import 'package:file_selector/file_selector.dart' show getDirectoryPath;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as paths;
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/widgets/error_retry.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/error_format.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/attachment_refs.dart';

/// Show the host folder chooser and return the absolute host path the user
/// picks, or null if they cancel.
///
/// What it offers is only what the host really supports: [recent] projects
/// (from the host's own session list), browsing inside the configured
/// project roots (the host refuses any other listing), a typed absolute path
/// (checked by the host when a conversation starts there), and — only when
/// this desktop is the host — the native folder dialog. Each opened folder is
/// one bounded listing; nothing walks the disk. Rendered as a bottom sheet on
/// a phone and a dialog on desktop.
Future<String?> showFolderPicker(
  BuildContext context, {
  required String serviceKey,
  String? initialPath,
  List<String> recent = const [],
}) => showAdaptivePanel<String>(
  context: context,
  // The body brings its own scrollable list.
  scrollable: false,
  // And its own header row, which is its top edge.
  insetTop: false,
  maxWidth: 640,
  builder: (_) => _FolderTreePicker(
    serviceKey: serviceKey,
    initialPath: initialPath,
    recent: recent,
  ),
);

/// Whether [path] is absolute on either a Unix or a Windows host.
bool isAbsoluteHostPath(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

/// The chooser body.
class _FolderTreePicker extends ConsumerStatefulWidget {
  const _FolderTreePicker({
    required this.serviceKey,
    required this.recent,
    this.initialPath,
  });

  final String serviceKey;
  final String? initialPath;
  final List<String> recent;

  @override
  ConsumerState<_FolderTreePicker> createState() => _FolderTreePickerState();
}

class _FolderTreePickerState extends ConsumerState<_FolderTreePicker> {
  // Configured roots (fetched once). Empty until loaded / when none configured.
  List<String> _roots = const [];
  // Browse stack: the chain of folders drilled into. Empty = the start page.
  final List<String> _stack = [];
  List<HostDirEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  // Only the newest listing may land: a quick second click wins.
  int _listing = 0;
  // This desktop is the host, so its native folder dialog shows host paths.
  bool _local = false;
  bool _pickingLocal = false;
  String? _pickerError;
  // The location bar is a path field.
  bool _editing = false;
  final TextEditingController _path = TextEditingController();
  final FocusNode _pathFocus = FocusNode();
  // A typed absolute path outside the roots, chosen as it is.
  String? _typed;
  String? _pathError;

  /// The folder currently shown (null on the start page).
  String? get _current => _stack.isEmpty ? null : _stack.last;

  /// The folder "Use this folder" returns.
  String? get _target => _typed ?? _current;

  @override
  void initState() {
    super.initState();
    _loadRoots();
    _probeLocal();
  }

  @override
  void dispose() {
    _path.dispose();
    _pathFocus.dispose();
    super.dispose();
  }

  /// Best-effort: an unreachable answer means "not this device".
  Future<void> _probeLocal() async {
    if (!isDesktop) return;
    try {
      final local = await ref
          .read(bridgeApiProvider)
          .metaHostIsLocal(widget.serviceKey);
      if (mounted && local) setState(() => _local = true);
    } catch (_) {}
  }

  Future<void> _loadRoots() async {
    final listing = ++_listing;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cfg = await ref
          .read(bridgeApiProvider)
          .metaProjectConfig(widget.serviceKey);
      if (!mounted || listing != _listing) return;
      _roots = cfg.projectRoots;
      // Open where the caller pointed us (the conversation's current folder)
      // when it sits inside a configured root, so "up" walks back out.
      final start = widget.initialPath?.trim();
      if (start != null && _seedStack(start)) {
        await _loadDir(_stack.last);
      } else if (_roots.length == 1 && widget.recent.isEmpty) {
        // A single root and nothing else to offer: drop straight into it.
        _stack.add(_roots.first);
        await _loadDir(_roots.first);
      } else {
        setState(() {
          _entries = const [];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted && listing == _listing) {
        setState(() {
          _error = friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  /// Rebuild [_stack] down to [path] when it is a configured root or a
  /// folder inside one. Returns whether it did.
  bool _seedStack(String path) {
    for (final root in _roots) {
      final windows =
          root.startsWith(r'\\') || RegExp(r'^[A-Za-z]:').hasMatch(root);
      final host = paths.Context(
        style: windows ? paths.Style.windows : paths.Style.posix,
      );
      final base = host.normalize(root);
      final target = host.normalize(path);
      if (!host.equals(base, target) && !host.isWithin(base, target)) continue;
      final ancestors = <String>[target];
      while (!host.equals(ancestors.last, base)) {
        ancestors.add(host.dirname(ancestors.last));
      }
      _stack
        ..clear()
        ..addAll(ancestors.reversed);
      return true;
    }
    return false;
  }

  Future<void> _loadDir(String path) async {
    final listing = ++_listing;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await ref
          .read(bridgeApiProvider)
          .metaListDir(widget.serviceKey, path);
      if (!mounted || listing != _listing) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || listing != _listing) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  void _enter(String path) {
    setState(() {
      _typed = null;
      _stack.add(path);
    });
    _loadDir(path);
  }

  /// Show crumb [index] of the stack, or the start page for -1.
  Future<void> _jumpTo(int index) async {
    if (index >= _stack.length - 1 && index >= 0) return;
    ++_listing; // whatever was being listed no longer lands
    setState(() {
      _typed = null;
      _stack.removeRange(index + 1, _stack.length);
      if (_stack.isEmpty) {
        _entries = const [];
        _loading = false;
        _error = null;
      }
    });
    if (_stack.isNotEmpty) await _loadDir(_stack.last);
  }

  /// Go up one level: to the parent folder, or back to the start page.
  Future<void> _up() => _jumpTo(_stack.length - 2);

  void _toggleEditing() {
    setState(() {
      _editing = !_editing;
      _pathError = null;
      if (_editing) _path.text = _target ?? '';
    });
    if (_editing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pathFocus.requestFocus();
      });
    }
  }

  /// A typed path: browsed when it lies inside a project root, otherwise
  /// chosen as it is (the host checks it when the conversation starts).
  void _submitPath(String raw) {
    final path = raw.trim();
    if (path.isEmpty) return;
    if (!isAbsoluteHostPath(path)) {
      setState(
        () => _pathError = AppLocalizations.of(context).folderPathAbsolute,
      );
      return;
    }
    setState(() {
      _pathError = null;
      _editing = false;
    });
    if (_seedStack(path)) {
      setState(() => _typed = null);
      _loadDir(_stack.last);
    } else {
      ++_listing;
      setState(() {
        _stack.clear();
        _entries = const [];
        _loading = false;
        _error = null;
        _typed = path;
      });
    }
  }

  /// This desktop is the host: its own folder dialog reaches any folder.
  Future<void> _pickLocal() async {
    if (_pickingLocal) return;
    setState(() {
      _pickingLocal = true;
      _pickerError = null;
    });
    try {
      final dir = await getDirectoryPath();
      if (dir != null && mounted) Navigator.of(context).pop(dir);
    } catch (e) {
      if (mounted) setState(() => _pickerError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _pickingLocal = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // A plain bounded column, so this body works in BOTH forms the adaptive
    // panel opens: a centred dialog on desktop and a bottom sheet on a phone.
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              if (_stack.isNotEmpty)
                IconButton(
                  key: const Key('folder-up-btn'),
                  icon: const Icon(AppIcons.arrow_back),
                  tooltip: l10n.folderUp,
                  onPressed: _loading ? null : _up,
                )
              else
                const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _current == null
                      ? l10n.pickFolderTitle
                      : folderName(_current!),
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_local)
                IconButton(
                  key: const Key('folder-local-btn'),
                  tooltip: l10n.folderOnThisComputer,
                  icon: const Icon(AppIcons.computer_outlined),
                  onPressed: _pickingLocal ? null : _pickLocal,
                ),
              IconButton(
                key: const Key('folder-edit-path'),
                tooltip: l10n.folderTypePath,
                isSelected: _editing,
                icon: const Icon(AppIcons.edit_location_alt_outlined),
                onPressed: _toggleEditing,
              ),
            ],
          ),
        ),
        _locationBar(l10n, scheme),
        if (_pickerError != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _pickerError!,
              key: const Key('folder-local-error'),
              style: TextStyle(color: scheme.error),
            ),
          ),
        const Divider(height: 1),
        Expanded(child: _body(l10n, scheme)),
        _footer(l10n, scheme),
      ],
    );
  }

  /// Where the user is: a breadcrumb whose every crumb jumps back there, or
  /// — while editing — a path field.
  Widget _locationBar(AppLocalizations l10n, ColorScheme scheme) {
    if (_editing) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: TextField(
          key: const Key('folder-path-field'),
          controller: _path,
          focusNode: _pathFocus,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.go,
          onSubmitted: _submitPath,
          style: const TextStyle(fontFamily: monoFontFamily, fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            labelText: l10n.folderPathFieldLabel,
            hintText: l10n.remotePathHint,
            errorText: _pathError,
            errorMaxLines: 3,
            suffixIcon: IconButton(
              key: const Key('folder-path-go'),
              tooltip: l10n.folderTypePath,
              icon: const Icon(AppIcons.arrow_forward),
              onPressed: () => _submitPath(_path.text),
            ),
          ),
        ),
      );
    }
    final crumbs = <Widget>[
      _crumb(
        const Key('folder-crumb-top'),
        l10n.folderBreadcrumbTop,
        current: _stack.isEmpty && _typed == null,
        onTap: () => _jumpTo(-1),
        scheme: scheme,
      ),
      for (var i = 0; i < _stack.length; i++)
        _crumb(
          Key('folder-crumb-$i'),
          i == 0 ? _stack[i] : folderName(_stack[i]),
          current: i == _stack.length - 1,
          onTap: () => _jumpTo(i),
          scheme: scheme,
        ),
      if (_typed != null)
        _crumb(
          const Key('folder-crumb-typed'),
          _typed!,
          current: true,
          onTap: null,
          scheme: scheme,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: SingleChildScrollView(
          key: const Key('folder-breadcrumb'),
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: Row(
            children: [
              for (var i = 0; i < crumbs.length; i++) ...[
                if (i > 0)
                  Icon(
                    AppIcons.chevron_right,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                crumbs[i],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _crumb(
    Key key,
    String label, {
    required bool current,
    required VoidCallback? onTap,
    required ColorScheme scheme,
  }) {
    final text = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: current ? FontWeight.w600 : FontWeight.w400,
          color: current ? scheme.onSurface : scheme.onSurfaceVariant,
        ),
      ),
    );
    final padded = ConstrainedBox(
      constraints: BoxConstraints(minHeight: isDesktop ? 30 : 44),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Center(widthFactor: 1, child: text),
      ),
    );
    return Tooltip(
      message: label,
      child: current || onTap == null || _loading
          ? Semantics(key: key, selected: current, child: padded)
          : InkWell(
              key: key,
              mouseCursor: clickable,
              borderRadius: BorderRadius.circular(kRowRadius),
              onTap: onTap,
              child: padded,
            ),
    );
  }

  Widget _body(AppLocalizations l10n, ColorScheme scheme) {
    if (_loading) {
      // Not a bare spinner: retries happen HERE, and the progress stream is
      // live-only, so something has to be watching while they run.
      return const LoadingWithRetry();
    }
    if (_error != null) {
      return ErrorRetry(
        message: _error!,
        errorKey: const Key('folder-picker-error'),
        onRetry: () => _current == null ? _loadRoots() : _loadDir(_current!),
      );
    }
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    if (_typed != null) {
      return _notice(
        const Key('folder-outside-note'),
        AppIcons.info_outline,
        l10n.folderOutsideRootsNote,
        muted,
      );
    }
    if (_stack.isNotEmpty) {
      if (_entries.isEmpty) {
        return _notice(
          const Key('folder-picker-empty'),
          AppIcons.folder_open_outlined,
          l10n.folderNoSubfolders,
          muted,
        );
      }
      return ListView.builder(
        itemCount: _entries.length,
        itemBuilder: (context, i) => _folderRow(l10n, scheme, _entries[i]),
      );
    }
    return ListView(children: _startPage(l10n, scheme, muted));
  }

  Widget _notice(Key key, IconData icon, String text, TextStyle style) =>
      ScrollableCenter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 28, color: style.color),
              const SizedBox(height: 10),
              Text(text, key: key, textAlign: TextAlign.center, style: style),
            ],
          ),
        ),
      );

  /// The start page: recent projects (one tap uses one), the configured
  /// project folders (browse), or — with none — the ways that still work.
  List<Widget> _startPage(
    AppLocalizations l10n,
    ColorScheme scheme,
    TextStyle muted,
  ) => [
    if (widget.recent.isNotEmpty) ...[
      _section(l10n.recentProjects, scheme),
      for (final p in widget.recent)
        ListTile(
          key: Key('folder-recent-$p'),
          dense: isDesktop,
          leading: Icon(AppIcons.history, color: scheme.onSurfaceVariant),
          title: Text(
            folderName(p),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            p,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: monoFontFamily, fontSize: 11),
          ),
          onTap: () => Navigator.of(context).pop(p),
        ),
    ],
    if (_roots.isNotEmpty) ...[
      _section(l10n.projectFolders, scheme),
      for (final r in _roots)
        _folderRow(
          l10n,
          scheme,
          HostDirEntry(name: folderName(r), path: r),
          subtitle: r,
        ),
    ] else
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
        child: Column(
          children: [
            Text(
              l10n.folderPickerNoRoots,
              key: const Key('folder-picker-no-roots'),
              textAlign: TextAlign.center,
              style: muted,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.folderPickerNoRootsHint,
              textAlign: TextAlign.center,
              style: muted,
            ),
            const SizedBox(height: 14),
            _startActions(l10n),
          ],
        ),
      ),
  ];

  Widget _startActions(AppLocalizations l10n) => Wrap(
    alignment: WrapAlignment.center,
    spacing: 8,
    runSpacing: 8,
    children: [
      if (_local)
        FilledButton.tonalIcon(
          key: const Key('folder-local-start'),
          onPressed: _pickingLocal ? null : _pickLocal,
          icon: const Icon(AppIcons.computer_outlined, size: 18),
          label: Text(l10n.folderOnThisComputer),
        ),
      OutlinedButton.icon(
        key: const Key('folder-type-start'),
        onPressed: _editing ? null : _toggleEditing,
        icon: const Icon(AppIcons.edit_location_alt_outlined, size: 18),
        label: Text(l10n.folderTypePath),
      ),
    ],
  );

  Widget _section(String label, ColorScheme scheme) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _folderRow(
    AppLocalizations l10n,
    ColorScheme scheme,
    HostDirEntry e, {
    String? subtitle,
  }) => ListTile(
    key: Key('folder-row-${e.path}'),
    dense: isDesktop,
    leading: Icon(
      e.isGitRepo ? AppIcons.source_outlined : AppIcons.folder_outlined,
      color: e.isGitRepo ? scheme.primary : scheme.onSurfaceVariant,
    ),
    title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: e.isGitRepo
        ? Text(
            l10n.gitRepoLabel,
            style: TextStyle(fontSize: 11, color: scheme.primary),
          )
        : subtitle == null
        ? null
        : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: const Icon(AppIcons.chevron_right, size: 20),
    onTap: _loading ? null : () => _enter(e.path),
  );

  /// The confirmation: which folder will be used, and the two exits.
  Widget _footer(AppLocalizations l10n, ColorScheme scheme) {
    final target = _target;
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (target != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text.rich(
                    TextSpan(
                      text: '${l10n.folderWillUse}  ',
                      children: [
                        TextSpan(
                          text: target,
                          style: TextStyle(
                            fontFamily: monoFontFamily,
                            fontFamilyFallback: monoCjkFallback,
                            color: scheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                    key: const Key('folder-target'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              // Too narrow for both (large text): the confirmation goes on
              // top and Cancel under it.
              OverflowBar(
                alignment: MainAxisAlignment.spaceBetween,
                spacing: 8,
                overflowAlignment: OverflowBarAlignment.end,
                overflowDirection: VerticalDirection.up,
                overflowSpacing: 4,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.cancel),
                  ),
                  FilledButton.icon(
                    key: const Key('folder-use-btn'),
                    onPressed: target == null || _loading
                        ? null
                        : () => Navigator.of(context).pop(target),
                    icon: const Icon(AppIcons.check, size: 18),
                    label: Text(l10n.useThisFolder),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
