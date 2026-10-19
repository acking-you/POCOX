import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/hosting/acp_host_form.dart';
import 'package:pocket_codex/src/hosting/agent_choice_grid.dart';
import 'package:pocket_codex/src/hosting/cancellable_delay.dart';
import 'package:pocket_codex/src/hosting/host_editor_drafts.dart';
import 'package:pocket_codex/src/hosting/host_names.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';

/// An operation of the hosting editor; its own control shows its progress.
enum HostAction {
  /// Start a new host.
  start,

  /// Save a running host's configuration.
  save,

  /// Restart a running host with its saved configuration.
  apply,

  /// Stop a running host.
  stop,

  /// Prepare Claude's adapter without starting anything.
  prepare,
}

/// The hosting editor's operations: starting a new host with its
/// configuration, saving a running host's runtime and model service,
/// applying them with a restart, and stopping.
///
/// Each operation owns a number ([_op]) taken when it begins; after every
/// await it goes on only while the page is mounted, has not left its route
/// and still owns it, so a late answer never reaches a closed page (even one
/// still animating out) or a newer operation. What must
/// survive the page (restore records) is written through what was captured
/// before the first await (container, preferences, scope life).
mixin HostEditorActions<T extends ConsumerStatefulWidget>
    on ConsumerState<T>, HostEditorDrafts<T> {
  /// What `CODEX_HOME` provides (inherited description, official sign-in).
  CodexSetupStatus? setup;

  /// Claude's adapter preparation, independent or before Start.
  AcpClaudeSetup? claudeSetup;

  // What Start itself announced an adapter download for; the next Start may
  // prepare for that same agent and environment only.
  String? _claudeAnnounced;

  // A preparation this page started and has not seen end: its run, which
  // is the only one this page may cancel (a later one is another caller's).
  int? _preparing;

  int _op = 0;

  // The page left its route ([retireEditor]); nothing of it goes on.
  bool _left = false;

  // A preparation's pending wait between two state reads: cut short when
  // the page leaves or stops waiting.
  final _prepareWait = CancellableDelay();

  /// The last failure, safe to show.
  String? error;

  // [error] refused the form's content before anything started: it goes as
  // soon as the form changes, while the fields keep their own marks.
  bool _refused = false;

  /// The last success, when it is worth saying.
  String? notice;

  /// The operation running while [busy].
  HostAction? running;

  bool _owns(int op) => mounted && !_left && op == _op;

  /// Set up the editor (call from `initState`).
  void initEditor() {
    initDrafts();
    final host = existing;
    if (host == null) {
      runtime.suggest(_hosts());
      openCode.suggest(_hosts());
      // Hosts may still be loading; suggest again once they arrive.
      ref.listenManual(localServeListProvider, (_, _) {
        if (!mounted) return;
        runtime.suggest(_hosts());
        openCode.suggest(_hosts());
      });
      Future.microtask(runtime.detect);
      Future.microtask(openCode.detect);
    }
    if (host == null || host.isCodex) unawaited(loadSetup());
  }

  /// The page left its route (popped, possibly still animating out): every
  /// operation of it ends here, its preparation wait included, and only the
  /// adapter preparation this page started is stopped (a joined one is
  /// another caller's). Idempotent; [disposeEditor] calls it too.
  void retireEditor() {
    if (_left) return;
    _left = true;
    _op++;
    _prepareWait.stop();
    if (_preparing case final run?) {
      _preparing = null;
      api.acpClaudePrepareCancelRun(run);
    }
  }

  /// Release the editor (call from `dispose`).
  void disposeEditor() {
    retireEditor();
    disposeDrafts();
  }

  List<AppServeStatus> _hosts() =>
      ref.read(localServeListProvider).valueOrNull ?? const [];

  /// The codex executable the official sign-in should run.
  String? officialBinary() {
    final (value, _) = runtime.read(AppLocalizations.of(context), exact: true);
    return value?.binary;
  }

  /// The proxy the official sign-in should use.
  String? officialProxy() => runtime.useProxy ? runtime.proxy.text : null;

  /// (Re-)read what `CODEX_HOME` provides.
  Future<void> loadSetup() async {
    try {
      final status = await api.codexSetupStatus();
      if (!mounted) return;
      setState(() => setup = status);
      ref.invalidate(codexSetupStatusProvider);
    } catch (_) {
      // Shown as unknown; the inherited choice stays usable.
    }
  }

  /// Pick the codex binary for the Codex form it was opened from.
  void browseCodex() => runtime.browse(() => !busy && isCodexHost);

  /// Pick the opencode executable for the OpenCode form it was opened from.
  void browseOpenCode() => openCode.browse(() => !busy && isOpenCodeHost);

  /// This page started the adapter preparation shown (and may cancel it).
  bool get ownsClaudePrepare => _preparing != null;

  /// Cancel the Claude adapter preparation this page started.
  void cancelClaudePrepare() {
    final run = _preparing;
    if (run == null) return;
    setState(() => claudeSetup = api.acpClaudePrepareCancelRun(run));
  }

  /// Stop waiting for a preparation another caller started (this page may
  /// not cancel it): only this page's operation ends; that run goes on.
  void stopWaitingForClaude() {
    if (_preparing != null || !(claudeSetup?.running ?? false)) return;
    _op++;
    _prepareWait.stop();
    setState(() {
      busy = false;
      running = null;
      claudeSetup = null;
      notice = AppLocalizations.of(context).claudePrepareLeftRunning;
    });
  }

  /// A start failure in the user's words; [name] is the name it asked for.
  String hostingError(Object e, {String? name}) {
    final l10n = AppLocalizations.of(context);
    final raw = friendlyError(e);
    if (raw.contains('opencode_already_hosted')) {
      return l10n.openCodeAlreadyHosted;
    }
    if (isLocalNameTaken(raw)) {
      // The bridge names the instance it refused, as it canonicalized it.
      final refused = RegExp(r'`([^`]+)`').firstMatch(raw)?.group(1);
      return l10n.hostNameInUse(refused ?? name ?? '');
    }
    if (isHostNameConflict(raw)) return l10n.hostNameConflict;
    if (isLocalPortTaken(raw)) {
      runtime.advanced = true;
      return l10n.hostPortConflict;
    }
    return raw;
  }

  /// Begin [action]; its number, or null while another operation runs.
  int? _begin(HostAction action) {
    if (busy || _left) return null;
    setState(() {
      busy = true;
      running = action;
      error = null;
      _refused = false;
      notice = null;
    });
    return ++_op;
  }

  /// Refuse the form as it is, with [message].
  void _refuse(String? message) => setState(() {
    error = message;
    _refused = true;
  });

  @override
  bool formChanged() {
    if (!_refused) return false;
    _refused = false;
    error = null;
    return true;
  }

  void _end(int op) {
    if (_owns(op)) {
      setState(() {
        busy = false;
        running = null;
      });
    }
  }

  /// Prepare the selected Claude environment without saving or starting a host.
  Future<void> prepareClaudeEnvironment() async {
    final value = acp;
    if (value == null || !isClaudeAdapterSpec(value.spec)) return;
    final op = _begin(HostAction.prepare);
    if (op == null) return;
    final l10n = AppLocalizations.of(context);
    try {
      final status = await api.acpClaudeStatus();
      if (!_owns(op)) return;
      if (!status.ready) {
        if (!status.canPrepare) {
          setState(
            () => error =
                status.problem ?? l10n.claudeAdapterMissing(status.package),
          );
          return;
        }
        if (!await _prepareClaude(op) || !_owns(op)) return;
      }
      setState(() => notice = l10n.claudeEnvironmentReady);
    } catch (e) {
      if (_owns(op)) setState(() => error = friendlyError(e));
    } finally {
      _end(op);
    }
  }

  /// Start the new host.
  Future<void> start() => choice == openCodeChoice
      ? _startOpenCode()
      : isAcpChoice(choice)
      ? _startAcp()
      : _startCodex();

  Future<void> _startOpenCode() async {
    final l10n = AppLocalizations.of(context);
    openCode.pathIntent++;
    final (value, invalid) = openCode.read(l10n);
    if (value == null) {
      _refuse(invalid);
      return;
    }
    await _startConfigured(
      openCode.name.text.trim(),
      value,
      refusal: () {
        final holder = sharedHistoryHost;
        if (holder == null || value.separateHistory) return null;
        return l10n.openCodeHistoryTaken(holder);
      },
    );
  }

  Future<void> _startCodex() async {
    final l10n = AppLocalizations.of(context);
    runtime.pathIntent++;
    final (value, invalid) = runtime.read(l10n);
    if (value == null) {
      runtime.advanced = invalid == l10n.localHostPortInvalid;
      _refuse(invalid);
      return;
    }
    await _startConfigured(runtime.name.text.trim(), value);
  }

  Future<void> _startAcp() async {
    final value = acp;
    if (value == null || !value.valid) {
      _refuse(AppLocalizations.of(context).acpProgramNotFound);
      return;
    }
    await _startConfigured(
      value.name,
      HostRuntime.acp(value.spec),
      saveAgent: value.save ? value.spec : null,
      // The Claude preset needs its ACP adapter; a missing one is prepared
      // here, on this explicit Start (announced beforehand).
      prepare: isClaudeAdapterSpec(value.spec)
          ? (op, life) => _prepareForStart(value, op, life)
          : null,
    );
  }

  /// Start a new host named [typed] (blank: the bridge's default) running
  /// [value], with the model service draft: saved and started as one
  /// operation, then remembered for the next launch. [refusal] adds a
  /// runtime's own check after the model service and name; [prepare] runs
  /// first and answers whether the start may go on; [saveAgent] is kept in
  /// "my agents".
  Future<void> _startConfigured(
    String typed,
    HostRuntime value, {
    String? Function()? refusal,
    Future<bool> Function(int op, ScopeLife life)? prepare,
    AcpAgentSpec? saveAgent,
  }) async {
    final l10n = AppLocalizations.of(context);
    final problem =
        draft.problem(l10n, fresh: true) ??
        switch (hostNameClash(typed, takenNames)) {
          final other? => l10n.hostNameInUse(other),
          null => refusal?.call(),
        };
    if (problem != null) {
      _refuse(problem);
      return;
    }
    final input = draft.input;
    final keyAction = draft.keyAction(fresh: true);
    final key = draft.typedKey;
    final op = _begin(HostAction.start);
    if (op == null) return;
    final toast = ToastMessenger.of(context);
    final navigator = Navigator.of(context);
    final container = ProviderScope.containerOf(context);
    final prefs = container.read(uiPrefsProvider.notifier);
    final life = container.read(scopeLifeProvider);
    try {
      if (prepare != null && !await prepare(op, life)) return;
      final result = await api.appServeStartConfigured(
        name: typed.isEmpty ? null : typed,
        runtime: value,
        input: input,
        keyAction: keyAction,
        key: key,
      );
      if (!life.alive) return;
      _remember(prefs, result.name, value, fresh: true);
      final saved = saveAgent == null
          ? Future.value(true)
          : prefs.saveAcpAgent(saveAgent);
      container.invalidate(localServeListProvider);
      container.invalidate(servicesProvider);
      // Only this page's own route, while it is mounted and the operation
      // is still its latest.
      if (_owns(op)) navigator.pop();
      final full = !await saved;
      await _announceStarted(
        result.name,
        toast,
        life,
        l10n,
        notes: [
          ?result.notice,
          if (full) l10n.acpSavedAgentsFull(UiPrefs.maxSavedAgents),
        ],
      );
    } catch (e) {
      if (_owns(op)) setState(() => error = hostingError(e, name: typed));
    } finally {
      _end(op);
    }
  }

  /// Make sure the Claude preset's adapter is there before [value] starts:
  /// a missing one is prepared only once the form (or a previous Start)
  /// announced that download for this agent and environment.
  Future<bool> _prepareForStart(
    AcpFormValue value,
    int op,
    ScopeLife life,
  ) async {
    final l10n = AppLocalizations.of(context);
    final status = await api.acpClaudeStatus();
    if (!_owns(op)) return false;
    if (status.ready) return true;
    if (!status.canPrepare) {
      setState(
        () =>
            error = status.problem ?? l10n.claudeAdapterMissing(status.package),
      );
      return false;
    }
    final announcement = claudeAnnouncementKey(value.spec, status);
    final shown = value.claudeShown;
    final formAnnounced =
        value.claudePrepareShown &&
        shown != null &&
        claudeAnnouncementKey(value.spec, shown) == announcement;
    if (!formAnnounced && _claudeAnnounced != announcement) {
      setState(() {
        _claudeAnnounced = announcement;
        error = l10n.claudeAdapterWillPrepare(status.package);
      });
      return false;
    }
    return await _prepareClaude(op) && _owns(op) && life.alive;
  }

  /// Prepare Claude's pinned adapter for operation [op], showing its
  /// progress until it ends; `true` once ready. Only the run this call
  /// observed counts: a state of another run is not this preparation's
  /// result (it is reported as replaced, and nothing starts). A page closed
  /// meanwhile answers `false` and stops only a run it started.
  Future<bool> _prepareClaude(int op) async {
    final l10n = AppLocalizations.of(context);
    var state = await api.acpClaudePrepareStart();
    // Joining a run another caller started gives no right to cancel it.
    final mine = state.started ? state.run : null;
    if (!_owns(op)) {
      // Answered after this page moved on: its dispose had no run to
      // cancel yet, so stop exactly the one this call started.
      if (mine != null) api.acpClaudePrepareCancelRun(mine);
      return false;
    }
    final run = state.run;
    _preparing = mine;
    setState(() => claudeSetup = state);
    while (state.running) {
      if (!await _prepareWait.wait(const Duration(milliseconds: 500)) ||
          !_owns(op)) {
        return false;
      }
      final next = api.acpClaudePrepareState();
      if (next.run != run) {
        // That run ended and another began (or the state is unknown): its
        // outcome is not known here, and the other run's is not ours.
        _preparing = null;
        setState(() {
          claudeSetup = null;
          error = l10n.claudePrepareReplaced;
        });
        return false;
      }
      state = next;
      setState(() => claudeSetup = state);
    }
    _preparing = null;
    setState(() {
      claudeSetup = state.state == 'done' ? null : state;
      error = switch (state.state) {
        'done' => null,
        'cancelled' => l10n.claudePrepareCancelled,
        _ => l10n.claudePrepareFailed(state.error ?? ''),
      };
    });
    return state.state == 'done';
  }

  /// The runtime a running host's save carries: its edited fields, or null
  /// when they are unchanged (the saved runtime is kept).
  (HostRuntime?, String?) _editedRuntime(AppLocalizations l10n) {
    final host = existing!;
    if (host.isOpenCode) {
      if (!runtimeEdited) return (null, null);
      return openCode.read(l10n);
    }
    if (host.isCodex) {
      if (!runtimeEdited) return (null, null);
      return runtime.read(l10n, exact: true);
    }
    final value = acp;
    if (!agentEdited || value == null) return (null, null);
    if (!value.valid) return (null, l10n.acpProgramNotFound);
    return (HostRuntime.acp(value.spec), null);
  }

  /// Save the running host's runtime and model service; nothing that runs
  /// changes. Refused until its configuration was read.
  Future<bool> saveConfig() async {
    final op = _begin(HostAction.save);
    if (op == null) return false;
    try {
      return await _save(op);
    } finally {
      _end(op);
    }
  }

  Future<bool> _save(int op) async {
    final host = existing!;
    final loaded = config;
    final l10n = AppLocalizations.of(context);
    if (load != EditorLoad.ready || loaded == null) return false;
    if (draft.problem(l10n) case final problem?) {
      _refuse(problem);
      return false;
    }
    final (edited, invalid) = _editedRuntime(l10n);
    if (invalid != null) {
      _refuse(invalid);
      return false;
    }
    try {
      final saved = await api.hostConfigSave(
        name: host.name,
        input: draft.input,
        keyAction: draft.keyAction(fresh: false),
        key: draft.typedKey,
        expectedRevision: loaded.revision,
        spec: host.isAcp ? (acp?.spec ?? editedSpecBase) : null,
        runtime: edited,
      );
      if (!_owns(op)) return false;
      adopt(saved);
      setState(() => notice = l10n.hostConfigSaved);
      return true;
    } catch (e) {
      if (_owns(op)) setState(() => error = friendlyError(e));
      return false;
    }
  }

  /// Restart the running host with its saved configuration (saving the
  /// edits first), after the user agreed to the interruption. Only this
  /// host restarts, and only the incarnation shown when Apply was pressed
  /// (taken before the confirmation and the save, so a host replaced
  /// meanwhile is refused, never retargeted) with the revision saved here.
  Future<void> applyConfig() async {
    final host = currentHost;
    if (host == null || busy || load != EditorLoad.ready) return;
    if (hostReplaced(host)) {
      setState(() => error = AppLocalizations.of(context).hostReplaced);
      return;
    }
    // A restart onto a shared history another host serves would only fail.
    if (sharedHistoryHost case final holder?
        when host.isOpenCode && !openCode.separateHistory) {
      _refuse(AppLocalizations.of(context).openCodeHistoryTaken(holder));
      return;
    }
    final incarnation = config?.active?.incarnation ?? host.incarnation;
    if (!await confirmApply(host)) return;
    // The page may have closed while the confirmation was open.
    if (!mounted) return;
    final op = _begin(HostAction.apply);
    if (op == null) return;
    final l10n = AppLocalizations.of(context);
    final container = ProviderScope.containerOf(context);
    final prefs = container.read(uiPrefsProvider.notifier);
    final life = container.read(scopeLifeProvider);
    try {
      if (editorDirty && !await _save(op)) return;
      if (!_owns(op)) return;
      final reviewed = config!;
      final now = reviewed.active?.incarnation;
      if (now != null && now != incarnation) {
        // The save reports another host under this name than the one the
        // user agreed to restart.
        setState(() => error = l10n.hostReplaced);
        return;
      }
      final result = await api.appServeApply(
        host.name,
        expectedIncarnation: incarnation,
        expectedRevision: reviewed.revision,
      );
      if (!life.alive) return;
      if (result.applied) _remember(prefs, host.name, reviewed.runtime);
      container.invalidate(localServeListProvider);
      container.invalidate(servicesProvider);
      if (!_owns(op)) return;
      // A restart that happened is reported as such; a restore-record
      // warning is shown beside it, never as a failure.
      final restoreProblem = result.applied
          ? await _restoreProblem(host.name)
          : null;
      if (!_owns(op)) return;
      setState(() {
        if (result.applied) {
          notice = restoreProblem == null
              ? l10n.hostApplied
              : '${l10n.hostApplied}\n'
                    '${l10n.managedRestoreProblem(restoreProblem)}';
        } else if (result.restoredPrevious) {
          error = l10n.hostApplyRestored(_reason(result.error));
        } else if (result.restoreError != null) {
          error = l10n.hostApplyStopped(
            _reason(result.error),
            _reason(result.restoreError),
          );
        } else {
          error = l10n.hostApplyFailed(_reason(result.error));
        }
      });
      // What the host runs now (the new configuration or the previous one).
      unawaited(loadConfig());
    } catch (e) {
      if (_owns(op)) setState(() => error = friendlyError(e));
    } finally {
      _end(op);
    }
  }

  /// A restart's failure [raw] (the bridge's safe text) in the user's words
  /// where they have some.
  String _reason(String? raw) => raw == null
      ? ''
      : raw.contains('opencode_already_hosted')
      ? AppLocalizations.of(context).openCodeAlreadyHosted
      : raw;

  /// This computer's restart-persistence warning for [name], if any. A read
  /// failure is not a warning.
  Future<String?> _restoreProblem(String name) async {
    try {
      return await api.hostRestoreProblem(name: name);
    } catch (_) {
      return null;
    }
  }

  /// After a successful start: say so in one toast, which also carries what
  /// the user should know beside it ([notes], and when the host will not be
  /// restored at the next launch) without turning the start into a failure.
  Future<void> _announceStarted(
    String name,
    ToastMessenger toast,
    ScopeLife life,
    AppLocalizations l10n, {
    List<String> notes = const [],
  }) async {
    final problem = await _restoreProblem(name);
    if (!life.alive) return;
    final caveats = [
      ...notes,
      if (problem != null) l10n.managedRestoreProblem(problem),
    ];
    final started = l10n.managedStarted(name);
    if (caveats.isEmpty) {
      toast.ok(started);
    } else {
      toast.notice([started, ...caveats].join('\n'));
    }
  }

  /// The restore record of [name] follows the runtime it now runs. A new
  /// host ([fresh]) has no older OpenCode record of its own to clear: the
  /// older record means OpenCode's default database, and a host with its own
  /// history is restored from the bridge's record alone. The Codex record is
  /// still written for older versions of the app; the bridge's restore
  /// record is what a cold start now follows.
  void _remember(
    UiPrefsStore prefs,
    String name,
    HostRuntime? ran, {
    bool fresh = false,
  }) {
    if (ran == null) return;
    if (ran.isOpenCode) {
      if (!ran.separateHistory) {
        prefs.setAutoHostOpenCode(
          AutoHostOpenCodePrefs(name: name, binary: ran.binary),
        );
      } else if (!fresh) {
        prefs.clearAutoHostOpenCode(name);
      }
      return;
    }
    if (ran.agent case final agent?) {
      unawaited(
        prefs.setAutoHostAcp(AutoHostAcpPrefs(name: name, spec: agent)),
      );
      return;
    }
    unawaited(
      prefs.setAutoHost(
        AutoHostPrefs(
          port: ran.port,
          name: name,
          proxy: ran.proxy,
          embedded: false,
          binaryOverride: ran.binary,
        ),
      ),
    );
  }

  /// Fully stop the running host; it is not restored at launch.
  Future<void> stop() async {
    final host = currentHost;
    if (host == null) return;
    final op = _begin(HostAction.stop);
    if (op == null) return;
    final l10n = AppLocalizations.of(context);
    final toast = ToastMessenger.of(context);
    final navigator = Navigator.of(context);
    final container = ProviderScope.containerOf(context);
    final prefs = container.read(uiPrefsProvider.notifier);
    final life = container.read(scopeLifeProvider);
    try {
      // Codex: codex + the API proxy and every relay key. ACP: the agent and
      // the processes it started. OpenCode: the `opencode serve` it owns.
      await api.appServeStop(host.name);
      if (!life.alive) return;
      if (host.isOpenCode) {
        prefs.clearAutoHostOpenCode(host.name);
      } else if (host.isAcp) {
        prefs.clearAutoHostAcp(host.name);
      } else {
        prefs.clearAutoHost(host.name);
      }
      // Optimistically hide the discovery entries so they leave at once.
      container
          .read(pendingRemovalProvider.notifier)
          .update(
            (set) => {
              ...set,
              host.appServiceKey,
              if (host.isCodex) host.apiServiceKey,
            },
          );
      container.invalidate(localServeListProvider);
      container.invalidate(servicesProvider);
      toast.ok(l10n.hostStoppedToast(host.name));
      if (_owns(op)) navigator.pop();
    } catch (e) {
      if (_owns(op)) setState(() => error = friendlyError(e));
    } finally {
      _end(op);
    }
  }
}
