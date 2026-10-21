//! Keeping a supplied key out of text shown or logged after a launch.
//!
//! Raw child output of a launch with a key is never kept: no per-line rule
//! can contain a key a child prints in arbitrary pieces (a short key split
//! over lines of one to three characters each matches nothing), so such
//! output is replaced by this app's fixed notices ([`OUTPUT_WITHHELD`],
//! [`ADDR_IN_USE`]) before it reaches a log, and a viewer of that log shows
//! nothing else ([`Redactor::output`]).
//!
//! [`Redactor::text`] filters this app's own error text, which carries no
//! raw child output of such a launch, as a second line of defence: a line is
//! withheld when it holds a whole copy of the key (verbatim, percent-encoded
//! or JSON-escaped), a fragment of at least [`MIN_FRAGMENT`] characters of
//! one at either edge, or is entirely such a fragment. That rule alone is
//! not containment. [`Lines`] splits a byte stream into lines, never
//! emitting part of an over-long line.

use crate::provider::Secret;

/// Longest text [`Redactor::text`] returns, in bytes (plus an ellipsis).
const MAX_TEXT: usize = 600;

/// A key fragment at least this long at a line edge withholds the line.
pub const MIN_FRAGMENT: usize = 4;

/// What [`Redactor::line`] shows instead of a line holding the key.
pub const WITHHELD_LINE: &str = "[line withheld: it held the key]";

/// Written to a keyed launch's log once, in place of all its raw output.
pub const OUTPUT_WITHHELD: &str =
    "[pocox] codex output withheld: this host was launched with a supplied key";

/// Written to a keyed launch's log in place of an output line reporting an
/// address-in-use bind failure, so that failure is still diagnosed.
pub const ADDR_IN_USE: &str =
    "[pocox] codex output reported: address already in use (the line itself is withheld)";

/// Whether `line` is exactly one of this app's fixed notices.
pub fn is_notice(line: &str) -> bool {
    line == OUTPUT_WITHHELD || line == ADDR_IN_USE
}

fn percent_encoded(key: &str, upper: bool) -> String {
    let mut out = String::with_capacity(key.len() * 3);
    for b in key.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(b));
        } else if upper {
            out.push_str(&format!("%{b:02X}"));
        } else {
            out.push_str(&format!("%{b:02x}"));
        }
    }
    out
}

/// Withholds a key from shown text (see the module docs).
#[derive(Clone, Default)]
pub struct Redactor {
    forms: Vec<String>,
}

impl std::fmt::Debug for Redactor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The forms are copies of the key: only their number is shown.
        f.debug_struct("Redactor")
            .field("forms", &self.forms.len())
            .finish()
    }
}

impl Redactor {
    /// For `key` (`None`: nothing to withhold). Keys are printable ASCII
    /// tokens (the host configuration accepts nothing else).
    pub fn new(key: Option<&Secret>) -> Self {
        let Some(key) = key.map(Secret::expose).filter(|k| !k.is_empty()) else {
            return Self::default();
        };
        let mut forms = vec![
            key.to_string(),
            percent_encoded(key, true),
            percent_encoded(key, false),
            // JSON encoders may escape `/`.
            key.replace('/', "\\/"),
        ];
        forms.sort();
        forms.dedup();
        Self {
            forms,
        }
    }

    /// Include another supplied credential without exposing its forms.
    pub fn include(&mut self, key: &Secret) {
        self.forms.extend(Self::new(Some(key)).forms);
        self.forms.sort();
        self.forms.dedup();
    }

    /// Whether there is no key to withhold.
    pub fn is_empty(&self) -> bool {
        self.forms.is_empty()
    }

    /// Whether `line` holds a key, a fragment of one at its edge, or is
    /// itself a fragment (the middle of a key wrapped over several lines).
    pub fn holds(&self, line: &str) -> bool {
        let bare = line.trim();
        self.forms.iter().any(|form| {
            line.contains(form.as_str())
                || (bare.len() >= MIN_FRAGMENT && form.contains(bare))
                || (MIN_FRAGMENT..form.len()).any(|n| {
                    // Forms are ASCII, so every index is a char boundary.
                    bare.ends_with(&form[..n]) || bare.starts_with(&form[form.len() - n..])
                })
        })
    }

