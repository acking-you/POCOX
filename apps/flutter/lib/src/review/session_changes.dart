import 'package:pocox/src/git_diff.dart';
import 'package:pocox/src/screens/app_session/transcript_model.dart';

/// One edit the agent made: a `fileChange` step of the conversation, as the
/// transcript recorded it.
class SessionEdit {
  /// Creates an edit.
  const SessionEdit({
    required this.id,
    required this.index,
    required this.turnId,
    required this.diff,
    this.completedAt,
  });

  /// The transcript item it came from.
  final String id;

  /// Its place among the conversation's edits, from 1.
  final int index;

  /// The turn it belongs to.
  final String turnId;

  /// When its turn finished (Unix seconds), if known.
  final int? completedAt;

  /// What it changed.
  final DiffModel diff;
}

/// One file the conversation changed: each edit's part of it, in order.
class SessionFile {
  /// Creates the file's entry.
  SessionFile(this.path, this.edits)
    : added = edits.fold(0, (n, e) => n + e.$2.added),
      removed = edits.fold(0, (n, e) => n + e.$2.removed);

  /// The file's path, as the edits named it.
  final String path;

  /// Every edit that touched it, with that edit's diff of it.
  final List<(SessionEdit, DiffFile)> edits;

  /// Lines added across its edits.
  final int added;

  /// Lines removed across its edits.
  final int removed;
}

/// Every change the loaded transcript holds, by edit and by file.
///
/// Built from what the transcript has loaded, so a long conversation's
/// older edits appear as its history is read. Each edit is shown as the
/// agent made it: later edits of a file are not folded into one diff, since
/// their line numbers refer to the file as each one found it.
class SessionChanges {
  SessionChanges._(this.edits, this.files);

  /// No changes.
  static final empty = SessionChanges._(const [], const []);

  /// The changes the `fileChange` items among [items] carry.
  factory SessionChanges.of(Iterable<TranscriptItem> items) {
    final edits = <SessionEdit>[];
    final byPath = <String, List<(SessionEdit, DiffFile)>>{};
    for (final item in items) {
      if (item.type != 'fileChange') continue;
      final diff = DiffModel.cached(item.text);
      if (diff.isEmpty) continue;
      final edit = SessionEdit(
        id: item.id,
        index: edits.length + 1,
        turnId: item.turnId,
        completedAt: item.turnCompletedAt,
        diff: diff,
      );
      edits.add(edit);
      for (final file in diff.files) {
        (byPath[file.path] ??= []).add((edit, file));
      }
    }
    if (edits.isEmpty) return empty;
    final files = [
      for (final entry in byPath.entries) SessionFile(entry.key, entry.value),
    ]..sort((a, b) => a.path.compareTo(b.path));
    return SessionChanges._(edits, files);
  }

  /// The edits, oldest first.
  final List<SessionEdit> edits;

  /// The files they touched, by path.
  final List<SessionFile> files;

  /// Whether the transcript holds no edit with a diff.
  bool get isEmpty => edits.isEmpty;

  /// Lines added across every edit.
  int get added => files.fold(0, (n, f) => n + f.added);

  /// Lines removed across every edit.
  int get removed => files.fold(0, (n, f) => n + f.removed);

  /// The edit from item [id], if it is one.
  SessionEdit? edit(String id) {
    for (final edit in edits) {
      if (edit.id == id) return edit;
    }
    return null;
  }
}
