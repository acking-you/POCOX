//! Bounded SSE framing, independent of network chunk and UTF-8 boundaries.

use std::{collections::VecDeque, pin::Pin};

use futures::{Stream, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{client::ClientError, wire::Dialect};

const MAX_EVENT_BYTES: usize = 2 * 1024 * 1024;

/// A native event. Unknown kinds remain available to the dispatcher.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Event {
    /// Project instance which emitted a global event, absent for heartbeats.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub directory: Option<String>,
    /// Native kind, for example `message.part.delta` or `session.status`.
    #[serde(rename = "type")]
    pub kind: String,
    /// Native event-specific fields.
    #[serde(default)]
    pub properties: Value,
}

/// One bounded native SSE connection.
pub struct EventStream {
    bytes: Pin<Box<dyn Stream<Item = Result<bytes::Bytes, reqwest::Error>> + Send>>,
    decoder: Decoder,
    ready: VecDeque<Event>,
    ended: bool,
}

impl EventStream {
    /// `framing` decodes each frame; the Pocket gateway's frames use the 1.x
    /// instance envelope.
    pub(super) fn new(response: reqwest::Response, framing: Dialect) -> Self {
        Self {
            bytes: Box::pin(response.bytes_stream()),
            decoder: Decoder::new(framing),
            ready: VecDeque::new(),
            ended: false,
        }
    }

    /// Read the next complete event. Transport failures and incomplete EOF
    /// are errors; neither can be mistaken for an idle session.
    pub async fn next(&mut self) -> Option<Result<Event, ClientError>> {
        loop {
            if let Some(event) = self.ready.pop_front() {
                return Some(Ok(event));
            }
            if self.ended {
                return None;
            }
            match self.bytes.next().await {
                Some(Ok(bytes)) => match self.decoder.push(&bytes) {
                    Ok(events) => self.ready.extend(events),
                    Err(error) => {
                        self.ended = true;
                        return Some(Err(error));
                    },
                },
                Some(Err(_)) => {
                    self.ended = true;
                    return Some(Err(ClientError::Transport));
                },
                None => {
                    self.ended = true;
                    return Some(Err(ClientError::EventStreamEnded));
                },
            }
        }
    }
}

/// Line and data buffers are reused across frames.
struct Decoder {
    line: Vec<u8>,
    data: Vec<u8>,
    carriage_return: bool,
    framing: Dialect,
}

impl Decoder {
    fn new(framing: Dialect) -> Self {
        Self {
            line: Vec::new(),
            data: Vec::new(),
            carriage_return: false,
            framing,
        }
    }

    fn push(&mut self, chunk: &[u8]) -> Result<Vec<Event>, ClientError> {
        let mut events = Vec::new();
        for &byte in chunk {
            if self.carriage_return && byte == b'\n' {
                self.carriage_return = false;
                continue;
            }
            self.carriage_return = byte == b'\r';
            if matches!(byte, b'\n' | b'\r') {
                if let Some(event) = self.finish_line()? {
                    if events.len() >= 1024 {
                        return Err(ClientError::TooLarge);
                    }
                    events.push(event);
                }
            } else {
                if self.line.len() + self.data.len() >= MAX_EVENT_BYTES {
                    return Err(ClientError::TooLarge);
                }
                self.line.push(byte);
            }
        }
        Ok(events)
    }

    fn finish_line(&mut self) -> Result<Option<Event>, ClientError> {
        if self.line.is_empty() {
            if self.data.is_empty() {
                return Ok(None);
            }
            let event = self.framing.event(&self.data);
            self.data.clear();
            return event;
        }
        if let Some(data) = self.line.strip_prefix(b"data:") {
            let data = data.strip_prefix(b" ").unwrap_or(data);
            if !self.data.is_empty() {
                self.data.push(b'\n');
            }
            self.data.extend_from_slice(data);
        }
        self.line.clear();
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_chunk_boundary_preserves_utf8_crlf_and_multiline_data() {
        let wire = b": heartbeat\r\ndata: {\r\ndata: \"type\":\"session.updated\",\r\ndata: \"properties\":{\"title\":\"\xe6\x81\xa2\xe5\xa4\x8d\"}}\r\n\r\n";
        for split in 0..=wire.len() {
            let mut decoder = Decoder::new(Dialect::V1);
            let mut events = decoder.push(&wire[..split]).expect("first chunk");
            events.extend(decoder.push(&wire[split..]).expect("second chunk"));
            assert_eq!(events.len(), 1);
            assert_eq!(events[0].kind, "session.updated");
            assert_eq!(events[0].properties["title"], "恢复");
        }
    }

    #[test]
    fn an_unterminated_oversized_line_is_rejected_before_allocation_grows() {
        let mut decoder = Decoder::new(Dialect::V1);
        assert!(matches!(
            decoder.push(&vec![b'x'; MAX_EVENT_BYTES + 1]),
            Err(ClientError::TooLarge)
        ));
        assert_eq!(decoder.line.len(), MAX_EVENT_BYTES);
    }

    #[test]
    fn invalid_payload_is_not_an_authoritative_event() {
        assert!(matches!(
            Decoder::new(Dialect::V1).push(b"data: no json\n\n"),
            Err(ClientError::InvalidResponse)
        ));
    }

    #[test]
    fn global_stream_keeps_project_scope_and_accepts_server_heartbeats() {
        let events = Decoder::new(Dialect::V1)
            .push(b"data: {\"directory\":\"/work/one\",\"payload\":{\"type\":\"session.status\",\"properties\":{\"sessionID\":\"ses_a\"}}}\n\ndata: {\"payload\":{\"type\":\"server.connected\",\"properties\":{}}}\n\n")
            .expect("global frames");
        assert_eq!(events[0].directory.as_deref(), Some("/work/one"));
        assert_eq!(events[0].properties["sessionID"], "ses_a");
        assert_eq!(events[1].kind, "server.connected");
        assert_eq!(events[1].directory, None);
    }
}
