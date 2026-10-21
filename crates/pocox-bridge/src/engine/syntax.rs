//! Syntax scopes projected to compact, theme-independent UTF-16 runs.
use std::{
    sync::LazyLock,
    time::{Duration, Instant},
};

use syntect::{
    easy::HighlightLines,
    highlighting::{Color, FontStyle, StyleModifier, Theme, ThemeItem},
    parsing::SyntaxSet,
    util::LinesWithEndings,
};

struct Configuration {
    syntax: SyntaxSet,
    theme: Theme,
}

static CONFIG: LazyLock<anyhow::Result<Configuration>> = LazyLock::new(|| {
    let mut theme = Theme::default();
    theme.settings.foreground = Some(color(0));
    for (selector, role, style) in [
        ("keyword, storage, constant.language", 1, FontStyle::empty()),
        ("entity.name.type, entity.name.class, support.type, support.class", 2, FontStyle::empty()),
        (
            "entity.name.function, support.function, entity.name.tag, entity.other.attribute-name",
            3,
            FontStyle::empty(),
        ),
        ("string, markup.inserted", 4, FontStyle::empty()),
        ("constant.numeric", 5, FontStyle::empty()),
        ("comment, markup.quote", 6, FontStyle::empty()),
        ("meta.preprocessor, variable, markup.deleted", 7, FontStyle::empty()),
        ("punctuation", 8, FontStyle::empty()),
        ("markup.bold", 1, FontStyle::BOLD),
        ("markup.italic", 8, FontStyle::ITALIC),
    ] {
        theme.scopes.push(ThemeItem {
            scope: selector.parse()?,
            style: StyleModifier {
                foreground: Some(color(role)),
                font_style: Some(style),
                ..Default::default()
            },
        });
    }
    Ok(Configuration {
        syntax: two_face::syntax::extra_newlines(),
        theme,
    })
});

fn color(role: u8) -> Color {
    Color {
        r: role,
        g: 0,
        b: 0,
        a: 255,
    }
}

/// Project explicit syntax scopes into `(exclusive UTF-16 end, role bits)`
/// pairs. Empty means plain text, including oversized or failed input. No
/// source is retained by Rust and the caller can reuse tokens across themes and
/// fonts.
pub fn highlight(source: &str, language: &str) -> Vec<u32> {
    if source.is_empty()
        || source.len() > 80_000
        || source.encode_utf16().count() > 20_000
        || source.lines().any(|line| line.len() > 4096)
    {
        return Vec::new();
    }
    let Ok(config) = CONFIG.as_ref() else { return Vec::new() };
    let name = match language {
        "bash" | "shell" => "sh",
        "csharp" => "cs",
        "javascript" => "js",
        "typescript" => "ts",
        "markdown" => "md",
        "powershell" => "ps1",
        "makefile" => "Makefile",
        "dockerfile" => "Dockerfile",
        other => other,
    };
    let Some(syntax) = config.syntax.find_syntax_by_token(name) else { return Vec::new() };
    let started = Instant::now();
    let mut highlighter = HighlightLines::new(syntax, &config.theme);
    let mut runs: Vec<u32> = Vec::new();
    let mut end = 0;
    for line in LinesWithEndings::from(source) {
        let Ok(tokens) = highlighter.highlight_line(line, &config.syntax) else {
            return Vec::new();
        };
        // A source is optional decoration. Do not occupy the CPU lane with an
        // arbitrarily expensive grammar; retain readable, unmodified text.
        if started.elapsed() > Duration::from_millis(100) {
            return Vec::new();
        }
        for (style, text) in tokens {
            if text.is_empty() {
                continue;
            }
            end += text.encode_utf16().count() as u32;
            let role = u32::from(style.foreground.r)
                | if style.font_style.contains(FontStyle::BOLD) { 256 } else { 0 }
                | if style.font_style.contains(FontStyle::ITALIC) { 512 } else { 0 };
            if runs.last() == Some(&role) {
                let index = runs.len() - 2;
                runs[index] = end;
            } else {
                runs.extend([end, role]);
            }
        }
    }
    runs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scopes_preserve_unicode_and_multiline_context_for_supported_grammars() {
        let sample = "/* 中文 😀\ncomment */\nfn main() { let text = \"你好\"; }\n";
        for language in [
            "rust",
            "dart",
            "typescript",
            "bash",
            "c",
            "cpp",
            "csharp",
            "css",
            "cmake",
            "diff",
            "dockerfile",
            "go",
            "ini",
            "java",
            "javascript",
            "json",
            "kotlin",
            "lua",
            "makefile",
            "markdown",
            "php",
            "powershell",
            "python",
            "ruby",
            "scala",
            "shell",
            "sql",
            "swift",
            "xml",
            "yaml",
        ] {
            let tokens = highlight(sample, language);
            assert!(!tokens.is_empty(), "{language}");
            assert_eq!(
                tokens[tokens.len() - 2] as usize,
                sample.encode_utf16().count(),
                "{language}"
            );
            let mut previous = 0;
            for pair in tokens.chunks_exact(2) {
                assert!(pair[0] > previous);
                assert!(pair[1] & 255 <= 8);
                previous = pair[0];
            }
        }
        let comment = highlight("/* first\nsecond */", "rust");
        assert!(comment.chunks_exact(2).any(|p| p[1] == 6));
    }

    #[test]
    fn unknown_oversized_and_pathological_lines_stay_plain() {
        assert!(highlight("text", "not-a-language").is_empty());
        assert!(highlight(&"x".repeat(4097), "rust").is_empty());
        assert!(highlight(&"let a = 1;\n".repeat(3000), "rust").is_empty());
    }
}
