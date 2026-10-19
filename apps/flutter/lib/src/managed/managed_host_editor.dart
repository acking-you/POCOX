import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/hosting/host_names.dart';
import 'package:pocket_codex/src/hosting/model_service_section.dart';
import 'package:pocket_codex/src/managed/managed_providers.dart';
import 'package:pocket_codex/src/managed/management_failure.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';
import 'package:pocket_codex/src/widgets/group_card.dart';
import 'package:pocket_codex/src/widgets/utility_page.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';

/// Open the editor for [host] on the remote computer behind [serviceKey], or
/// for a new service of runtime [kind] (`codex`, `opencode`, `claude`).
Future<void> showManagedHostEditor(
  BuildContext context, {
  required String serviceKey,
  required String device,
  ManagedHost? host,
  String? kind,
  Set<String> takenNames = const {},
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ManagedHostEditor(
      serviceKey: serviceKey,
      device: device,
      host: host,
      kind: kind,
      takenNames: takenNames,
    ),
  ),
);

/// The remote counterpart of the hosting editor: one service on another
/// computer, managed through its `host:` key.
///
/// Only restricted runtime choices cross the boundary (no executable path or
/// argv). Every mutation names what was read: Save the revision, Apply that
/// revision and the running incarnation, Stop the incarnation. A conflict
/// keeps the edits and asks for a reload; an unknown outcome (a lost
/// response) refreshes the state and is never resent automatically. Keys are
/// write-only: kept, replaced or removed explicitly; a masked URL, an
/// unedited runtime and unchanged Claude secrets keep their stored values.
class ManagedHostEditor extends ConsumerStatefulWidget {
  /// Creates the editor.
  const ManagedHostEditor({
    super.key,
    required this.serviceKey,
    required this.device,
    this.host,
    this.kind,
    this.takenNames = const {},
  }) : assert(host != null || kind != null);

  /// The computer's management key.
  final String serviceKey;

  /// The computer's device name, for the title.
  final String device;

  /// The service edited; null creates one of [kind].
  final ManagedHost? host;

  /// A new service's runtime.
  final String? kind;

  /// Names already used on that computer.
  final Set<String> takenNames;

  @override
  ConsumerState<ManagedHostEditor> createState() => _ManagedHostEditorState();
}

class _ManagedHostEditorState extends ConsumerState<ManagedHostEditor> {
  final _draft = ModelServiceDraft();
  final _name = TextEditingController();
  final _port = TextEditingController();
  final _proxy = TextEditingController();

  /// The host as last read: the revision and incarnation every mutation
  /// names. Null until a new service was created.
  ManagedHost? _host;
  String _savedPort = '';
  String _savedProxy = '';
  bool _busy = false;
  bool _conflict = false;
  bool _leaveConfirmed = false;
  String? _notice;
  String? _error;

  BridgeApi get _api => ref.read(bridgeApiProvider);

  /// The runtime kind: the new service's, or the host's engine. A saved
  /// ACP agent is the Claude preset only by its profile; any other agent
  /// stays `acp` with its own (conservative) support.
  String get _kind {
    final host = _host;
    if (host == null) return widget.kind!;
    return managedHostKind(host);
  }

  bool get _fresh => _host == null;

