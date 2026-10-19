import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/hosting/acp_host_form.dart';
import 'package:pocket_codex/src/hosting/agent_choice_grid.dart';
import 'package:pocket_codex/src/hosting/codex_runtime_section.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/hosting/host_names.dart';
import 'package:pocket_codex/src/hosting/model_service_section.dart';
import 'package:pocket_codex/src/hosting/opencode_runtime_section.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/ui_prefs.dart';

/// Where the edited host's saved configuration is.
enum EditorLoad {
  /// Being read; nothing that depends on it can be saved or applied.
  loading,

  /// Read; the fields show it.
  ready,

  /// The read failed; retry before editing.
  failed,
}

/// The hosting editor's drafts: what is being edited and what it was loaded
/// from.
///
/// A running host is edited only after its saved configuration has been
/// read ([EditorLoad.ready]); its runtime fields are filled from the saved
/// desired runtime, else from what the host runs now ([HostConfig.active]),
/// never from guesses. A later read never overwrites edits: it is held as
/// [newerConfig] until the user reloads. A new host keeps one model-service
/// draft and one agent form value per agent choice, so switching agents
/// never carries a provider or key into another one, and switching back
/// restores what was typed there ([acpDraftFor]).
mixin HostEditorDrafts<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The running host edited, or null for a new host.
  AppServeStatus? get existing;

  /// The bridge.
  late final BridgeApi api;

  /// The Codex runtime fields (a new Codex host, or the running one).
  late final CodexRuntimeForm runtime;

  /// The OpenCode runtime fields (a new OpenCode host, or the running one).
  late final OpenCodeRuntimeForm openCode;

  final Map<String, ModelServiceDraft> _drafts = {};

  /// The new host's agent, see [AgentChoice].
  AgentChoice choice = codexChoice;

  /// The ACP form's current value (new agent, or the running one edited).
  AcpFormValue? acp;

  // The first value each new-agent choice reported: what "unchanged" is
  // (its agent, instance name and save toggle).
  final Map<String, AcpFormValue> _acpBaseline = {};

  // The last value each new-agent choice reported.
  final Map<String, AcpFormValue> _acpDrafts = {};

  // Agent values reported since the last frame, the latest per target;
  // applied together after it ([_applyAgents]).
  final Map<String, AcpFormValue> _agentPending = {};

  // The profile each target's model service was last restricted for.
  final Map<String, String> _restrictedFor = {};

  /// What the new host's form showed for [choice], to restore it.
  AcpFormValue? acpDraftFor(AgentChoice choice) => _acpDrafts[choice];

  /// Loading state of the running host's configuration.
  EditorLoad load = EditorLoad.ready;

  /// Why the load failed, safe to show.
  String? loadError;

  /// The configuration last read or saved (a running host).
  HostConfig? config;

  /// A newer read that arrived while edits were pending; shown, not applied.
  HostConfig? newerConfig;

  /// The agent the running ACP host's form was filled with: the saved
  /// desired agent, else the one it runs ([HostConfig.active]).
  AcpAgentSpec? editedSpecBase;

  /// Moves whenever the running host's agent form is refilled.
  int agentFormSeq = 0;

  /// An operation is running.
  bool busy = false;

  int _loadSeq = 0;

  // Set once leaving was confirmed, so the pop that follows goes through.
  bool _leaveConfirmed = false;

  /// The model service being edited for the current target.
  ModelServiceDraft get draft => _draftFor(_target);

  String get _target => existing == null ? choice : '';

  ModelServiceDraft _draftFor(String target) => _drafts.putIfAbsent(target, () {
    final draft = ModelServiceDraft()..addListener(rebuild);
    draft.restrict(
      target == openCodeChoice
          ? _openCodeSupport
          : isAcpChoice(target)
          ? const HostConfigSupport()
          : _codexSupport,
    );
    if (target == openCodeChoice || existing?.isOpenCode == true) {
      // Its history follows its model service (see [OpenCodeRuntimeForm]).
      void follow() => openCode.customProvider = draft.source == 'custom';
      draft.addListener(follow);
      follow();
    }
    return draft;
  });

  HostConfigSupport get _codexSupport => api.hostConfigSupported();

  HostConfigSupport get _openCodeSupport =>
      api.hostConfigSupported(engine: 'opencode');

  /// Whether the edited host (or the new host's agent) is an ACP agent.
  bool get isAcpHost => existing?.isAcp ?? isAcpChoice(choice);

  /// Whether the edited host (or the new host) is a native OpenCode host.
  bool get isOpenCodeHost => existing?.isOpenCode ?? choice == openCodeChoice;

  /// Whether the edited host (or the new host) is a native Codex host.
  bool get isCodexHost => !isAcpHost && !isOpenCodeHost;

  /// The running host as last reported, or null once it is gone. Never a
  /// stale snapshot: a stopped host is not operated on by name.
  /// Watches the host list: call from `build` only ([currentHost] elsewhere).
  AppServeStatus? get liveHost =>
      _hostIn(ref.watch(localServeListProvider).valueOrNull);

  /// [liveHost] for callbacks (reads without watching).
  AppServeStatus? get currentHost =>
      _hostIn(ref.read(localServeListProvider).valueOrNull);

  AppServeStatus? _hostIn(List<AppServeStatus>? hosts) {
    final host = existing;
    if (host == null) return null;
    if (hosts == null) return host;
    return hosts.where((h) => h.name == host.name).firstOrNull;
  }

  /// The edited host no longer runs.
  bool hostGone(AppServeStatus? live) => existing != null && live == null;

  /// The edited host was started again elsewhere since its configuration
  /// was read: reload before applying.
  bool hostReplaced(AppServeStatus? live) {
    final seen = config?.active?.incarnation;
    final now = live?.incarnation;
    return seen != null && now != null && seen != now;
  }

  /// The saved configuration is newer than what the host runs.
  bool get configPending => config?.pendingApply ?? false;

  /// The agent was edited: the running ACP host's, or (a new host) any
  /// agent choice's form — its agent, a typed instance name or the save
  /// toggle, on the shown choice or one switched away from.
  bool get agentEdited {
    if (existing == null) {
      return _acpDrafts.entries.any((entry) {
        final base = _acpBaseline[entry.key];
        return base != null && !sameForm(entry.value, base);
      });
    }
    final edited = acp?.spec;
    final base = editedSpecBase;
    if (edited == null || base == null) return false;
    return !sameAgent(edited, base);
  }

  /// Whether form value [value] still shows what [base] showed: the same
  /// agent, save toggle and (unless only suggested) instance name.
  static bool sameForm(AcpFormValue value, AcpFormValue base) =>
      sameAgent(value.spec, base.spec) &&
      value.save == base.save &&
      (!value.nameEdited || value.name.trim() == base.name.trim());

  /// Whether [a] and [b] launch the same agent.
  static bool sameAgent(AcpAgentSpec a, AcpAgentSpec b) =>
      a.program == b.program &&
      a.displayName == b.displayName &&
      listEquals(a.args, b.args);

  /// The running Codex or OpenCode host's runtime fields were edited.
  bool get runtimeEdited {
    final host = existing;
    if (host == null || load != EditorLoad.ready) return false;
    if (host.isOpenCode) return openCode.differs;
    return host.isCodex && runtime.differs(AppLocalizations.of(context));
  }

  /// Anything is edited and unsaved: runtime, agent, model service or key.
  bool get editorDirty {
    if (existing != null) {
      return load == EditorLoad.ready &&
          (draft.dirty || runtimeEdited || agentEdited);
    }
    return _drafts.values.any((d) => d.dirty) ||
        runtime.touched ||
        openCode.touched ||
        agentEdited;
  }

  /// Instance names this device already hosts.
  Set<String> get takenNames => {for (final host in _localHosts) host.name};

  /// Another host serving OpenCode's default database (one host can at a
  /// time), by name; the host edited here never counts.
  String? get sharedHistoryHost {
    final own = existing?.name;
    return _localHosts
        .where(
          (h) =>
              h.servesOpenCodeHistory &&
              (own == null ||
                  canonicalHostName(h.name) != canonicalHostName(own)),
        )
        .firstOrNull
        ?.name;
  }

  List<AppServeStatus> get _localHosts =>
      ref.read(localServeListProvider).valueOrNull ?? const <AppServeStatus>[];

  /// The grid choice that edits [spec]: its preset, else a saved agent.
  AgentChoice choiceFor(AcpAgentSpec spec) =>
      api.acpPresets().any((p) => p.id == spec.profileId)
      ? 'preset:${spec.profileId}'
      : 'saved:${spec.profileId}';

  /// Set up the drafts (call from `initState`).
  void initDrafts() {
    api = ref.read(bridgeApiProvider);
    runtime = CodexRuntimeForm(api)..addListener(rebuild);
    openCode = OpenCodeRuntimeForm(api)..addListener(rebuild);
    final host = existing;
    if (host == null) return;
    load = EditorLoad.loading;
    unawaited(loadConfig());
  }

  /// Release the drafts (call from `dispose`).
  void disposeDrafts() {
    _loadSeq++;
    for (final draft in _drafts.values) {
      draft.removeListener(rebuild);
      draft.dispose();
    }
    runtime.removeListener(rebuild);
    runtime.dispose();
    openCode.removeListener(rebuild);
    openCode.dispose();
  }

  /// Rebuild while mounted.
  void rebuild() {
    if (!mounted) return;
    formChanged();
    setState(() {});
  }

  /// The form changed (an edit, or a detection or suggestion landing);
  /// true when that cleared something shown, so the page rebuilds.
  bool formChanged() => false;

  /// (Re-)read the running host's configuration; only the latest read
  /// counts. With pending edits a successful read is held in [newerConfig].
  Future<void> loadConfig() async {
    final host = existing;
    if (host == null) return;
    final seq = ++_loadSeq;
    if (load != EditorLoad.ready) {
      setState(() {
        load = EditorLoad.loading;
        loadError = null;
      });
    }
    try {
      final loaded = await api.hostConfigGet(host.name);
      if (!mounted || seq != _loadSeq) return;
      if (load == EditorLoad.ready && editorDirty) {
        setState(() => newerConfig = loaded);
        return;
      }
      adopt(loaded);
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        if (load != EditorLoad.ready) load = EditorLoad.failed;
        loadError = friendlyError(e);
      });
    }
  }

  /// Show [loaded] in every field, discarding edits (a load, a reload the
  /// user asked for, or the answer of a save or apply).
  void adopt(HostConfig loaded) {
    final host = existing!;
    _loadSeq++;
    config = loaded;
    newerConfig = null;
    final desired = loaded.runtime ?? loaded.active?.runtime;
    if (host.isOpenCode) {
      openCode.name.text = host.name;
      openCode.prefill(
        desired != null && desired.isOpenCode
            ? desired
            : HostRuntime.opencode(
                binary: host.codexBinary,
                separateHistory: host.opencode?.separateHistory ?? false,
              ),
      );
      draft.restrict(_openCodeSupport);
    } else if (host.isCodex) {
      runtime.name.text = host.name;
      runtime.prefill(
        desired != null && desired.isCodex
            ? desired
            : HostRuntime.codex(
                binary: host.codexBinary,
                port: _portOf(host.appListenAddr),
                proxy: host.proxy,
              ),
      );
      draft.restrict(_codexSupport);
    } else {
      editedSpecBase =
          desired?.agent ?? loaded.active?.runtime.agent ?? _knownSpec(host);
      acp = null;
      agentFormSeq++;
      // The refilled form reports its agent again; apply it afresh.
      _restrictedFor.remove('');
      final spec = editedSpecBase;
      draft.restrict(
        spec == null
            ? const HostConfigSupport()
            : api.hostConfigSupported(spec: spec),
      );
    }
    draft.load(loaded);
    setState(() {
      load = EditorLoad.ready;
      loadError = null;
    });
  }

  static int _portOf(String addr) =>
      int.tryParse(addr.substring(addr.lastIndexOf(':') + 1)) ?? 0;

  /// The running ACP host's agent from this app's records, when the host
  /// does not report it (an older bridge).
  AcpAgentSpec? _knownSpec(AppServeStatus host) {
    final prefs = ref.read(uiPrefsProvider).valueOrNull;
    final restored = prefs?.autoHostAcp
        .where((r) => r.name == host.name)
        .firstOrNull
        ?.spec;
    if (restored != null) return restored;
    final id = host.profileId;
    if (id == null) return null;
    return prefs?.acpAgents.where((a) => a.profileId == id).firstOrNull ??
        api.acpPresets().where((p) => p.id == id).firstOrNull?.spec;
  }

  /// The grid choice changed; each choice keeps its own drafts.
  void selectChoice(AgentChoice next) {
    setState(() {
      choice = next;
      // The restored form reports it again once built.
      acp = _acpDrafts[next];
      runtime.pathIntent++;
      openCode.pathIntent++;
    });
  }

  /// The ACP form changed: the agent decides what its model service offers.
  /// The form reports during its own build (and its parent's), so nothing
  /// is rebuilt here: the latest value of each target is applied once after
  /// the frame, to that target's own draft.
  void agentChanged(AcpFormValue value) {
    final target = _target;
    acp = value;
    if (existing == null) {
      _acpBaseline.putIfAbsent(target, () => value);
      _acpDrafts[target] = value;
    }
    final scheduled = _agentPending.isNotEmpty;
    _agentPending[target] = value;
    if (scheduled) return;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) => _applyAgents());
    binding.ensureVisualUpdate();
  }

  void _applyAgents() {
    final pending = Map.of(_agentPending);
    _agentPending.clear();
    if (!mounted) return;
    if (formChanged()) setState(() {});
    for (final MapEntry(key: target, value: value) in pending.entries) {
      final profile = value.spec.profileId;
      if (_restrictedFor[target] == profile) continue;
      _restrictedFor[target] = profile;
      _draftFor(target).restrict(api.hostConfigSupported(spec: value.spec));
    }
    rebuild();
  }

  /// Ask before leaving with unsaved edits; `true` when the page may close.
  /// Nothing leaves while an operation runs.
  Future<bool> confirmLeave() async {
    if (busy) return false;
    if (_leaveConfirmed || !editorDirty) return true;
    final l10n = AppLocalizations.of(context);
    final leave = await confirmEditorAction(
      context,
      title: l10n.hostLeaveTitle,
      body: l10n.hostLeaveBody,
      action: l10n.hostLeaveDiscard,
      cancel: l10n.hostLeaveStay,
      dialogKey: const Key('host-leave-dialog'),
      cancelKey: const Key('host-leave-stay'),
      confirmKey: const Key('host-leave-discard'),
    );
    if (!leave || !mounted) return false;
    setState(() => _leaveConfirmed = true);
    return true;
  }

  /// Whether a pop may go through without asking.
  bool get canLeave => !busy && (_leaveConfirmed || !editorDirty);

  /// Explain what applying interrupts; `true` when the user agreed.
  Future<bool> confirmApply(AppServeStatus host) async {
    final l10n = AppLocalizations.of(context);
    final agreed = await confirmEditorAction(
      context,
      title: l10n.hostApplyConfirmTitle(host.name),
      body: l10n.hostApplyConfirmBody,
      action: l10n.hostApplyRestart,
      dialogKey: const Key('host-apply-dialog'),
      cancelKey: const Key('host-apply-cancel'),
      confirmKey: const Key('host-apply-confirm'),
    );
    return agreed && mounted;
  }
}
