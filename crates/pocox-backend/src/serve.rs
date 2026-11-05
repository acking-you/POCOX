//! The accept loop: wrap each connection in the configured TLS layer and hand
//! it to the HTTP API (hyper).
//!
//! This listener faces the public, and pairing puts an anonymous surface on it.
//! With pairing on, a connection has to earn its file descriptor: there are
//! caps in total and per address, and timers on what it sends. With it off,
//! connections are served as they always were. Either way a failing `accept`
//! backs off instead of spinning when descriptors run out.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
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

/// How often refusals are logged at warn. A refusal can be someone's outage,
/// but a flood of them must not become a flood of log lines.
const REFUSAL_LOG_INTERVAL_SECS: i64 = 60;

/// What one listener admits with pairing on.
#[derive(Debug, Clone, Copy)]
pub struct ConnectionLimits {
    /// Connections open at once.
    pub total: usize,
    /// Connections open at once from one address (an IPv4 address or an IPv6
    /// /64). A trusted proxy is exempt: all its clients share its address.
    pub per_address: usize,
    /// How long a client has to send a request's headers, which also ends an
    /// idle connection. Longer than any client's usual gap between
    /// requests, whose poll intervals are multiples of 5 seconds or 6 + 5k,
    /// so a poll does not race the close.
    pub header_read_timeout: Duration,
}

impl Default for ConnectionLimits {
    fn default() -> Self {
        Self {
            total: 8192,
            per_address: 128,
            header_read_timeout: Duration::from_secs(18),
        }
    }
}

/// Open connections, counted in total and per address.
struct ConnectionCounts {
    limits: ConnectionLimits,
    exempt: TrustedProxies,
    open: Mutex<(usize, HashMap<Vec<u8>, usize>)>,
    refused: AtomicU64,
    last_warned: AtomicI64,
}

/// One admitted connection. Dropping it gives the slot back.
struct Admitted {
    counts: Arc<ConnectionCounts>,
    bucket: Option<Vec<u8>>,
}

impl ConnectionCounts {
    fn new(limits: ConnectionLimits, exempt: TrustedProxies) -> Arc<Self> {
        Arc::new(Self {
            limits,
            exempt,
            open: Mutex::new((0, HashMap::new())),
            refused: AtomicU64::new(0),
            last_warned: AtomicI64::new(0),
        })
    }

    /// Note a refusal, at warn no more than once per interval. An operator who
    /// left a proxy out of `trusted_proxies` finds out here.
    fn note_refusal(&self, peer: IpAddr) {
        let refused = self.refused.fetch_add(1, Ordering::Relaxed) + 1;
        let now = time::OffsetDateTime::now_utc().unix_timestamp();
        let last = self.last_warned.load(Ordering::Relaxed);
        if now - last >= REFUSAL_LOG_INTERVAL_SECS
            && self
                .last_warned
                .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
                .is_ok()
        {
            tracing::warn!(
                %peer,
                refused,
                "connection limit reached; is every proxy in trusted_proxies?"
            );
        }
    }

    fn admit(self: &Arc<Self>, ip: IpAddr) -> Option<Admitted> {
        let bucket = (!self.exempt.contains(ip)).then(|| address_bucket(ip));
        let mut open = self.open.lock().expect("connection counts");
        let full = open.0 >= self.limits.total
            || bucket.as_ref().is_some_and(|bucket| {
                open.1.get(bucket).copied().unwrap_or(0) >= self.limits.per_address
            });
        if full {
            drop(open);
            self.note_refusal(ip);
            return None;
        }
        if let Some(bucket) = &bucket {
            *open.1.entry(bucket.clone()).or_default() += 1;
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
///
/// `limits` is `None` with pairing off: no caps and no timers, as before.
pub async fn serve_http(
    listener: TcpListener,
    router: Router,
    tls: TlsKind,
    limits: Option<ConnectionLimits>,
    trusted_proxies: TrustedProxies,
) {
    let counts = limits.map(|limits| ConnectionCounts::new(limits, trusted_proxies));
    loop {
        let (tcp, peer) = match listener.accept().await {
            Ok(x) => x,
            Err(e) => {
                tracing::warn!(error = %e, "http accept failed");
                tokio::time::sleep(ACCEPT_BACKOFF).await;
                continue;
            },
        };
        let admitted = match &counts {
            Some(counts) => match counts.admit(peer.ip()) {
                Some(admitted) => Some(admitted),
                None => continue,
            },
            None => None,
        };
        let tls = tls.clone();
        let router = router.clone();
        tokio::spawn(async move {
            let _admitted = admitted;
            let Some(stream) = accept_tls(&tls, tcp).await else {
                return;
            };
            let io = TokioIo::new(stream);
            let spoke = Arc::new(AtomicBool::new(false));
            let heard = Arc::clone(&spoke);
            let service = hyper::service::service_fn(move |mut request| {
                heard.store(true, Ordering::Relaxed);
                request.extensions_mut().insert(ConnectInfo(peer));
                router.clone().oneshot(request.map(axum::body::Body::new))
            });
            let mut builder = Builder::new(TokioExecutor::new());
            let Some(limits) = limits else {
                if let Err(e) = builder.serve_connection_with_upgrades(io, service).await {
                    tracing::debug!(error = %e, "http connection ended");
                }
                return;
            };
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
        });
    }
}
