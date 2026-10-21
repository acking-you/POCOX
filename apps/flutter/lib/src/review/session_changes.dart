import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
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
  const SessionFile(
    this.path,
    this.edits, {
    required this.added,
    required this.removed,
  });

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
  const SessionChanges(
    this.edits,
    this.files, {
    required this.added,
    required this.removed,
  });

  static const empty = SessionChanges([], [], added: 0, removed: 0);

  static Future<SessionChanges> project(
    BridgeApi api,
    List<SessionEdit> edits,
  ) async {
    if (edits.isEmpty) return empty;
    final index = await api.reviewIndex([for (final edit in edits) edit.diff]);
    return SessionChanges(
      edits,
      [
        for (final file in index.files)
          SessionFile(
            file.path,
            [
              for (final (edit, section) in file.sections)
                (edits[edit], edits[edit].diff.files[section]),
            ],
            added: file.added,
            removed: file.removed,
          ),
      ],
      added: index.added,
      removed: index.removed,
    );
  }

  /// The edits, oldest first.
  final List<SessionEdit> edits;

  /// The files they touched, by path.
  final List<SessionFile> files;

  /// Whether the transcript holds no edit with a diff.
  bool get isEmpty => edits.isEmpty;

  /// Lines added across every edit.
  final int added;

  /// Lines removed across every edit.
  final int removed;

  /// The edit from item [id], if it is one.
  SessionEdit? edit(String id) {
    for (final edit in edits) {
      if (edit.id == id) return edit;
    }
    return null;
  }
}

/// Rebuild the native review index only when edit metadata changes. Ordinary
/// text deltas do not re-index, and stale completions never replace a new view.
class SessionChangesView extends StatefulWidget {
  const SessionChangesView({
    super.key,
    required this.api,
    required this.items,
    required this.builder,
  });
  final BridgeApi api;
  final List<TranscriptItem> items;
  final Widget Function(SessionChanges) builder;
  @override
  State<SessionChangesView> createState() => _SessionChangesViewState();
}

class _SessionChangesViewState extends State<SessionChangesView> {
  List<(String, String, int?, DiffModel)> _source = [];
  SessionChanges? _changes;
  Object? _error;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant SessionChangesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refresh(force: !identical(oldWidget.api, widget.api));
  }

  void _refresh({bool force = false}) {
    final source = [
      for (final item in widget.items)
        if (item.type == 'fileChange' &&
            item.diff != null &&
            !item.diff!.isEmpty)
          (item.id, item.turnId, item.turnCompletedAt, item.diff!),
    ];
    if (!force && _changes != null && listEquals(_source, source)) return;
    // An unchanged in-flight request already owns this revision.
    if (!force &&
        _revision > 0 &&
        _changes == null &&
        _error == null &&
        listEquals(_source, source)) {
      return;
    }
    _source = source;
    _error = null;
    final revision = ++_revision;
    if (source.isEmpty) {
      _changes = SessionChanges.empty;
      return;
    }
    final edits = [
      for (var i = 0; i < source.length; i++)
        SessionEdit(
          id: source[i].$1,
          turnId: source[i].$2,
          completedAt: source[i].$3,
          diff: source[i].$4,
          index: i + 1,
        ),
    ];
    SessionChanges.project(widget.api, edits).then(
      (changes) {
        if (!mounted || revision != _revision) return;
        setState(() => _changes = changes);
      },
      onError: (Object error) {
        if (!mounted || revision != _revision) return;
        setState(() => _error = error);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: TextButton(
          onPressed: () => setState(() => _refresh(force: true)),
          child: Text(AppLocalizations.of(context).retry),
        ),
      );
    }
    final changes = _changes;
    return changes == null
        ? const Center(child: CircularProgressIndicator())
        : widget.builder(changes);
  }
}
