//! Parsed and numbered diffs for every Flutter review surface.
use super::*;
use crate::engine::{
    execution::{self, Lane},
    git_diff,
};

/// A numbered diff row; the renderer only selects its colors and layout.
pub struct DiffLineDto {
    /// `context`, `added`, `removed` or `hunk`.
    pub kind: String,
    /// Display text.
    pub text: String,
    /// Old-file number or hunk start.
    pub old_line: Option<u32>,
    /// New-file number or hunk start.
    pub new_line: Option<u32>,
}
/// A changed file and its precomputed counts.
pub struct DiffFileDto {
    /// Decoded host path.
    pub path: String,
    /// Numbered rows.
    pub lines: Vec<DiffLineDto>,
    /// Added lines.
    pub added: u32,
    /// Removed lines.
    pub removed: u32,
}
/// Native parsed diff, reusable by its content revision.
pub struct DiffDto {
    /// Content identity.
    pub revision: String,
    /// Changed files in source order.
    pub files: Vec<DiffFileDto>,
    /// Total added lines.
    pub added: u32,
    /// Total removed lines.
    pub removed: u32,
    /// The bounded view omitted source content.
    pub truncated: bool,
}

pub(super) fn dto(diff: &git_diff::Diff) -> DiffDto {
    DiffDto {
        revision: diff.revision.clone(),
        added: diff.added,
        removed: diff.removed,
        truncated: diff.truncated,
        files: diff
            .files
            .iter()
            .map(|file| DiffFileDto {
                path: file.path.clone(),
                added: file.added,
                removed: file.removed,
                lines: file
                    .lines
                    .iter()
                    .map(|line| DiffLineDto {
                        kind: line.kind.clone(),
                        text: line.text.clone(),
                        old_line: line.old_line,
                        new_line: line.new_line,
                    })
                    .collect(),
            })
            .collect(),
    }
}

/// Read and parse the working tree in Rust, returning a ready-to-render view.
pub async fn app_git_diff_parsed(service_key: String, cwd: String) -> Result<DiffDto> {
    let raw = execution::run(Lane::Read, move || engine(&service_key).git_diff(&service_key, &cwd))
        .await?;
    execution::run(Lane::Cpu, move || Ok(dto(&git_diff::parse(&raw)))).await
}

/// File metadata for a conversation edit; diff bodies need no return trip.
pub struct ReviewFileInputDto {
    /// Host path.
    pub path: String,
    /// Added lines.
    pub added: u32,
    /// Removed lines.
    pub removed: u32,
}
/// One edit's files in their original diff order.
pub struct ReviewEditInputDto {
    /// File records, including repeated paths.
    pub files: Vec<ReviewFileInputDto>,
}
/// Index of one section in the supplied edit/file arrays.
pub struct ReviewSectionDto {
    /// Zero-based edit index.
    pub edit: u32,
    /// Zero-based file index within the edit.
    pub file: u32,
}
/// One path's complete edit history and counts.
pub struct ReviewFileDto {
    /// Host path, sorted lexicographically in the result.
    pub path: String,
    /// Sections in chronological edit order.
    pub sections: Vec<ReviewSectionDto>,
    /// Added lines across sections.
    pub added: u64,
    /// Removed lines across sections.
    pub removed: u64,
}
/// Indexed conversation review, without copying parsed diff bodies.
pub struct ReviewIndexDto {
    /// Files sorted by path.
    pub files: Vec<ReviewFileDto>,
    /// Total added lines.
    pub added: u64,
    /// Total removed lines.
    pub removed: u64,
}

fn index_edits(edits: Vec<ReviewEditInputDto>) -> Result<ReviewIndexDto> {
    let count = edits.iter().map(|edit| edit.files.len()).sum::<usize>();
    let bytes = edits
        .iter()
        .flat_map(|edit| &edit.files)
        .map(|file| file.path.len())
        .sum::<usize>();
    anyhow::ensure!(
        edits.len() <= 100_000 && count <= 100_000 && bytes <= 8 << 20,
        "review index exceeds its metadata budget"
    );
    let mut files = std::collections::BTreeMap::<String, ReviewFileDto>::new();
    let (mut added, mut removed) = (0, 0);
    for (edit, input) in edits.into_iter().enumerate() {
        for (file, input) in input.files.into_iter().enumerate() {
            let record = files
                .entry(input.path.clone())
                .or_insert_with(|| ReviewFileDto {
                    path: input.path,
                    sections: Vec::new(),
                    added: 0,
                    removed: 0,
                });
            record.sections.push(ReviewSectionDto {
                edit: edit as u32,
                file: file as u32,
            });
            record.added += u64::from(input.added);
            record.removed += u64::from(input.removed);
            added += u64::from(input.added);
            removed += u64::from(input.removed);
        }
    }
    Ok(ReviewIndexDto {
        files: files.into_values().collect(),
        added,
        removed,
    })
}

/// Group edits by file and compute totals on the native CPU queue.
pub async fn review_index(edits: Vec<ReviewEditInputDto>) -> Result<ReviewIndexDto> {
    execution::run(Lane::Cpu, move || index_edits(edits)).await
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn repeated_paths_keep_every_section_in_edit_order() {
        let file = |path: &str| ReviewFileInputDto {
            path: path.into(),
            added: 2,
            removed: 1,
        };
        let result = index_edits(vec![
            ReviewEditInputDto {
                files: vec![file("b"), file("a")],
            },
            ReviewEditInputDto {
                files: vec![file("a"), file("a")],
            },
        ])
        .unwrap();
        assert_eq!(
            result
                .files
                .iter()
                .map(|file| file.path.as_str())
                .collect::<Vec<_>>(),
            ["a", "b"]
        );
        assert_eq!(
            result.files[0]
                .sections
                .iter()
                .map(|s| (s.edit, s.file))
                .collect::<Vec<_>>(),
            [(0, 1), (1, 0), (1, 1)]
        );
        assert_eq!((result.added, result.removed), (8, 4));
        assert_eq!((result.files[0].added, result.files[0].removed), (6, 3));
    }
}