    /// `line`, or [`WITHHELD_LINE`] in its place when it holds the key.
    pub fn line<'a>(&self, line: &'a str) -> &'a str {
        if self.holds(line) {
            WITHHELD_LINE
        } else {
            line
        }
    }

    /// A child output line as it may be shown: verbatim without a key;
    /// with one, only when it is one of this app's fixed notices (the raw
    /// output of a keyed launch is never shown, see the module docs).
    pub fn output<'a>(&self, line: &'a str) -> Option<&'a str> {
        (self.forms.is_empty() || is_notice(line)).then_some(line)
    }

    /// `text` with every key-holding line withheld, bounded.
    pub fn text(&self, text: &str) -> String {
        let mut out = if self.forms.is_empty() {
            text.to_string()
        } else {
            text.lines()
                .map(|line| self.line(line))
                .collect::<Vec<_>>()
                .join("\n")
        };
        if out.len() > MAX_TEXT {
            let mut cut = MAX_TEXT;
            while !out.is_char_boundary(cut) {
                cut -= 1;
            }
            out.truncate(cut);
            out.push('…');
        }
        out
    }
}

/// One piece of a stream split by [`Lines`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Piece<'a> {
    /// A complete line, without its `\n`.
    Line(&'a [u8]),
    /// A line longer than the bound, of which at least this many bytes were
    /// dropped; nothing of it is emitted, up to its real end of line.
    Withheld(usize),
}

/// Splits a byte stream fed in arbitrary chunks into complete lines. A line
/// over `cap` bytes is never emitted in parts: it is reported once as
/// [`Piece::Withheld`] and the rest of it is discarded up to its newline.
#[derive(Debug)]
pub struct Lines {
    carry: Vec<u8>,
    cap: usize,
    discarding: bool,
}

impl Lines {
    /// A splitter keeping at most `cap` bytes of a partial line.
    pub fn new(cap: usize) -> Self {
        Self {
            carry: Vec::new(),
            cap,
            discarding: false,
        }
    }

    /// Forget any partial line (the stream restarted, e.g. a truncated file).
    pub fn reset(&mut self) {
        self.carry.clear();
        self.discarding = false;
    }

