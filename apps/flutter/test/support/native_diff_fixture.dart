import 'package:pocox/src/git_diff.dart';

/// Structured native output for UI tests; parser behavior is tested in Rust.
DiffModel diffFixture(
  String path, {
  List<String> removed = const ['old'],
  List<String> added = const ['new'],
}) => DiffModel(
  [
    DiffFile(
      path: path,
      added: added.length,
      removed: removed.length,
      lines: [
        DiffLine(
          DiffLineKind.hunk,
          '@@ -1,${removed.length} +1,${added.length} @@',
          oldLine: removed.isEmpty ? 0 : 1,
          newLine: added.isEmpty ? 0 : 1,
        ),
        for (var i = 0; i < removed.length; i++)
          DiffLine(DiffLineKind.removed, removed[i], oldLine: i + 1),
        for (var i = 0; i < added.length; i++)
          DiffLine(DiffLineKind.added, added[i], newLine: i + 1),
      ],
    ),
  ],
  added: added.length,
  removed: removed.length,
);

DiffModel combineDiffFixtures(DiffModel first, DiffModel second) => DiffModel(
  [...first.files, ...second.files],
  added: first.added + second.added,
  removed: first.removed + second.removed,
);

ReviewIndex reviewIndexFixture(List<DiffModel> edits) {
  final sections = <String, List<(int, int)>>{};
  for (var e = 0; e < edits.length; e++) {
    for (var f = 0; f < edits[e].files.length; f++) {
      (sections[edits[e].files[f].path] ??= []).add((e, f));
    }
  }
  final paths = sections.keys.toList()..sort();
  return ReviewIndex(
    [
      for (final path in paths)
        ReviewFileIndex(
          path: path,
          sections: sections[path]!,
          added: sections[path]!.fold(
            0,
            (sum, s) => sum + edits[s.$1].files[s.$2].added,
          ),
          removed: sections[path]!.fold(
            0,
            (sum, s) => sum + edits[s.$1].files[s.$2].removed,
          ),
        ),
    ],
    added: edits.fold(0, (sum, edit) => sum + edit.added),
    removed: edits.fold(0, (sum, edit) => sum + edit.removed),
  );
}
