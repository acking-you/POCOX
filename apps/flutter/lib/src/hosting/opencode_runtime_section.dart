import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/hosting/host_names.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';
import 'package:pocket_codex/src/widgets/group_card.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// What a native OpenCode host is started with: the instance name, where it
/// keeps its sessions ([separateHistory]) and the `opencode` executable
/// (detected on `PATH`, or chosen).
///
/// The host owns one `opencode serve` on loopback; its port and password
/// are the host's own and never shown. One host at a time serves OpenCode's
/// default database, so a new host beside it keeps a history of its own
/// unless the user chooses otherwise. A running host's form is [prefill]ed
/// from its saved (else active) runtime under its fixed name.
class OpenCodeRuntimeForm extends ChangeNotifier {
  /// Creates the form; [api] detects OpenCode.
  OpenCodeRuntimeForm(this._api);

  final BridgeApi _api;

  /// Instance name.
  final name = TextEditingController(text: 'opencode');

  /// Explicit executable path.
  final path = TextEditingController();

  bool _nameEdited = false;
  bool _disposed = false;
  int _detectSeq = 0;

  /// Moves on every explicit path decision (typing, picking, "change"); a
  /// late detection or file pick applies only while it is unchanged.
  int pathIntent = 0;

  /// The user chose the executable themselves.
  bool overridePath = false;

  /// The host keeps its sessions in a database of its own instead of
  /// OpenCode's default one.
  bool separateHistory = false;

  // The user picked the history; suggestions no longer replace it.
  bool _historyChosen = false;

  // Another host serves OpenCode's default database.
  bool _besideShared = false;

  bool _customProvider = false;

  /// The last detection, or null before it finished.
  OpenCodeEnvironment? found;

  /// The user changed a field.
  bool touched = false;

  // What a running host's form was filled with.
  String? _baselineBinary;
  bool _baselineSeparate = false;
  bool _prefilled = false;

  /// Mark the name as typed; suggestions no longer replace it.
  void nameEdited() {
    _nameEdited = true;
    edited();
  }

  /// Choose where the host keeps its sessions.
  void chooseHistory(bool separate) {
    _historyChosen = true;
    separateHistory = separate;
    edited();
  }

  /// A field changed by the user.
  void edited() {
    touched = true;
    _notify();
  }