    /// Feed `bytes`, emitting every piece they complete.
    pub fn feed(&mut self, mut bytes: &[u8], mut emit: impl FnMut(Piece<'_>)) {
        while !bytes.is_empty() {
            let Some(nl) = bytes.iter().position(|&b| b == b'\n') else {
                if !self.discarding {
                    self.carry.extend_from_slice(bytes);
                    if self.carry.len() > self.cap {
                        emit(Piece::Withheld(self.carry.len()));
                        self.carry.clear();
                        self.discarding = true;
                    }
                }
                return;
            };
            let head = &bytes[..nl];
            bytes = &bytes[nl + 1..];
            if self.discarding {
                // The real end of the over-long line.
                self.discarding = false;
                continue;
            }
            let line: &[u8] = if self.carry.is_empty() {
                head
            } else {
                self.carry.extend_from_slice(head);
                &self.carry
            };
            if line.len() > self.cap {
                emit(Piece::Withheld(line.len()));
            } else {
                emit(Piece::Line(line));
            }
            self.carry.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "sk-ABC0123";

    fn redactor() -> Redactor {
        Redactor::new(Some(&Secret::new(KEY)))
    }

    /// The lines `chunks` produce, as shown through the redactor.
    fn shown(chunks: &[&[u8]], cap: usize) -> Vec<String> {
        let redactor = redactor();
        let mut lines = Lines::new(cap);
        let mut out = Vec::new();
        for chunk in chunks {
            lines.feed(chunk, |piece| match piece {
                Piece::Line(line) => {
                    out.push(redactor.line(&String::from_utf8_lossy(line)).to_string());
                },
                Piece::Withheld(bytes) => out.push(format!("[{bytes} withheld]")),
            });
        }
        out
    }

    #[test]
    fn whole_encoded_and_escaped_copies_are_withheld() {
        let r = Redactor::new(Some(&Secret::new("sk-a/b+c")));
        for line in
            ["auth sk-a/b+c here", "q=sk-a%2Fb%2Bc&x=1", "q=sk-a%2fb%2bc", r#"{"key":"sk-a\/b+c"}"#]
        {
            assert_eq!(r.line(line), WITHHELD_LINE, "{line}");
        }
        assert_eq!(r.line("nothing secret"), "nothing secret");
        assert!(Redactor::new(None).is_empty());
        assert_eq!(Redactor::new(None).text("a\nb"), "a\nb");
    }

    #[test]
    fn a_short_key_split_across_lines_is_withheld_on_both_sides() {
        assert_eq!(shown(&[b"token sk-AB\nC0123 rest\n"], 64), [WITHHELD_LINE, WITHHELD_LINE]);
        // Separate writes, split inside the key and inside the newline run.
        assert_eq!(shown(&[b"token sk-", b"AB", b"\nC01", b"23 rest\nok\n"], 64), [
            WITHHELD_LINE,
            WITHHELD_LINE,
            "ok"
        ]);
        // A three-way wrap: the middle line is all key.
        assert_eq!(shown(&[b"x sk-A\nBC01\n23 y\n"], 64)[1], WITHHELD_LINE);
    }

    #[test]
    fn an_overflowing_line_is_discarded_up_to_its_real_newline() {
        // The key's prefix falls into the dropped part; its short suffix
        // arrives in a later write of the same line and is never a line.
        let mut long = vec![b'x'; 40];
        long.extend_from_slice(b" sk-AB");
        let out = shown(&[&long, b"C0123", b" tail\nnext line\n"], 32);
        assert_eq!(out, ["[46 withheld]", "next line"]);
        // A complete over-long line is withheld too.
        assert_eq!(shown(&[&[b'y'; 40], b"\nshort\n"], 32), ["[40 withheld]", "short"]);
    }

    /// The case the per-line rule cannot contain: the key in pieces of one
    /// to three characters, at every split position, in separate writes and
    /// across an overflow. Shown as child output of a keyed launch, nothing
    /// of it remains; only exact notices pass.
    #[test]
    fn keyed_output_shows_nothing_but_notices_however_the_key_is_split() {
        let redactor = redactor();
        let mut texts: Vec<Vec<u8>> = Vec::new();
        for i in 0..=KEY.len() {
            for j in i..=KEY.len() {
                let (a, rest) = KEY.split_at(i);
                let (b, c) = rest.split_at(j - i);
                texts.push(format!("x {a}\n{b}\n{c} y\n").into_bytes());
                texts.push(format!("{a}\r\n{b}\n\n{c}\n").into_bytes());
            }
        }
        let mut long = vec![b'z'; 40];
        long.extend_from_slice(format!("{KEY}\n{}\n", &KEY[..3]).as_bytes());
        texts.push(long);
        for text in &texts {
            for chunk in 1..=4 {
                let mut lines = Lines::new(32);
                let mut shown = Vec::new();
                for piece in text.chunks(chunk) {
                    lines.feed(piece, |piece| {
                        if let Piece::Line(line) = piece {
                            let line = String::from_utf8_lossy(line).into_owned();
                            shown.extend(redactor.output(&line).map(str::to_string));
                        }
                    });
                }
                assert!(shown.is_empty(), "{shown:?} from {:?}", String::from_utf8_lossy(text));
            }
        }
        assert_eq!(redactor.output(OUTPUT_WITHHELD), Some(OUTPUT_WITHHELD));
        assert_eq!(redactor.output(ADDR_IN_USE), Some(ADDR_IN_USE));
        assert_eq!(redactor.output(&format!("{OUTPUT_WITHHELD} {KEY}")), None);
        // Without a key, output is unchanged.
        assert_eq!(Redactor::new(None).output("plain"), Some("plain"));
    }

    #[test]
    fn debug_never_prints_a_form_of_the_key() {
        let shown = format!("{:?}", Redactor::new(Some(&Secret::new("sk-a/b+c"))));
        assert!(!shown.contains("sk-a") && !shown.contains("%2F"), "{shown}");
        assert!(shown.contains("forms"), "{shown}");
    }

    #[test]
    fn text_is_bounded() {
        let long = "a".repeat(2_000);
        assert!(redactor().text(&long).len() <= MAX_TEXT + '…'.len_utf8());
    }
}
