import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/acp_host_form.dart';
import 'package:pocket_codex/src/hosting/agent_choice_grid.dart';
import 'package:pocket_codex/src/hosting/claude_preparation_progress.dart';
import 'package:pocket_codex/src/hosting/codex_runtime_section.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/hosting/host_editor_actions.dart';
import 'package:pocket_codex/src/hosting/host_editor_drafts.dart';
import 'package:pocket_codex/src/hosting/host_status_section.dart';
import 'package:pocket_codex/src/hosting/model_service_section.dart';
import 'package:pocket_codex/src/hosting/official_login_panel.dart';
import 'package:pocket_codex/src/hosting/opencode_runtime_section.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/group_card.dart';
import 'package:pocket_codex/src/widgets/utility_page.dart';

/// Open the hosting editor: a new host, or the running [existing] one.
/// [initialChoice] preselects a new host's agent ([AgentChoice]).
Future<void> showHostingEditor(
  BuildContext context, {
  AppServeStatus? existing,
  AgentChoice? initialChoice,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        HostingEditor(existing: existing, initialChoice: initialChoice),
  ),
);

/// The hosting editor, one page for creating and editing a local host.
///
/// A new host: pick the agent ([AgentChoiceGrid]), fill its runtime (Codex:
/// [CodexRuntimeSection]; OpenCode: [OpenCodeRuntimeSection]; ACP:
/// [AcpHostForm]) and its model service
/// ([ModelServiceSection]), then Start: saved and started as one operation
/// ([BridgeApi.appServeStartConfigured]), so a failed start leaves no new
/// configuration behind.
///
/// A running host: its status ([HostStatusSection]), its runtime (Codex:
/// executable, port and proxy; ACP: program and arguments) and its model
/// service, all read from the bridge first. Save stores them and changes
/// nothing that runs; an explicit, confirmed "restart to apply" restarts only
/// that host ([BridgeApi.appServeApply]) with exactly the revision shown, and
/// a failed restart brings the previous configuration back. Leaving with
/// unsaved edits asks first, for back, the page's own navigation and its
/// shortcuts alike.
class HostingEditor extends ConsumerStatefulWidget {
  /// Creates the editor; [existing] edits a running host.
  const HostingEditor({super.key, this.existing, this.initialChoice});

  /// The running host edited, or null for a new host.
  final AppServeStatus? existing;

  /// A new host's preselected agent; Codex when null.
  final AgentChoice? initialChoice;

  @override
  ConsumerState<HostingEditor> createState() => _HostingEditorState();
}