  @override
  void initState() {
    super.initState();
    _host = widget.host;
    _draft.restrict(_support(_kind));
    final host = widget.host;
    if (host != null) {
      _adopt(host);
    } else {
      _name.text = _defaultName(widget.kind!);
      _port.text = '0';
    }
    for (final c in [_name, _port, _proxy]) {
      c.addListener(_rebuild);
    }
    _draft.addListener(_rebuild);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  HostConfigSupport _support(String kind) => switch (kind) {
    'opencode' => _api.hostConfigSupported(engine: 'opencode'),
    'claude' => _api.hostConfigSupported(spec: _claudeSpec),
    'grok' => _api.hostConfigSupported(spec: _grokSpec),
    // The saved agent's profile decides; without one, an unknown profile
    // (existing configuration only).
    'acp' => _api.hostConfigSupported(
      spec: _host == null
          ? _unknownAgent
          : managedAgent(_host!) ?? _unknownAgent,
    ),
    _ => _api.hostConfigSupported(),
  };

  static const _unknownAgent = AcpAgentSpec(
    profileId: 'unknown',
    displayName: '',
    program: '',
  );

  static const _claudeSpec = AcpAgentSpec(
    profileId: 'claude',
    displayName: 'Claude',
    program: 'claude-agent-acp',
  );

  static const _grokSpec = AcpAgentSpec(
    profileId: 'grok',
    displayName: 'Grok',
    program: 'grok',
    args: ['agent', '--no-leader', 'stdio'],
  );

  String _defaultName(String kind) => uniqueHostName(kind, widget.takenNames);

  /// The name on that computer a new service's typed name collides with.
  String? get _nameClash =>
      _fresh ? hostNameClash(_name.text, widget.takenNames) : null;

  /// Show [host] in every field, discarding edits (a load, a save, or an
  /// explicit reload).
  void _adopt(ManagedHost host) {
    _host = host;
    _conflict = false;
    _draft.load(host.config);
    final runtime = host.config.runtime ?? host.config.active?.runtime;
    _savedPort = '${runtime?.port ?? 0}';
    _savedProxy = runtime?.proxy ?? '';
    _port.text = _savedPort;
    _proxy.text = _savedProxy;
  }

  @override
  void dispose() {
    _draft.dispose();
    _name.dispose();
    _port.dispose();
    _proxy.dispose();
    super.dispose();
  }

  bool get _runtimeDirty =>
      _kind == 'codex' &&
      (_port.text.trim() != _savedPort || _proxy.text.trim() != _savedProxy);

  bool get _dirty => _fresh || _draft.dirty || _runtimeDirty;

  /// The runtime a save sends: null (keep everything stored) unless the
  /// Codex port or proxy was edited; an unedited proxy beside a new port is
  /// kept on the host.
  ManagedRuntime? _runtimeEdit() {
    if (!_runtimeDirty) return null;
    final proxyEdited = _proxy.text.trim() != _savedProxy;
    final proxy = _proxy.text.trim();
    return ManagedRuntime(
      kind: 'codex',
      port: int.tryParse(_port.text.trim()) ?? 0,
      proxy: proxyEdited && proxy.isNotEmpty ? proxy : null,
      keepProxy: !proxyEdited,
    );
  }

  bool get _keepBaseUrl {
    final host = _host;
    return host != null &&
        host.baseUrlMasked &&
        _draft.source == 'custom' &&
        _draft.baseUrl.text.trim() == (host.config.baseUrl ?? '');
  }

  String? _problem(AppLocalizations l10n) {
    if (_host?.config.problem != null) return null;
    if (_fresh && _name.text.trim().isEmpty) return l10n.managedNameRequired;
    if (_nameClash case final other?) return l10n.managedNameInUse(other);
    final port = int.tryParse(_port.text.trim());
    if (_kind == 'codex' && (port == null || port < 0 || port > 65535)) {
      return l10n.managedPortInvalid;
    }
    return _draft.problem(l10n, fresh: _fresh);
  }

  /// Run one mutation: pending while it runs, its own result after. An
  /// unknown outcome refreshes the host and never repeats the request.
  Future<void> _run(Future<String?> Function() operation) async {
    if (_busy || !mounted) return;
    final l10n = AppLocalizations.of(context);
    // The container outlives this page: the panel's re-read still happens
    // after the page is left.
    final container = ProviderScope.containerOf(context, listen: false);
    final key = widget.serviceKey;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final notice = await operation();
      if (!mounted) return;
      setState(() => _notice = notice);
    } catch (e) {
      if (!mounted) return;
      final failure = ManagementFailure.of(e);
      setState(() {
        _error = managedFailureText(l10n, failure);
        if (failure.conflict) _conflict = true;
      });
      if (failure.uncertain || failure.code == 'host_changed') {
        await _refresh(keepEdits: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      container.invalidate(managedDeviceProvider(key));
    }
  }

  /// Re-read the host. With [keepEdits], fields stay as typed; a revision
  /// that moved meanwhile becomes a reload prompt instead of an overwrite.
  Future<void> _refresh({bool keepEdits = false}) async {
    final name = _host?.name ?? _name.text.trim();
    try {
      final device = await _api.managedDevice(widget.serviceKey);
      if (!mounted) return;
      final fresh = device.hosts.where((h) => h.name == name).firstOrNull;
      if (fresh == null) return;
      setState(() {
        final before = _host;
        if (!keepEdits || before == null || !_dirty) {
          _adopt(fresh);
        } else {
          if (fresh.config.revision != before.config.revision) {
            _conflict = true;
          }
          _host = fresh;
        }
      });
    } catch (_) {
      // The shown error already says to refresh; the panel retries.
    }
  }

  Future<void> _save() => _run(() async {
    final host = _host!;
    final l10n = AppLocalizations.of(context);
    final saved = await _api.managedHostSave(
      widget.serviceKey,
      host.name,
      ManagedHostEdit(
        input: _draft.input,
        keyAction: _draft.keyAction(fresh: false),
        key: _draft.typedKey,
        expectedRevision: host.config.revision,
        runtime: _runtimeEdit(),
        keepBaseUrl: _keepBaseUrl,
      ),
    );
    if (!mounted) return null;
    setState(() => _adopt(saved));
    return saved.running ? l10n.hostConfigSaved : l10n.managedSaved;
  });

  Future<void> _create() => _run(() async {
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    final runtime = _kind == 'codex'
        ? ManagedRuntime(
            kind: 'codex',
            port: int.tryParse(_port.text.trim()) ?? 0,
            proxy: _proxy.text.trim().isEmpty ? null : _proxy.text.trim(),
          )
        : ManagedRuntime(kind: _kind);
    final created = await _api.managedHostStart(
      widget.serviceKey,
      name: name,
      runtime: runtime,
      input: _draft.input,
      keyAction: _draft.keyAction(fresh: true),
      key: _draft.typedKey,
    );
    if (!mounted) return null;
    setState(() => _adopt(created));
    return l10n.managedStarted(created.name);
  });

  Future<void> _startSaved() => _run(() async {
    final host = _host!;
    final l10n = AppLocalizations.of(context);
    final started = await _api.managedHostStartSaved(
      widget.serviceKey,
      host.name,
      expectedRevision: host.config.revision,
    );
    if (!mounted) return null;
    setState(() => _adopt(started));
    return l10n.managedStarted(started.name);
  });

  Future<void> _apply() async {
    final host = _host!;
    final incarnation = host.config.active?.incarnation;
    if (incarnation == null) return;
    final key = widget.serviceKey;
    final l10n = AppLocalizations.of(context);
    if (!await _confirm(
          l10n.hostApplyConfirmTitle(host.name),
          l10n.hostApplyConfirmBody,
          l10n.hostApplyRestart,
        ) ||
        !_sameTarget(key, host)) {
      return;
    }
    await _run(() async {
      final r = await _api.managedHostApply(
        widget.serviceKey,
        host.name,
        expectedIncarnation: incarnation,
        expectedRevision: host.config.revision,
      );
      await _refresh();
      if (r.applied) return l10n.hostApplied;
      // The host answered: its failure is definite, not an unknown outcome.
      if (mounted) {
        setState(
          () => _error = r.restoredPrevious
              ? l10n.hostApplyRestored(r.error ?? '')
              : l10n.hostApplyStopped(r.error ?? '', r.restoreError ?? ''),
        );
      }
      return null;
    });
  }

  Future<void> _stop() async {
    final host = _host!;
    final incarnation = host.config.active?.incarnation;
    if (incarnation == null) return;
    final key = widget.serviceKey;
    final l10n = AppLocalizations.of(context);
    if (!await _confirm(
          l10n.managedStopConfirmTitle(host.name),
          l10n.managedStopConfirmBody,
          l10n.stopHosting,
        ) ||
        !_sameTarget(key, host)) {
      return;
    }
    await _run(() async {
      await _api.managedHostStop(
        widget.serviceKey,
        host.name,
        expectedIncarnation: incarnation,
      );
      await _refresh(keepEdits: true);
      return l10n.managedStopped(host.name);
    });
  }

  /// Whether the page still shows the computer and host observed before a
  /// confirmation: a changed destination is never acted on.
  bool _sameTarget(String key, ManagedHost host) =>
      mounted && key == widget.serviceKey && identical(_host, host) && !_busy;

  Future<bool> _confirm(String title, String body, String action) async =>
      await confirmManaged(context, title, body, action) && mounted;

  /// Leaving loses nothing (or was confirmed): a new service whose model
  /// service is untouched has only suggested fields.
  bool get _clean => _leaveConfirmed || !_dirty || (_fresh && !_draft.dirty);

  Future<bool> _confirmLeave() async {
    if (_busy) return false;
    if (_clean) return true;
    final l10n = AppLocalizations.of(context);
    final leave = await _confirm(
      l10n.hostLeaveTitle,
      l10n.hostLeaveBody,
      l10n.hostLeaveDiscard,
    );
    if (leave) setState(() => _leaveConfirmed = true);
    return leave;
  }

  bool get _canLeave => !_busy && _clean;

  Widget _runtimeSection(AppLocalizations l10n) {
    final host = _host;
    final status = host?.status;
    final scheme = Theme.of(context).colorScheme;
    return GroupCard(
      key: const Key('managed-runtime-section'),
      title: l10n.hostRuntimeInfo,
      // Where the program and its arguments are managed.
      info: l10n.managedRuntimeNote,
      children: [
        EditorBlock(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  managedKindIcon(
                    _kind,
                    profileId: host == null ? null : managedProfile(host),
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      managedKindLabel(
                        l10n,
                        _kind,
                        agentName: host == null
                            ? null
                            : managedAgent(host)?.displayName,
                      ),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  managedStateChip(context, host),
                ],
              ),
              const SizedBox(height: 12),
              if (_fresh)
                FocusHelp(
                  help: _nameClash == null ? l10n.managedNameHelper : null,
                  child: TextField(
                    key: const Key('managed-name'),
                    controller: _name,
                    enabled: !_busy,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l10n.localHostName,
                      errorText: switch (_nameClash) {
                        final other? => l10n.managedNameInUse(other),
                        null => null,
                      },
                    ),
                  ),
                )
              else
                SelectableText(
                  host!.name,
                  key: const Key('managed-host-name'),
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              if (_kind == 'codex') ...[
                const SizedBox(height: 14),
                FocusHelp(
                  help: l10n.managedPortHelper,
                  child: TextField(
                    key: const Key('managed-port'),
                    controller: _port,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: l10n.managedPortLabel,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // Empty inherits; the placeholder says so while typing.
                TextField(
                  key: const Key('managed-proxy'),
                  controller: _proxy,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: l10n.hostProxyLabel,
                    hintText: l10n.hostProxyInherit,
                  ),
                ),
              ],
              if (status != null && host!.config.pendingApply) ...[
                const SizedBox(height: 8),
                EditorNote(
                  l10n.hostConfigPending,
                  key: const Key('managed-pending-apply'),
                  color: cautionColor(scheme),
                ),
              ],
              if (host?.restoreProblem case final problem?) ...[
                const SizedBox(height: 8),
                EditorNote(
                  l10n.managedRestoreProblem(problem),
                  key: const Key('managed-restore-problem'),
                  color: cautionColor(scheme),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _actions(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final host = _host;
    final problem = _problem(l10n);
    final unreadable = host?.config.problem != null;
    final running = host?.running ?? false;
    final incarnation = host?.config.active?.incarnation;
    final idle = !_busy && !_conflict;
    final buttons = <Widget>[
      TextButton(
        key: const Key('managed-close'),
        onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
        child: Text(
          _fresh
              ? l10n.cancel
              : MaterialLocalizations.of(context).closeButtonLabel,
        ),
      ),
      if (_fresh)
        FilledButton(
          key: const Key('managed-create'),
          onPressed: idle && problem == null ? _create : null,
          child: Text(l10n.startHosting),
        )
      else ...[
        if (running)
          OutlinedButton(
            key: const Key('managed-stop'),
            style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
            onPressed: !_busy && incarnation != null ? _stop : null,
            child: Text(l10n.stopHosting),
          ),
        if (!unreadable)
          OutlinedButton(
            key: const Key('managed-save'),
            onPressed: idle && problem == null && _dirty ? _save : null,
            child: Text(l10n.hostSaveConfig),
          ),
        if (running && host!.config.pendingApply && !unreadable)
          FilledButton(
            key: const Key('managed-apply'),
            onPressed: idle && !_dirty && incarnation != null ? _apply : null,
            child: Text(l10n.hostApplyRestart),
          ),
        if (!running && !unreadable)
          FilledButton(
            key: const Key('managed-start-saved'),
            onPressed: idle && !_dirty ? _startSaved : null,
            child: Text(l10n.managedStart),
          ),
      ],
    ];
    return EditorActionBar(
      children: [
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(
              key: Key('managed-pending'),
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ...buttons,
      ],
    );
  }

  List<Widget> _messages(AppLocalizations l10n, ColorScheme scheme) => [
    if (_host?.config.problem case final problem?)
      EditorNote(
        l10n.managedConfigUnreadable(problem),
        key: const Key('managed-config-problem'),
        color: scheme.error,
      ),
    if (_conflict)
      EditorNote(
        l10n.managedConflict,
        key: const Key('managed-conflict'),
        color: cautionColor(scheme),
        action: TextButton(
          key: const Key('managed-reload'),
          onPressed: _busy ? null : () => _refresh(),
          child: Text(l10n.hostConfigReload),
        ),
      ),
    if (_notice case final notice?)
      Text(
        notice,
        key: const Key('managed-notice'),
        style: TextStyle(color: successColor(scheme)),
      ),
    if (_error case final error?)
      Text(
        error,
        key: const Key('managed-error'),
        style: TextStyle(color: scheme.error),
      ),
  ];

  /// The sections and outcome lines; [inline] puts the actions under them.
  Widget _form(
    AppLocalizations l10n,
    ColorScheme scheme, {
    required bool inline,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _runtimeSection(l10n),
      const SizedBox(height: 12),
      // An unreadable record is never shown as fields: its placeholders
      // must not be saved as configuration.
      if (_host?.config.problem == null) ...[
        ModelServiceSection(
          draft: _draft,
          enabled: !_busy,
          inherited: EditorNote(l10n.managedInheritedNote),
          official: EditorNote(l10n.managedOfficialNote),
        ),
        const SizedBox(height: 12),
      ],
      for (final message in _messages(l10n, scheme))
        Padding(padding: const EdgeInsets.only(top: 4), child: message),
      if (inline) _actions(l10n),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final host = _host;
    return PopScope(
      canPop: _canLeave,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmLeave() && mounted) navigator.pop();
      },
      child: UtilityLeaveGuard(
        confirm: _confirmLeave,
        child: UtilityPage(
          route: '/manage',
          title: host == null
              ? l10n.managedAddTitle(deviceLabel(widget.device))
              : l10n.managedEditTitle(host.name, deviceLabel(widget.device)),
          parent: UtilityParent(title: l10n.manageServices, route: '/manage'),
          // With little room (keyboard up, large text) the actions scroll
          // with the form instead of covering it.
          body: LayoutBuilder(
            builder: (context, box) {
              final inline = box.maxHeight < 420;
              return Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      key: const Key('managed-editor-scroll'),
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 680),
                          child: _form(l10n, scheme, inline: inline),
                        ),
                      ),
                    ),
                  ),
                  if (!inline) ...[
                    Divider(height: 1, color: scheme.outlineVariant),
                    _actions(l10n),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Ask before a remote mutation; true only for an explicit [action].
Future<bool> confirmManaged(
  BuildContext context,
  String title,
  String body,
  String action,
) => confirmEditorAction(
  context,
  title: title,
  body: body,
  action: action,
  dialogKey: const Key('managed-confirm'),
  confirmKey: const Key('managed-confirm-ok'),
);

/// The display name of a runtime kind.
String managedKindLabel(
  AppLocalizations l10n,
  String kind, {
  String? agentName,
}) => switch (kind) {
  'opencode' => 'OpenCode',
  'claude' => 'Claude',
  'grok' => 'Grok',
  'codex' => 'Codex',
  'acp' when agentName != null && agentName.isNotEmpty => agentName,
  _ => l10n.managedKindUnknown,
};

/// The agent mark of runtime [kind] (the Claude and Grok presets are ACP
/// agents); [profileId] names a saved agent's own.
Widget managedKindIcon(String kind, {String? profileId, required double size}) {
  final preset = kind == 'claude' || kind == 'grok';
  return AgentIcon.of(
    provider: preset ? 'acp' : kind,
    profileId: profileId ?? (preset ? kind : null),
    size: size,
  );
}

/// The saved (else running) ACP agent of [host]; its argv is never sent
/// remotely, only its profile and display name matter here.
AcpAgentSpec? managedAgent(ManagedHost host) =>
    host.config.runtime?.agent ?? host.config.active?.runtime.agent;

/// The ACP profile of [host], from its saved agent or its running status.
String? managedProfile(ManagedHost host) =>
    managedAgent(host)?.profileId ?? host.status?.profileId;

/// The runtime kind of an existing [host]: `claude` / `grok` only for those
/// presets' profiles, `acp` for any other agent.
String managedHostKind(ManagedHost host) => switch (host.engine) {
  'acp' => switch (managedProfile(host)) {
    final profile? when profile == 'claude' || profile == 'grok' => profile,
    _ => 'acp',
  },
  final engine => engine,
};

/// The running / stopped chip of [host] (new when null).
Widget managedStateChip(BuildContext context, ManagedHost? host) {
  final l10n = AppLocalizations.of(context);
  final scheme = Theme.of(context).colorScheme;
  final (label, color) = switch (host) {
    null => (l10n.managedStateNew, scheme.onSurfaceVariant),
    final h when h.config.problem != null => (
      l10n.managedStateNeedsAttention,
      scheme.error,
    ),
    final h when h.running => (l10n.managedStateRunning, successColor(scheme)),
    _ => (l10n.managedStateStopped, scheme.onSurfaceVariant),
  };
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );
}
