import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/managed/management_failure.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:pocket_codex/src/widgets/folder_tree_picker.dart';

/// The host's default project folder: where a new conversation starts when
/// nobody chose a folder. Shows the host's automatic folder (created only
/// when the first conversation needs it), lets it be changed to an existing
/// host folder or reset to automatic, and keeps the browsable roots under
/// Advanced.
///
/// [serviceKey] is any key the host serves project settings on: a session
/// key of a local host, or a remote computer's `host:` management key. Its
/// reads and saves are independent of service management, so a failure here
/// never blocks starting or stopping services.
class DefaultProjectTile extends ConsumerStatefulWidget {
  /// Creates the tile.
  const DefaultProjectTile({
    super.key,
    required this.serviceKey,
    this.local = false,
  });

  /// The host's project-settings key.
  final String serviceKey;

  /// The host is this computer, so its folders can be added with the native
  /// directory picker.
  final bool local;

  @override
  ConsumerState<DefaultProjectTile> createState() => _DefaultProjectTileState();
}

class _DefaultProjectTileState extends ConsumerState<DefaultProjectTile> {
  ProjectSettings? _settings;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  bool _conflict = false;

  /// Moves on every read and on a key change, so a late answer for an
  /// earlier read or another host is dropped.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DefaultProjectTile old) {
    super.didUpdateWidget(old);
    if (old.serviceKey != widget.serviceKey) {
      // Everything shown or pending belonged to the previous host; its late
      // answers are dropped by the generation [_load] moves.
      _settings = null;
      _busy = false;
      _conflict = false;
      _error = null;
      _load();
    }
  }

  /// Mutations wait for an idle, current read: never during a save or a
  /// read, and never after a conflict until an explicit reload.
  bool get _locked => _busy || _loading || _conflict;

  /// Read the host's settings. [keepError] is shown again after a
  /// successful read (a lost save answer's notice), only for this read.
  Future<void> _load({String? keepError}) async {
    final generation = ++_generation;
    final key = widget.serviceKey;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await ref
          .read(bridgeApiProvider)
          .metaProjectSettings(key);
      if (!mounted || generation != _generation) return;
      setState(() {
        _settings = settings;
        _loading = false;
        _conflict = false;
        _error = keepError;
      });
    } catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = ManagementFailure.of(e).message;
        _loading = false;
      });
    }
  }

  Future<void> _save({
    required List<String> roots,
    required String? defaultProject,
  }) async {
    final settings = _settings;
    if (settings == null || _locked) return;
    final generation = ++_generation;
    final key = widget.serviceKey;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await ref
          .read(bridgeApiProvider)
          .metaSaveProjectSettings(
            key,
            projectRoots: roots,
            defaultProject: defaultProject,
            expectedRevision: settings.revision,
          );
      if (!mounted || generation != _generation) return;
      setState(() {
        _settings = saved;
        _busy = false;
      });
      showToastOk(context, l10n.defaultProjectSaved);
    } catch (e) {
      if (!mounted || generation != _generation) return;
      final failure = ManagementFailure.of(e);
      setState(() {
        _busy = false;
        _conflict = failure.conflict;
        _error = failure.conflict
            ? l10n.defaultProjectConflict
            : failure.uncertain
            ? l10n.managedOutcomeUnknown
            : failure.message;
      });
      // A lost answer may still have saved: show what the host has now
      // rather than offering the same save again.
      if (failure.uncertain) unawaited(_load(keepError: _error));
    }
  }

  /// Whether a folder chosen in a dialog may still be saved: the tile shows
  /// the same host and read as when the dialog opened, and is idle.
  bool _current(String key, ProjectSettings settings) =>
      mounted &&
      key == widget.serviceKey &&
      identical(settings, _settings) &&
      !_locked;

  Future<void> _change() async {
    final settings = _settings;
    if (settings == null || _locked) return;
    final key = widget.serviceKey;
    final picked = await showFolderPicker(
      context,
      serviceKey: widget.serviceKey,
      initialPath: settings.effectiveDefault,
      recent: settings.projectRoots,
    );
    final path = picked?.trim();
    if (path == null || path.isEmpty) return;
    // The picker belongs to the host and read it opened for.
    if (!_current(key, settings)) return;
    await _save(roots: settings.projectRoots, defaultProject: path);
  }

  Future<void> _useAutomatic() async {
    final settings = _settings;
    if (settings == null) return;
    await _save(roots: settings.projectRoots, defaultProject: null);
  }

  Future<void> _addRoot() async {
    final settings = _settings;
    if (settings == null || _locked) return;
    final key = widget.serviceKey;
    final path = widget.local
        ? await getDirectoryPath()
        : await _typedFolder(context);
    if (path == null || path.trim().isEmpty) return;
    if (!_current(key, settings)) return;
    final root = path.trim();
    if (settings.projectRoots.contains(root)) return;
    await _save(
      roots: [...settings.projectRoots, root],
      defaultProject: settings.defaultProject,
    );
  }

  Future<void> _removeRoot(String root) async {
    final settings = _settings;
    if (settings == null) return;
    await _save(
      roots: [
        for (final r in settings.projectRoots)
          if (r != root) r,
      ],
      // The default folder is its own setting; removing a browsable root
      // never changes it.
      defaultProject: settings.defaultProject,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final settings = _settings;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final path = settings?.effectiveDefault;
    final children = <Widget>[
      Row(
        children: [
          Icon(Icons.folder_special_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.defaultProjectTitle,
              style: theme.textTheme.titleSmall,
            ),
          ),
          if (_busy || _loading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      const SizedBox(height: 8),
    ];
    if (settings == null && !_loading) {
      children.add(
        Text(
          l10n.defaultProjectUnavailable(_error ?? ''),
          key: const Key('default-project-error'),
          style: TextStyle(color: scheme.error),
        ),
      );
      children.add(
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const Key('default-project-retry'),
            onPressed: _load,
            child: Text(l10n.retry),
          ),
        ),
      );
    } else if (settings != null) {
      children.addAll([
        if (path != null)
          _PathLine(
            key: const Key('default-project-path'),
            path: path,
            automatic: settings.automatic,
          )
        else
          Text(l10n.defaultProjectNone, style: muted),
        if (path != null && settings.automatic && !settings.exists) ...[
          const SizedBox(height: 4),
          Text(l10n.defaultProjectCreatedLater, style: muted),
        ],
        // An older host reports no existence (`exists` false means unknown).
        if (path != null &&
            !settings.automatic &&
            !settings.legacy &&
            !settings.exists) ...[
          const SizedBox(height: 4),
          Text(
            l10n.defaultProjectMissing,
            style: TextStyle(color: cautionColor(scheme)),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            FilledButton.tonalIcon(
              key: const Key('default-project-change'),
              onPressed: _locked ? null : _change,
              icon: const Icon(Icons.drive_file_move_outline, size: 18),
              label: Text(l10n.defaultProjectChange),
            ),
            if (!settings.legacy && !settings.automatic)
              TextButton(
                key: const Key('default-project-automatic'),
                onPressed: _locked ? null : _useAutomatic,
                child: Text(l10n.defaultProjectUseAutomatic),
              ),
          ],
        ),
        _roots(l10n, settings, muted),
      ]);
    }
    if (_error != null && settings != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            _error!,
            key: const Key('default-project-error'),
            style: TextStyle(color: scheme.error),
          ),
        ),
      );
      if (_conflict) {
        children.add(
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('default-project-reload'),
              onPressed: _busy || _loading ? null : _load,
              child: Text(l10n.hostConfigReload),
            ),
          ),
        );
      }
    }
    return Column(
      key: const Key('default-project-tile'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// Browsable roots, folded away: they confine the folder browser and are
  /// rarely changed.
  Widget _roots(
    AppLocalizations l10n,
    ProjectSettings settings,
    TextStyle? muted,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      // An own ink layer: a coloured ancestor would hide the tile's.
      type: MaterialType.transparency,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('default-project-advanced'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 4),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: Text(
            l10n.projectRootsAdvanced(settings.projectRoots.length),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          children: [
            Text(l10n.projectRootsHint, style: muted),
            const SizedBox(height: 6),
            for (final root in settings.projectRoots)
              Row(
                key: Key('project-root-$root'),
                children: [
                  Expanded(
                    child: Tooltip(
                      message: root,
                      child: Text(
                        root,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  IconButton(
                    key: Key('remove-project-$root'),
                    tooltip: l10n.removeProjectFolder,
                    icon: Icon(Icons.close, size: 18, color: scheme.error),
                    onPressed: _locked ? null : () => _removeRoot(root),
                  ),
                ],
              ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                key: const Key('add-project-folder-btn'),
                onPressed: _locked ? null : _addRoot,
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: Text(l10n.addProjectFolder),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A host path that may be long: wraps to two lines, shows in full on long
/// press / hover, and can be copied.
class _PathLine extends StatelessWidget {
  const _PathLine({super.key, required this.path, required this.automatic});

  final String path;
  final bool automatic;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Tooltip(
                message: path,
                child: Text(
                  path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              if (automatic)
                Text(
                  l10n.defaultProjectAutomatic,
                  key: const Key('default-project-automatic-label'),
                  style: TextStyle(fontSize: 12, color: scheme.primary),
                ),
            ],
          ),
        ),
        IconButton(
          key: const Key('default-project-copy'),
          tooltip: l10n.copy,
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: path));
            showToast(context, l10n.copied);
          },
        ),
      ],
    );
  }
}

/// Ask for an absolute host folder by path (a remote host has no native
/// picker here).
Future<String?> _typedFolder(BuildContext context) => showDialog<String>(
  context: context,
  builder: (_) => const _TypedFolderDialog(),
);

class _TypedFolderDialog extends StatefulWidget {
  const _TypedFolderDialog();

  @override
  State<_TypedFolderDialog> createState() => _TypedFolderDialogState();
}

class _TypedFolderDialogState extends State<_TypedFolderDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final path = _controller.text.trim();
    if (isAbsoluteHostPath(path)) Navigator.of(context).pop(path);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.addProjectFolder),
      content: TextField(
        key: const Key('project-root-path'),
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        decoration: InputDecoration(hintText: l10n.projectRootPathHint),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('project-root-add'),
          onPressed: _submit,
          child: Text(l10n.addProjectFolder),
        ),
      ],
    );
  }
}