class _HostingEditorState extends ConsumerState<HostingEditor>
    with HostEditorDrafts<HostingEditor>, HostEditorActions<HostingEditor> {
  @override
  AppServeStatus? get existing => widget.existing;

  @override
  void initState() {
    super.initState();
    if (widget.initialChoice case final initial? when existing == null) {
      choice = initial;
    }
    initEditor();
  }

  @override
  void dispose() {
    disposeEditor();
    super.dispose();
  }

  Widget _agentGrid() {
    final saved =
        ref.watch(uiPrefsProvider).valueOrNull?.acpAgents ??
        const <AcpAgentSpec>[];
    final hosts =
        ref.watch(localServeListProvider).valueOrNull ??
        const <AppServeStatus>[];
    return GroupCard(
      key: const Key('host-agent-section'),
      title: AppLocalizations.of(context).hostSectionAgent,
      children: [
        EditorBlock(
          child: AgentChoiceGrid(
            value: choice,
            presets: api.acpPresets(),
            saved: saved,
            onChanged: busy ? null : selectChoice,
            openCodeHost: hosts.where((h) => h.isOpenCode).firstOrNull,
            onOpenHost: _openRunning,
          ),
        ),
      ],
    );
  }

  /// Open the running [host]'s own editor in place of this new-host page,
  /// once this page may close.
  Future<void> _openRunning(AppServeStatus host) async {
    if (!await confirmLeave() || !mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => HostingEditor(existing: host)),
    );
  }

  /// What the agent's existing configuration provides, in words.
  Widget _inherited(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    if (isOpenCodeHost) {
      return EditorNote(
        l10n.hostInheritedOpenCode,
        key: const Key('host-inherited-opencode'),
      );
    }
    if (isAcpHost) return EditorNote(l10n.hostInheritedAcp);
    final s = setup;
    if (s == null) return const LinearProgressIndicator();
    final source = s.effectiveSource.isNotEmpty
        ? s.effectiveSource
        : s.hasCustomProvider
        ? 'custom'
        : s.hasAuth
        ? 'account'
        : 'none';
    final (text, color) = switch (source) {
      'custom' => (
        l10n.hostInheritedCodexCustom(s.selectedProvider ?? '—'),
        successColor(scheme),
      ),
      'account' => (l10n.hostInheritedCodexAccount, successColor(scheme)),
      'invalid' => (l10n.hostInheritedCodexInvalid, scheme.error),
      _ => (l10n.hostInheritedCodexNone, cautionColor(scheme)),
    };
    return Column(
      key: const Key('host-inherited-status'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        EditorNote(text, color: color),
        const SizedBox(height: 4),
        EditorNote(l10n.hostInheritedCodexHome(s.codexHome)),
      ],
    );
  }

  /// Save and restart controls for a running host's configuration.
  Widget _configActions(AppLocalizations l10n, AppServeStatus? live) {
    final scheme = Theme.of(context).colorScheme;
    final dirty = editorDirty;
    final ready = load == EditorLoad.ready;
    final gone = hostGone(live);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (configPending && !dirty) ...[
          EditorNote(
            l10n.hostConfigPending,
            key: const Key('host-config-pending'),
            color: cautionColor(scheme),
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              key: const Key('host-config-save'),
              onPressed: busy || !ready || !dirty ? null : saveConfig,
              child: Text(l10n.hostSaveConfig),
            ),
            FilledButton.icon(
              key: const Key('host-config-apply'),
              onPressed: busy || !ready || gone || !(configPending || dirty)
                  ? null
                  : applyConfig,
              icon: const Icon(Icons.restart_alt, size: 18),
              label: Text(
                dirty ? l10n.hostSaveAndRestart : l10n.hostApplyRestart,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        EditorNote(l10n.hostApplyNote),
      ],
    );
  }

  /// Codex hosts also publish `api:<name>`; say what it uses.
  Widget? _apiNote(AppLocalizations l10n) =>
      isCodexHost ? EditorNote(l10n.hostApiProxyNote) : null;

  Widget _footer(AppLocalizations l10n, AppServeStatus? live) {
    final note = _apiNote(l10n);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (existing != null) _configActions(l10n, live),
        if (existing != null && note != null) const SizedBox(height: 8),
        ?note,
      ],
    );
  }

  ModelServiceSection _model(AppLocalizations l10n, AppServeStatus? live) =>
      ModelServiceSection(
        draft: draft,
        enabled: !busy,
        inherited: _inherited(l10n),
        official: !isCodexHost
            ? null
            : OfficialLoginPanel(
                status: setup,
                enabled: !busy,
                binary: officialBinary,
                proxy: officialProxy,
                onChanged: loadSetup,
              ),
        footer: existing == null && !isCodexHost ? null : _footer(l10n, live),
      );

  /// The running host's state notes: gone, replaced, a newer saved
  /// configuration, or the load gate.
  List<Widget> _hostNotes(AppLocalizations l10n, AppServeStatus? live) {
    final scheme = Theme.of(context).colorScheme;
    return [
      if (hostGone(live))
        EditorNote(
          l10n.hostGone,
          key: const Key('host-gone'),
          color: scheme.error,
        )
      else if (hostReplaced(live))
        _noteWithAction(
          l10n.hostReplaced,
          const Key('host-replaced'),
          l10n.hostConfigReload,
          busy ? null : loadConfig,
          scheme.error,
        ),
      if (newerConfig case final newer?)
        _noteWithAction(
          l10n.hostConfigNewer,
          const Key('host-config-newer'),
          l10n.hostConfigReload,
          busy ? null : () => adopt(newer),
          cautionColor(scheme),
        ),
    ];
  }

  Widget _noteWithAction(
    String text,
    Key key,
    String action,
    VoidCallback? onPressed,
    Color color,
  ) => Row(
    key: key,
    children: [
      Expanded(child: EditorNote(text, color: color)),
      TextButton(onPressed: onPressed, child: Text(action)),
    ],
  );

  Widget _loadGate(AppLocalizations l10n) {
    if (load == EditorLoad.loading) {
      return const Padding(
        key: Key('host-config-loading'),
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    }
    return GroupCard(
      key: const Key('host-config-load-failed'),
      title: l10n.hostConfigLoadFailedTitle,
      children: [
        EditorBlock(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              EditorNote(
                l10n.hostConfigLoadFailed(loadError ?? ''),
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('host-config-retry'),
                onPressed: loadConfig,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l10n.retry),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _runningRuntime(AppLocalizations l10n, AppServeStatus host) {
    if (host.isOpenCode) {
      return OpenCodeRuntimeSection(
        form: openCode,
        enabled: !busy,
        onBrowse: browseOpenCode,
        fixedName: true,
        hint: l10n.hostRuntimeEditNote,
      );
    }
    if (host.isCodex) {
      return CodexRuntimeSection(
        form: runtime,
        enabled: !busy,
        onBrowse: browseCodex,
        fixedName: true,
        hint: l10n.hostRuntimeEditNote,
      );
    }
    final spec = editedSpecBase;
    return GroupCard(
      key: const Key('host-agent-edit'),
      title: l10n.hostSectionAgent,
      hint: l10n.hostAgentEditNote,
      children: [
        EditorBlock(
          child: spec == null
              ? EditorNote(l10n.hostAgentUnknown)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AcpHostForm(
                      key: ValueKey('host-agent-form-$agentFormSeq'),
                      choice: choiceFor(spec),
                      initial: spec,
                      fixedName: host.name,
                      enabled: !busy,
                      onChanged: agentChanged,
                      onPrepare: prepareClaudeEnvironment,
                    ),
                    if (claudeSetup case final setup? when setup.running)
                      _claudeProgress(setup),
                  ],
                ),
        ),
      ],
    );
  }

  List<Widget> _sections(AppLocalizations l10n) {
    final host = existing;
    final live = liveHost;
    if (host != null) {
      return [
        HostStatusSection(host: live ?? host),
        ..._hostNotes(l10n, live),
        if (load != EditorLoad.ready)
          _loadGate(l10n)
        else ...[
          _runningRuntime(l10n, host),
          _model(l10n, live),
        ],
      ];
    }
    return [
      _agentGrid(),
      if (choice == openCodeChoice)
        OpenCodeRuntimeSection(
          form: openCode,
          enabled: !busy,
          onBrowse: browseOpenCode,
        )
      else if (isAcpChoice(choice))
        GroupCard(
          key: const Key('acp-runtime-section'),
          title: l10n.hostRuntimeInfo,
          children: [
            EditorBlock(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AcpHostForm(
                    // One form per choice, restored from its own draft.
                    key: ValueKey('host-agent-new-$choice'),
                    choice: choice,
                    restored: acpDraftFor(choice),
                    enabled: !busy,
                    takenNames: takenNames,
                    onChanged: agentChanged,
                    onPrepare: prepareClaudeEnvironment,
                  ),
                  if (claudeSetup case final setup? when setup.running)
                    _claudeProgress(setup),
                ],
              ),
            ),
          ],
        )
      else
        CodexRuntimeSection(
          form: runtime,
          enabled: !busy,
          onBrowse: browseCodex,
        ),
      _model(l10n, null),
    ];
  }

  /// The running preparation's card; Cancel or Stop waiting sits in the
  /// action bar, by who owns the run.
  Widget _claudeProgress(AcpClaudeSetup setup) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: ClaudePreparationProgress(
      key: const Key('claude-prepare-progress'),
      setup: setup,
      joined: !ownsClaudePrepare,
    ),
  );

  Widget _actions(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final host = existing;
    return Material(
      color: scheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          // Side by side while both fit; otherwise (a narrow phone, large
          // text, a long translation) stacked at the end, each label free to
          // wrap, rather than overflowing the bar.
          child: OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            overflowAlignment: OverflowBarAlignment.end,
            overflowSpacing: 8,
            children: [
              // While Claude's adapter is being prepared by this page, Cancel
              // stops that preparation (only the npm process it started); one
              // joined from another caller is not this page's to stop, so it
              // offers Stop waiting, which ends only this page's operation.
              // Close stays beside either, unavailable until it is over.
              if ((claudeSetup?.running ?? false) && ownsClaudePrepare)
                TextButton(
                  key: const Key('claude-prepare-cancel'),
                  onPressed: cancelClaudePrepare,
                  child: Text(l10n.claudePrepareCancel),
                )
              else if (claudeSetup?.running ?? false)
                TextButton(
                  key: const Key('claude-prepare-stop-waiting'),
                  onPressed: stopWaitingForClaude,
                  child: Text(l10n.claudePrepareStopWaiting),
                ),
              TextButton(
                key: const Key('host-editor-close'),
                // Through the page's PopScope, so unsaved edits are asked
                // about first.
                onPressed: busy ? null : () => Navigator.of(context).maybePop(),
                child: Text(
                  host == null
                      ? l10n.cancel
                      : MaterialLocalizations.of(context).closeButtonLabel,
                ),
              ),
              if (host != null)
                FilledButton(
                  key: const Key('stop-hosting-btn'),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  ),
                  onPressed: busy || hostGone(liveHost) ? null : stop,
                  child: Text(l10n.stopHosting),
                )
              else
                FilledButton(
                  key: const Key('start-hosting-btn'),
                  onPressed: busy ? null : start,
                  child: Text(l10n.startHosting),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final host = existing;
    final messages = [
      if (notice != null)
        (const Key('host-editor-notice'), notice!, successColor(scheme)),
      if (error != null) (const Key('host-editor-error'), error!, scheme.error),
    ];
    return PopScope(
      canPop: canLeave,
      onPopInvokedWithResult: (didPop, _) async {
        // Gone from its route now, though still mounted while it animates
        // out: nothing it began goes on.
        if (didPop) {
          retireEditor();
          return;
        }
        final navigator = Navigator.of(context);
        if (await confirmLeave() && mounted) navigator.pop();
      },
      child: UtilityLeaveGuard(
        confirm: confirmLeave,
        child: UtilityPage(
          route: '/manage',
          title: host == null
              ? l10n.localHostDialogTitle
              : l10n.hostEditorTitle(host.name),
          parent: UtilityParent(title: l10n.manageServices, route: '/manage'),
          body: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  key: const Key('host-editor-scroll'),
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      // The settings column width, so editor and settings read
                      // as one family of pages.
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final section in _sections(l10n)) ...[
                            section,
                            const SizedBox(height: 12),
                          ],
                          for (final (key, message, color) in messages)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                message,
                                key: key,
                                style: TextStyle(color: color),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant),
              _actions(l10n),
            ],
          ),
        ),
      ),
    );
  }
}