  /// The user takes the executable path into their own hands (typing it,
  /// or "change"): a late detection or pick no longer replaces it.
  void customizePath() {
    overridePath = true;
    pathIntent++;
    edited();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Fill the fields from a running host's [runtime].
  void prefill(HostRuntime runtime) {
    _detectSeq++;
    _prefilled = true;
    _nameEdited = true;
    pathIntent++;
    _baselineBinary = runtime.binary;
    _baselineSeparate = runtime.separateHistory;
    separateHistory = runtime.separateHistory;
    _historyChosen = true;
    path.text = runtime.binary ?? '';
    overridePath = runtime.binary != null;
    touched = false;
    _notify();
    unawaited(detect());
  }

  /// Fill an untouched name with one free on this device, and an unpicked
  /// history with the one a new host can use: its own while another host
  /// serves OpenCode's default database.
  void suggest(List<AppServeStatus> hosts) {
    if (!_nameEdited) {
      name.text = uniqueHostName('opencode', {for (final h in hosts) h.name});
    }
    _besideShared = hosts.any((h) => h.servesOpenCodeHistory);
    _suggestHistory();
    _notify();
  }

  /// The host's model service is a custom provider, which OpenCode's
  /// background server cannot use: an unpicked history becomes its own.
  set customProvider(bool value) {
    if (value == _customProvider) return;
    _customProvider = value;
    _suggestHistory();
    _notify();
  }

  /// The shared history is served by OpenCode's background server, which a
  /// custom provider cannot use: this host could only follow it.
  bool get sharedNeedsBackgroundServer =>
      _customProvider && !separateHistory && (found?.backgroundServer ?? false);

  void _suggestHistory() {
    if (_historyChosen) return;
    separateHistory =
        _besideShared ||
        (_customProvider && (found?.backgroundServer ?? false));
  }

  /// The executable the fields name: an explicit path, else null (the
  /// bridge resolves `PATH`).
  String? get binary {
    if (!overridePath) return null;
    final typed = path.text.trim();
    return typed.isEmpty ? null : typed;
  }

  /// The runtime the fields describe, or why they cannot be used.
  (HostRuntime?, String?) read(AppLocalizations l10n) {
    // An unpicked history follows the detection (OpenCode 2's background
    // server), so it is not decided before the detection is.
    if (found == null && !_historyChosen) {
      return (null, l10n.openCodeDetecting);
    }
    if (overridePath && path.text.trim().isEmpty) {
      return (null, l10n.openCodePathRequired);
    }
    // The bridge checks again on start; a known problem is said here first.
    if (found case final env? when env.problem != null || env.path == null) {
      return (null, openCodeProblemText(l10n, env.problem));
    }
    return (
      HostRuntime.opencode(binary: binary, separateHistory: separateHistory),
      null,
    );
  }

  /// Whether a running host's runtime differs from what it was filled with.
  bool get differs =>
      _prefilled &&
      touched &&
      (binary != _baselineBinary || separateHistory != _baselineSeparate);

  /// (Re-)detect OpenCode for the current path; only the latest counts.
  Future<void> detect() async {
    final seq = ++_detectSeq;
    final asked = binary;
    found = null;
    _notify();
    OpenCodeEnvironment result;
    try {
      result = await _api.openCodeDetect(binary: asked);
    } catch (e) {
      result = OpenCodeEnvironment(problem: '$e');
    }
    if (_disposed || seq != _detectSeq) return;
    found = result;
    _suggestHistory();
    _notify();
  }

  /// Pick the executable; dropped when anything changed meanwhile.
  Future<void> browse(bool Function() stillApplies) async {
    final intent = pathIntent;
    final file = await openFile();
    if (file == null || _disposed) return;
    if (intent != pathIntent || !stillApplies()) return;
    path.text = file.path;
    overridePath = true;
    pathIntent++;
    edited();
    unawaited(detect());
  }

  @override
  void dispose() {
    _disposed = true;
    name.dispose();
    path.dispose();
    super.dispose();
  }
}

/// The "Runtime" section of an OpenCode host: instance name, history and
/// executable, with the detected version or why it cannot be hosted.
class OpenCodeRuntimeSection extends StatelessWidget {
  /// Creates the section for [form].
  const OpenCodeRuntimeSection({
    super.key,
    required this.form,
    required this.enabled,
    required this.onBrowse,
    this.fixedName = false,
    this.info,
    this.takenNames = const {},
    this.sharedHistoryHost,
  });

  /// The fields.
  final OpenCodeRuntimeForm form;

  /// Whether the fields can be edited.
  final bool enabled;

  /// Pick an executable.
  final VoidCallback onBrowse;

  /// A running host: its name is shown, not editable.
  final bool fixedName;

  /// Replaces the new host's explanation behind the title's info mark.
  final String? info;

  /// Names this device's other hosts use; a new host's name must differ.
  final Set<String> takenNames;

