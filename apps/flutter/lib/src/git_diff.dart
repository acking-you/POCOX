/// Ready-to-render native diff models. Parsing, numbering and counts belong
/// to Rust; Flutter only chooses layout and syntax highlighting.
library;

import 'package:pocox/src/rust/api/bridge/diff.dart' as native;

enum DiffLineKind { context, added, removed, hunk }

class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldLine, this.newLine});
  final DiffLineKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;
}

class DiffFile {
  const DiffFile({
    required this.path,
    required this.lines,
    required this.added,
    required this.removed,
  });
  final String path;
  final List<DiffLine> lines;
  final int added;
  final int removed;
}

class DiffModel {
  const DiffModel(
    this.files, {
    this.added = 0,
    this.removed = 0,
    this.truncated = false,
  });
  factory DiffModel.fromNative(native.DiffDto value) => DiffModel(
    [
      for (final file in value.files)
        DiffFile(
          path: file.path,
          added: file.added,
          removed: file.removed,
          lines: [
            for (final line in file.lines)
              DiffLine(
                _kind(line.kind),
                line.text,
                oldLine: line.oldLine,
                newLine: line.newLine,
              ),
          ],
        ),
    ],
    added: value.added,
    removed: value.removed,
    truncated: value.truncated,
  );
  final List<DiffFile> files;
  final int added;
  final int removed;
  final bool truncated;
  bool get isEmpty => files.isEmpty;

  static DiffLineKind _kind(native.DiffLineKind kind) => switch (kind) {
    native.DiffLineKind.context => DiffLineKind.context,
    native.DiffLineKind.added => DiffLineKind.added,
    native.DiffLineKind.removed => DiffLineKind.removed,
    native.DiffLineKind.hunk => DiffLineKind.hunk,
  };
}

/// A path's extension, as a syntax-highlighter language hint. Empty for a
/// dotfile or an extensionless name, which the highlighter leaves plain.
///
/// Splits on both separators so a Windows path from the host resolves the same
/// as a POSIX one.
String languageHintForPath(String path) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  final base = slash < 0 ? path : path.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  return dot <= 0 ? '' : base.substring(dot + 1);
}

/// Native indices reference the existing diff objects held by Flutter.
class ReviewFileIndex {
  const ReviewFileIndex({
    required this.path,
    required this.sections,
    required this.added,
    required this.removed,
  });
  final String path;
  final List<(int, int)> sections;
  final int added;
  final int removed;
}

class ReviewIndex {
  const ReviewIndex(this.files, {required this.added, required this.removed});
  final List<ReviewFileIndex> files;
  final int added;
  final int removed;
}
