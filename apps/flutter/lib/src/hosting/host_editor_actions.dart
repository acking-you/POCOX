import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/hosting/acp_host_form.dart';
import 'package:pocket_codex/src/hosting/agent_choice_grid.dart';
import 'package:pocket_codex/src/hosting/host_editor_drafts.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';

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
  // the page leaves or stops waiting, so no timer outlives either.
  Timer? _prepareTimer;
  Completer<bool>? _prepareWait;

  /// The last failure, safe to show.
  String? error;

  /// The last success, when it is worth saying.
  String? notice;

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
    _stopPrepareWait();
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
    _stopPrepareWait();
    setState(() {
      busy = false;
      claudeSetup = null;
      notice = AppLocalizations.of(context).claudePrepareLeftRunning;
    });
  }

  /// A start failure in the user's words.
  String hostingError(Object e) {
    final l10n = AppLocalizations.of(context);
    final raw = friendlyError(e);
    if (raw.contains('opencode_already_hosted')) {
      return l10n.openCodeAlreadyHosted;
    }
    if (isHostNameConflict(raw) || isLocalNameTaken(raw)) {
      return l10n.hostNameConflict;
    }
    if (isLocalPortTaken(raw)) {
      runtime.advanced = true;
      return l10n.hostPortConflict;
    }
    return raw;
  }

  /// Begin an operation; its number, or null while another one runs.
  int? _begin() {
    if (busy || _left) return null;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    return ++_op;
  }

  void _end(int op) {
    if (_owns(op)) setState(() => busy = false);
  }

  /// Prepare the selected Claude environment without saving or starting a host.
  Future<void> prepareClaudeEnvironment() async {
    final value = acp;
    if (value == null || !isClaudeAdapterSpec(value.spec)) return;
    final op = _begin();
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
      setState(() => error = invalid);
      return;
    }
    // OpenCode's own providers and sign-ins, or the custom provider the
    // bridge supports for it ([HostConfigSupport]).
    if (draft.problem(l10n, fresh: true) case final problem?) {
      setState(() => error = problem);
      return;
    }
    final typed = openCode.name.text.trim();
    final input = draft.input;
    final keyAction = draft.keyAction(fresh: true);
    final key = draft.typedKey;
    final op = _begin();
    if (op == null) return;
    final navigator = Navigator.of(context);
    final container = ProviderScope.containerOf(context);
    final prefs = container.read(uiPrefsProvider.notifier);
    final life = container.read(scopeLifeProvider);
    final toast = ToastMessenger.of(context);
    try {
      final result = await api.appServeStartConfigured(
        name: typed.isEmpty ? null : typed,
        runtime: value,
        input: input,
        keyAction: keyAction,
        key: key,
      );
      if (!life.alive) return;
      prefs.setAutoHostOpenCode(
        AutoHostOpenCodePrefs(name: result.name, binary: value.binary),
      );
      container.invalidate(localServeListProvider);
      container.invalidate(servicesProvider);
      if (_owns(op)) navigator.pop();
      await _noticeRestoreProblem(result.name, toast, life, l10n);
    } catch (e) {
      if (_owns(op)) setState(() => error = hostingError(e));
    } finally {
      _end(op);
    }
  }

  Future<void> _startCodex() async {
    final l10n = AppLocalizations.of(context);
    runtime.pathIntent++;
    final (value, invalid) = runtime.read(l10n);
    if (value == null) {
      runtime.advanced = invalid == l10n.localHostPortInvalid;
      setState(() => error = invalid);
      return;
    }
    if (draft.problem(l10n, fresh: true) case final problem?) {
      setState(() => error = problem);
      return;
    }
    final typed = runtime.name.text.trim();
    final input = draft.input;
    final keyAction = draft.keyAction(fresh: true);
    final key = draft.typedKey;
    final op = _begin();
    if (op == null) return;
    final toast = ToastMessenger.of(context);
    final navigator = Navigator.of(context);
    final container = ProviderScope.containerOf(context);
    final prefs = container.read(uiPrefsProvider.notifier);
    final life = container.read(scopeLifeProvider);
    try {
      final result = await api.appServeStartConfigured(
        name: typed.isEmpty ? null : typed,
        runtime: value,
        input: input,
        keyAction: keyAction,
        key: key,
      );
      if (!life.alive) return;
      // Still written for older versions of the app; the bridge's restore
      // record of this start is what a cold start now follows.
      prefs.setAutoHost(
        AutoHostPrefs(
          port: value.port,
          name: result.name,
          proxy: value.proxy,
          embedded: false,
          binaryOverride: value.binary,
        ),
      );
      container.invalidate(localServeListProvider);
      container.invalidate(servicesProvider);
      // Only this page's own route, while it is mounted and the operation
      // is still its latest.
      if (_owns(op)) navigator.pop();
      await _noticeRestoreProblem(result.name, toast, life, l10n);
    } catch (e) {
      if (_owns(op)) setState(() => error = hostingError(e));
    } finally {
      _end(op);
    }
  }

  Future<void> _startAcp() async {
    final l10n = AppLocalizations.of(context);
    final value = acp;
    if (value == null || !value.valid) {
      setState(() => error = l10n.acpProgramNotFound);
      return;
    }
    if (draft.problem(l10n, fresh: true) case final problem?) {
      setState(() => error = problem);
      return;
    }
    final input = draft.input;
    final keyAction = draft.keyAction(fresh: true);
    final key = draft.typedKey;
    final op = _begin();
    if (op == null) return;
    final toast = ToastMessenger.of(context);
    final navigator = Navigator.of(context);
    final container = ProviderScope.containerOf(context);
    final prefs = container.read(uiPrefsProvider.notifier);
    final life = container.read(scopeLifeProvider);
    try {
      // The Claude preset needs its ACP adapter; a missing one is prepared
      // here, on this explicit Start (announced beforehand).
      if (isClaudeAdapterSpec(value.spec)) {
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
            return;
          }
          if (!await _prepareClaude(op) || !_owns(op) || !life.alive) return;
        }
      }
      final result = await api.appServeStartConfigured(
        name: value.name.isEmpty ? null : value.name,
        runtime: HostRuntime.acp(value.spec),
        input: input,
        keyAction: keyAction,
        key: key,
      );
      if (!life.alive) return;
      prefs.setAutoHostAcp(
        AutoHostAcpPrefs(name: result.name, spec: value.spec),
      );
      final saved = value.save
          ? prefs.saveAcpAgent(value.spec)
          : Future.value(true);
      container.invalidate(localServeListProvider);
      container.invalidate(servicesProvider);
      if (_owns(op)) navigator.pop();
      if (!await saved && life.alive) {
        toast.notice(l10n.acpSavedAgentsFull(UiPrefs.maxSavedAgents));
      }
      await _noticeRestoreProblem(result.name, toast, life, l10n);
    } catch (e) {
      if (_owns(op)) setState(() => error = hostingError(e));
    } finally {
      _end(op);
    }
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
      if (!await _prepareDelay(op)) return false;
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

  /// Wait one poll interval of the preparation [op] observes: `false` once
  /// [op] no longer owns the page (it left, or stopped waiting meanwhile).
  Future<bool> _prepareDelay(int op) async {
    _stopPrepareWait();
    final wait = Completer<bool>();
    _prepareWait = wait;
    _prepareTimer = Timer(const Duration(milliseconds: 500), () {
      if (identical(_prepareWait, wait)) {
        _prepareWait = null;
        _prepareTimer = null;
      }
      wait.complete(true);
    });
    return await wait.future && _owns(op);
  }

  /// End the pending preparation wait, if any, as stopped.
  void _stopPrepareWait() {
    _prepareTimer?.cancel();
    _prepareTimer = null;
    final wait = _prepareWait;
    _prepareWait = null;
    if (wait != null && !wait.isCompleted) wait.complete(false);
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
    final op = _begin();
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
      setState(() => error = problem);
      return false;
    }
    final (edited, invalid) = _editedRuntime(l10n);
    if (invalid != null) {
      setState(() => error = invalid);
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
    final incarnation = config?.active?.incarnation ?? host.incarnation;
    if (!await confirmApply(host)) return;
    // The page may have closed while the confirmation was open.
    if (!mounted) return;
    final op = _begin();
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
      if (result.applied) _remember(prefs, host, reviewed.runtime);
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
          error = l10n.hostApplyRestored(result.error ?? '');
        } else if (result.restoreError != null) {
          error = l10n.hostApplyStopped(
            result.error ?? '',
            result.restoreError!,
          );
        } else {
          error = l10n.hostApplyFailed(result.error ?? '');
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

  /// This computer's restart-persistence warning for [name], if any. A read
  /// failure is not a warning.
  Future<String?> _restoreProblem(String name) async {
    try {
      return await api.hostRestoreProblem(name: name);
    } catch (_) {
      return null;
    }
  }

  /// After a successful start: tell the user when it will not be restored
  /// at the next launch, without turning the start into a failure.
  Future<void> _noticeRestoreProblem(
    String name,
    ToastMessenger toast,
    ScopeLife life,
    AppLocalizations l10n,
  ) async {
    final problem = await _restoreProblem(name);
    if (problem != null && life.alive) {
      toast.notice(l10n.managedRestoreProblem(problem));
    }
  }

  /// The restore record follows the runtime the host now runs.
  void _remember(UiPrefsStore prefs, AppServeStatus host, HostRuntime? ran) {
    if (ran == null) return;
    if (ran.isOpenCode) {
      prefs.setAutoHostOpenCode(
        AutoHostOpenCodePrefs(name: host.name, binary: ran.binary),
      );
      return;
    }
    if (ran.agent case final agent?) {
      unawaited(
        prefs.setAutoHostAcp(AutoHostAcpPrefs(name: host.name, spec: agent)),
      );
      return;
    }
    unawaited(
      prefs.setAutoHost(
        AutoHostPrefs(
          port: ran.port,
          name: host.name,
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
    final op = _begin();
    if (op == null) return;
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
      if (_owns(op)) navigator.pop();
    } catch (e) {
      if (_owns(op)) setState(() => error = friendlyError(e));
    } finally {
      _end(op);
    }
  }
}