  /// Another host serving OpenCode's default database, by name: this host
  /// cannot share that history while it runs.
  final String? sharedHistoryHost;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: form,
      builder: (context, _) => GroupCard(
        key: const Key('opencode-runtime-section'),
        title: l10n.hostRuntimeInfo,
        info: info ?? l10n.openCodeRuntimeHint,
        children: [
          EditorBlock(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                HostNameField(
                  fieldKey: const Key('opencode-name-field'),
                  controller: form.name,
                  enabled: enabled,
                  fixed: fixedName,
                  taken: takenNames,
                  onChanged: (_) => form.nameEdited(),
                ),
                const SizedBox(height: 16),
                _history(context, l10n),
                const SizedBox(height: 16),
                _executable(context, l10n),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Where the host keeps its sessions: OpenCode's default database, which
  /// one host serves at a time, or one of its own.
  Widget _history(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final holder = sharedHistoryHost;
    final labels = [l10n.openCodeHistoryShared, l10n.openCodeHistoryOwn];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InfoTitle(
          title: Text(
            l10n.openCodeHistoryTitle,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          info: l10n.openCodeHistoryInfo,
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) => SegmentedButton<bool>(
            key: const Key('opencode-history'),
            // Side by side only while each label fits on one line.
            direction: segmentsFitAcross(context, constraints.maxWidth, labels)
                ? Axis.horizontal
                : Axis.vertical,
            segments: [
              ButtonSegment(
                value: false,
                label: Text(
                  labels[0],
                  key: const Key('opencode-history-shared'),
                ),
              ),
              ButtonSegment(
                value: true,
                label: Text(labels[1], key: const Key('opencode-history-own')),
              ),
            ],
            selected: {form.separateHistory},
            onSelectionChanged: enabled
                ? (picked) => form.chooseHistory(picked.first)
                : null,
          ),
        ),
        if (holder != null && !form.separateHistory) ...[
          const SizedBox(height: 8),
          EditorNote(
            l10n.openCodeHistoryTaken(holder),
            key: const Key('opencode-history-taken'),
            color: cautionColor(theme.colorScheme),
          ),
        ] else if (form.sharedNeedsBackgroundServer) ...[
          const SizedBox(height: 8),
          EditorNote(
            l10n.openCodeHistoryBackgroundServer,
            key: const Key('opencode-history-background-server'),
            color: cautionColor(theme.colorScheme),
          ),
        ],
      ],
    );
  }

  Widget _executable(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final env = form.found;
    if (env == null) {
      return Semantics(
        label: l10n.openCodeDetecting,
        child: const LinearProgressIndicator(),
      );
    }
    final ok = env.path != null && env.problem == null;
    final status = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? AppIcons.check_circle : AppIcons.error_outline,
          size: 18,
          color: ok ? successColor(scheme) : scheme.error,
        ),
        const SizedBox(width: 6),
        Expanded(
          // Wraps, not clips: a long path is the information.
          child: Text(
            ok
                ? l10n.openCodeFoundAt(env.version ?? '?', env.path!)
                : openCodeProblemText(l10n, env.problem),
            key: const Key('opencode-detected'),
            style: helpTextStyle(
              theme,
            ).copyWith(color: ok ? scheme.onSurface : scheme.error),
          ),
        ),
      ],
    );
    final children = <Widget>[status, const SizedBox(height: 8)];
    if (form.overridePath || !ok) {
      children.add(
        Row(
          // The button is centred on the field it fills.
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                key: const Key('opencode-path-field'),
                controller: form.path,
                enabled: enabled,
                decoration: InputDecoration(labelText: l10n.openCodePath),
                onChanged: (_) => form.customizePath(),
                onSubmitted: (_) => form.detect(),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const Key('browse-opencode-btn'),
              onPressed: enabled ? onBrowse : null,
              child: Text(l10n.chooseCodexPath),
            ),
          ],
        ),
      );
    }
    children.add(
      Wrap(
        spacing: 8,
        children: [
          if (!form.overridePath && ok)
            TextButton(
              key: const Key('customize-opencode-btn'),
              onPressed: enabled ? form.customizePath : null,
              child: Text(l10n.customizeCodexPath),
            ),
          TextButton.icon(
            key: const Key('redetect-opencode-btn'),
            onPressed: enabled ? form.detect : null,
            icon: const Icon(AppIcons.refresh, size: 16),
            label: Text(l10n.codexRedetect),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

/// [problem] (an [OpenCodeEnvironment] or host diagnostic) in words. The
/// bridge reports safe text, shown as given; the known codes are words for
/// fixtures and an older bridge.
String openCodeProblemText(AppLocalizations l10n, String? problem) =>
    switch (problem) {
      null || 'not_found' => l10n.openCodeNotFound,
      'unsupported_version' => l10n.openCodeUnsupportedVersion,
      'no_provider' => l10n.openCodeNoProvider,
      'opencode_already_hosted' => l10n.openCodeAlreadyHosted,
      final other => other,
    };
