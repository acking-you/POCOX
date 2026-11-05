//! The accept loop: wrap each connection in the configured TLS layer and hand
//! it to the HTTP API (hyper).
//!
//! This listener faces the public, and pairing puts an anonymous surface on it,
//! so a connection has to earn its file descriptor: there are caps in total and
//! per address, hyper's header timer is running, and a failing `accept` backs
//! off instead of spinning when descriptors run out.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::ConnectInfo;
use axum::Router;
use hyper_util::rt::{TokioExecutor, TokioIo, TokioTimer};
use hyper_util::server::conn::auto::Builder;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpListener, TcpStream};
use tower::ServiceExt as _;

use crate::pairing::{address_bucket, TrustedProxies};
use crate::tls::TlsKind;

/// A wrapped (TLS or plain) connection ready to serve.
trait Stream: AsyncRead + AsyncWrite + Unpin + Send + 'static {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send + 'static> Stream for T {}

/// How long a TLS handshake may take before the connection is abandoned. Each
/// accepted connection is its own task, so an unbounded handshake lets a client
/// that opens a socket but never completes (or slowly drips) the handshake pin
/// a task + file descriptor indefinitely — a slowloris-style
/// resource-exhaustion vector on a public listener. Bound it.
const TLS_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

/// How long to wait after `accept` fails. Out of descriptors, it fails at once
/// and forever, and retrying immediately would burn a core on it.
const ACCEPT_BACKOFF: Duration = Duration::from_millis(100);

/// HTTP/2 streams per connection.
const MAX_CONCURRENT_STREAMS: u32 = 64;

/// How often an idle HTTP/2 connection is pinged, and how long it has to
/// answer.
const H2_KEEP_ALIVE: Duration = Duration::from_secs(30);
const H2_KEEP_ALIVE_TIMEOUT: Duration = Duration::from_secs(20);

/// What one listener admits.
#[derive(Debug, Clone, Copy)]
pub struct ConnectionLimits {
    /// Connections open at once.
    pub total: usize,
    /// Connections open at once from one address (an IPv4 address or an IPv6
    /// /64). A trusted proxy is exempt: all its clients share its address.
    pub per_address: usize,
    /// How long a client has to send a request's headers, which also ends an
    /// idle HTTP/1 connection.
    pub header_read_timeout: Duration,
}

impl Default for ConnectionLimits {
    fn default() -> Self {
        Self {
            total: 8192,
            per_address: 128,
            header_read_timeout: Duration::from_secs(15),
        }
    }
}

/// Open connections, counted in total and per address.
struct ConnectionCounts {
    limits: ConnectionLimits,
    exempt: TrustedProxies,
    open: Mutex<(usize, HashMap<Vec<u8>, usize>)>,
}

/// One admitted connection. Dropping it gives the slot back.
struct Admitted {
    counts: Arc<ConnectionCounts>,
    bucket: Option<Vec<u8>>,
}

impl ConnectionCounts {
    fn admit(self: &Arc<Self>, ip: IpAddr) -> Option<Admitted> {
        let bucket = (!self.exempt.contains(ip)).then(|| address_bucket(ip));
        let mut open = self.open.lock().expect("connection counts");
        if open.0 >= self.limits.total {
            return None;
        }
        if let Some(bucket) = &bucket {
            let from_address = open.1.entry(bucket.clone()).or_default();
            if *from_address >= self.limits.per_address {
                return None;
            }
            *from_address += 1;
        }
        open.0 += 1;
        Some(Admitted {
            counts: Arc::clone(self),
            bucket,
        })
    }
}

impl Drop for Admitted {
    fn drop(&mut self) {
        let mut open = self.counts.open.lock().expect("connection counts");
        open.0 -= 1;
        if let Some(bucket) = &self.bucket {
            if let Some(from_address) = open.1.get_mut(bucket) {
                *from_address -= 1;
                if *from_address == 0 {
                    open.1.remove(bucket);
                }
            }
        }
    }
}

/// Wrap one accepted TCP connection, or `None` if it was an ACME challenge or
/// the handshake failed/stalled.
async fn accept_tls(tls: &TlsKind, tcp: TcpStream) -> Option<Box<dyn Stream>> {
    match tls {
        TlsKind::Plain => Some(Box::new(tcp)),
        TlsKind::Static(acceptor) => {
            match tokio::time::timeout(TLS_HANDSHAKE_TIMEOUT, acceptor.accept(tcp)).await {
                Ok(Ok(stream)) => Some(Box::new(stream)),
                Ok(Err(e)) => {
                    tracing::warn!(error = %e, "tls handshake failed");
                    None
                },
                Err(_) => {
                    tracing::warn!("tls handshake timed out");
                    None
                },
            }
        },
    }
}

/// Serve the HTTP API over the TLS layer, forever. Each request carries its
/// socket peer as [`ConnectInfo`], in direct-TLS and plain modes alike, because
/// per-address limits have nothing else to go on.
pub async fn serve_http(
    listener: TcpListener,
    router: Router,
    tls: TlsKind,
    limits: ConnectionLimits,
    trusted_proxies: TrustedProxies,
) {
    let counts = Arc::new(ConnectionCounts {
        limits,
        exempt: trusted_proxies,
        open: Mutex::new((0, HashMap::new())),
    });
    loop {
        let (tcp, peer) = match listener.accept().await {
            Ok(x) => x,
            Err(e) => {
                tracing::warn!(error = %e, "http accept failed");
                tokio::time::sleep(ACCEPT_BACKOFF).await;
                continue;
            },
        };
        let Some(admitted) = counts.admit(peer.ip()) else {
            tracing::debug!("connection limit reached; closing a new connection");
            continue;
        };
        let tls = tls.clone();
        let router = router.clone();
        tokio::spawn(async move {
            let _admitted = admitted;
            if let Some(stream) = accept_tls(&tls, tcp).await {
                let io = TokioIo::new(stream);
                let spoke = Arc::new(AtomicBool::new(false));
                let heard = Arc::clone(&spoke);
                let service = hyper::service::service_fn(move |mut request| {
                    heard.store(true, Ordering::Relaxed);
                    request.extensions_mut().insert(ConnectInfo(peer));
                    router.clone().oneshot(request.map(axum::body::Body::new))
                });
                let mut builder = Builder::new(TokioExecutor::new());
                builder
                    .http1()
                    .timer(TokioTimer::new())
                    .header_read_timeout(limits.header_read_timeout);
                builder
                    .http2()
                    .timer(TokioTimer::new())
                    .max_concurrent_streams(MAX_CONCURRENT_STREAMS)
                    .keep_alive_interval(H2_KEEP_ALIVE)
                    .keep_alive_timeout(H2_KEEP_ALIVE_TIMEOUT);
                let connection = builder.serve_connection_with_upgrades(io, service);
                tokio::pin!(connection);
                // Telling HTTP/1 from HTTP/2 waits for the first bytes with no timer of its
                // own, and hyper's header timer starts only after that. A client that
                // connects and says nothing is therefore closed here.
                let first_words = tokio::time::sleep(limits.header_read_timeout);
                let ended = tokio::select! {
                    ended = connection.as_mut() => Some(ended),
                    () = first_words => None,
                };
                let ended = match ended {
                    Some(ended) => ended,
                    None if spoke.load(Ordering::Relaxed) => connection.await,
                    None => {
                        tracing::debug!("closing a connection that sent nothing");
                        return;
                    },
                };
                if let Err(e) = ended {
                    tracing::debug!(error = %e, "http connection ended");
                }
            }
        });
    }
}
