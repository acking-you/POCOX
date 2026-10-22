//! Bounded syntax highlighting; Flutter owns styles and widget layout.
use anyhow::Result;

use crate::engine::{
    execution::{self, Lane},
    syntax,
};

/// One source and its explicitly selected grammar; no language guessing.
pub struct HighlightInputDto {
    /// Source preserved verbatim by the renderer.
    pub source: String,
    /// A fence language name or alias.
    pub language: String,
}

/// Compact semantic runs without source text or theme-dependent styles.
pub struct HighlightTokensDto {
    /// Pairs of exclusive UTF-16 end offsets and role/decoration bits.
    /// Roles 0..8 are plain, keyword, type, function, string, number,
    /// comment, meta and punctuation; 256 is bold, 512 is italic.
    pub runs: Vec<u32>,
}

/// Highlight a bounded batch outside the UI thread and the async runtime.
pub async fn highlight_batch(inputs: Vec<HighlightInputDto>) -> Result<Vec<HighlightTokensDto>> {
    anyhow::ensure!(inputs.len() <= 32, "too many highlight inputs");
    anyhow::ensure!(
        inputs
            .iter()
            .map(|i| i.source.len() + i.language.len())
            .sum::<usize>()
            <= 1 << 20,
        "highlight batch exceeds its byte budget"
    );
    execution::run(Lane::Cpu, move || {
        Ok(inputs
            .into_iter()
            .map(|input| HighlightTokensDto {
                runs: syntax::highlight(&input.source, &input.language),
            })
            .collect())
    })
    .await
}
