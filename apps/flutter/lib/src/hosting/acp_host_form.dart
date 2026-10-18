import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/hosting/agent_choice_grid.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/hosting/host_names.dart';
import 'package:pocket_codex/src/hosting/argv_editor.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/text_measure.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// What the ACP form currently describes.
class AcpFormValue {
  /// Creates a form value.
  const AcpFormValue({
    required this.name,
    required this.spec,
    required this.save,
    this.claudePrepareShown = false,
    this.claudeShown,
    this.nameEdited = false,
  });

  /// Instance name (defaults to the profile id when empty).
  final String name;

  /// The user typed [name] (a suggested one follows the agent).
  final bool nameEdited;

  /// The agent to host.
  final AcpAgentSpec spec;

  /// Whether to save a custom agent to "my agents".
  final bool save;

  /// The form is showing that Start will prepare Claude's missing adapter
  /// (so a download never starts unannounced).
  final bool claudePrepareShown;

  /// The environment that announcement described; Start prepares only while
  /// it still finds the same one (see [claudeAnnouncementKey]).
  final AcpClaudeStatus? claudeShown;

  /// Whether the value can be submitted.
  bool get valid =>
      spec.program.trim().isNotEmpty && spec.displayName.trim().isNotEmpty;
}

/// Whether [spec] is the Claude preset's own adapter program, whose launch
/// the host discovers (adapter, Node.js and native CLI) instead of resolving
/// the program alone.
bool isClaudeAdapterSpec(AcpAgentSpec spec) =>
    spec.profileId == 'claude' && spec.program.trim() == 'claude-agent-acp';

/// What an announced adapter preparation is about: the agent's program and
/// arguments and the environment found for it (adapter state, Node.js
/// runtime, package). A preparation is announced for exactly one of these;
/// a different agent or environment needs its own announcement.
String claudeAnnouncementKey(AcpAgentSpec spec, AcpClaudeStatus status) =>
    jsonEncode([
      spec.program,
      spec.args,
      status.adapter,
      status.runtime,
      status.runtimePath,
      status.runtimeVersion,
      status.package,
      status.canPrepare,
    ]);

/// The profile id of a new custom agent named [name]. The readable part is
/// a lossy slug (names in other scripts all become `agent`), so [salt] —
/// random per new agent, see [newProfileSalt] — keeps two custom agents
/// from ever sharing a saved entry. The id only names the saved entry: the
/// host binds sessions to the program and arguments actually run.
String customProfileId(String name, String salt) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final cut = slug.length > 40 ? slug.substring(0, 40) : slug;
  return 'custom-${cut.isEmpty ? 'agent' : cut}-$salt';
}

/// Eight random hex digits for [customProfileId].
String newProfileSalt([Random? random]) {
  final source = random ?? Random.secure();
  return [
    for (var i = 0; i < 8; i++) source.nextInt(16).toRadixString(16),
  ].join();
}

/// The new-ACP-host form for the agent picked in the dialog's agent grid
/// ([choice]: `preset:<id>`, `saved:<profileId>` or `custom`).
///
/// Essentials first — the instance name and whether the program was found.
/// The program and argument vector of a preset or saved agent sit behind
/// "Advanced"; a custom agent shows them open, since they are what it is.
class AcpHostForm extends ConsumerStatefulWidget {
  /// Creates the form; [onChanged] receives every edit.
  const AcpHostForm({
    super.key,
    required this.choice,
    required this.onChanged,
    this.enabled = true,
    this.takenNames = const {},
    this.initial,
    this.fixedName,
    this.restored,
    this.onPrepare,
  });

  /// The agent picked in the grid.
  final String choice;

  /// The agent to edit (a running host's spec) instead of [choice]'s
  /// defaults.
  final AcpAgentSpec? initial;

  /// The running host's instance name, shown and not editable.
  final String? fixedName;

  /// What this form showed for [choice] before another agent was picked:
  /// restored instead of [choice]'s defaults, so switching back loses no
  /// edit.
  final AcpFormValue? restored;

  /// Called with the current value.
  final ValueChanged<AcpFormValue> onChanged;

  /// Prepare the Claude adapter without starting a host, then refresh detection.
  final Future<void> Function()? onPrepare;

  /// Whether the fields can be edited.
  final bool enabled;

  /// Instance names running hosts already use on this device; the suggested
  /// name avoids them and a typed one must differ.
  final Set<String> takenNames;

  @override
  ConsumerState<AcpHostForm> createState() => _AcpHostFormState();
}

class _AcpHostFormState extends ConsumerState<AcpHostForm> {
  static const _custom = customAgentChoice;
  // One per new custom agent this form describes (kept by a restore).
  String _salt = newProfileSalt();
  final _name = TextEditingController();
  final _displayName = TextEditingController();
  final _program = TextEditingController();
  List<String> _args = const [];
  List<String> _argsSeed = const [];
  String _choice = _custom;
  String _profileId = '';
  bool _save = true;
  bool _advanced = false;
  // Whether the user typed an instance name; a suggested one follows the
  // agent choice, a typed one stays.
  bool _nameEdited = false;
  String? _located;
  // The Claude preset's environment, when that is what the form describes.
  AcpClaudeStatus? _claude;
  bool _locating = false;
  // The last lookup failed (shown with a retry), as opposed to not found.
  String? _locateError;
  Timer? _locateDebounce;
  // Moves on every change of the program or agent, so a lookup or a file
  // pick started before it can never publish its result.
  int _locateSeq = 0;
  int _choiceSeq = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    final restored = widget.restored;
    if (restored != null) {
      _restore(restored);
    } else if (initial == null) {
      _select(widget.choice, emit: false);
    } else {
      _apply(widget.choice, initial, emit: false);
    }
    if (widget.fixedName case final name?) {
      _name.text = name;
      _nameEdited = true;
    }
    Future.microtask(() {
      if (!mounted) return;
      _emit();
      _locate();
    });
  }

  @override
  void didUpdateWidget(AcpHostForm old) {
    super.didUpdateWidget(old);
    if (old.choice != widget.choice) {
      _select(widget.choice);
    } else if (!_nameEdited && !setEquals(old.takenNames, widget.takenNames)) {
      // Running hosts arrived (or changed): an untouched suggestion moves
      // off any name they now use; a typed name stays.
      _name.text = uniqueHostName(_nameBase, widget.takenNames);
      _emit();
    }
  }

  /// Show [value] again for [AcpHostForm.choice] (see [AcpHostForm.restored]).
  void _restore(AcpFormValue value) {
    final custom = widget.choice == _custom;
    final id = value.spec.profileId;
    final salt = RegExp(r'-([0-9a-f]{8})$').firstMatch(id)?.group(1);
    // The same custom agent keeps its id: its salt is kept.
    if (custom && salt != null) _salt = salt;
    _apply(widget.choice, value.spec, emit: false);
    _save = value.save || !custom;
    if (value.nameEdited) {
      _name.text = value.name;
      _nameEdited = true;
    }
  }

  String get _nameBase => _choice == _custom ? 'agent' : _profileId;

  /// Load [choice] into the fields: a preset, a saved agent, or empty
  /// fields for a new custom agent.
  void _select(String choice, {bool emit = true}) {
    final presets = ref.read(bridgeApiProvider).acpPresets();
    final saved =
        ref.read(uiPrefsProvider).valueOrNull?.acpAgents ??
        const <AcpAgentSpec>[];
    AcpAgentSpec? spec;
    if (choice.startsWith('preset:')) {
      final id = choice.substring(7);
      spec = presets.where((p) => p.id == id).firstOrNull?.spec;
    } else if (choice.startsWith('saved:')) {
      final id = choice.substring(6);
      spec = saved.where((a) => a.profileId == id).firstOrNull;
    }
    _apply(
      spec == null ? _custom : choice,
      spec ?? const AcpAgentSpec(profileId: '', displayName: '', program: ''),
      emit: emit,
    );
  }

  @override
  void dispose() {
    _locateDebounce?.cancel();
    _name.dispose();
    _displayName.dispose();
    _program.dispose();
    super.dispose();
  }

  bool get _isCustom => !_choice.startsWith('preset:');

  void _apply(String choice, AcpAgentSpec spec, {bool emit = true}) {
    _choiceSeq++;
    _choice = choice;
    _profileId = spec.profileId;
    _displayName.text = spec.displayName;
    _program.text = spec.program;
    _args = List.of(spec.args);
    _argsSeed = _args;
    // A custom agent is defined by its program and arguments: show them.
    _advanced = choice == _custom;
    if (!_nameEdited || _name.text.trim().isEmpty) {
      _nameEdited = false;
      _name.text = uniqueHostName(_nameBase, widget.takenNames);
    }
    if (emit) {
      _emit();
      _locate();
    }
  }

  AcpAgentSpec get _spec {
    final display = _displayName.text.trim();
    final id = _choice == _custom
        ? customProfileId(display, _salt)
        : _profileId;
    return AcpAgentSpec(
      profileId: id,
      displayName: display,
      // Paths may legitimately contain spaces; only surrounding whitespace,
      // which is never part of a typed path, is dropped.
      program: _program.text.trim(),
      args: List.unmodifiable(_args),
    );
  }

  void _emit() {
    final claude = _claude;
    widget.onChanged(
      AcpFormValue(
        name: _name.text.trim(),
        spec: _spec,
        save: _save && _isCustom,
        claudePrepareShown:
            !_locating &&
            claude != null &&
            claude.adapter == 'missing' &&
            claude.canPrepare,
        claudeShown: _locating ? null : claude,
        nameEdited: _nameEdited,
      ),
    );
  }

  void _locate() {
    _locateDebounce?.cancel();
    // Invalidate any lookup in flight at once, not when the debounce fires.
    final seq = ++_locateSeq;
    final program = _program.text.trim();
    final profileId = _profileId;
    final claude = isClaudeAdapterSpec(_spec);
    if (program.isEmpty) {
      if (mounted) {
        setState(() {
          _located = null;
          _claude = null;
          _locating = false;
          _locateError = null;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _locating = true;
        _locateError = null;
        // What was found for the previous program says nothing now.
        _claude = null;
      });
      _emit();
    }
    _locateDebounce = Timer(const Duration(milliseconds: 300), () async {
      String? found;
      AcpClaudeStatus? environment;
      String? error;
      try {
        final api = ref.read(bridgeApiProvider);
        if (claude) {
          environment = await api.acpClaudeStatus();
          found = environment.adapterPath;
        } else {
          found = await api.acpLocate(program, profileId: profileId);
        }
      } catch (e) {
        error = friendlyError(e);
      }
      if (!mounted || seq != _locateSeq) return;
      setState(() {
        _located = found;
        _claude = environment;
        _locateError = error;
        _locating = false;
      });
      _emit();
    });
  }

  Future<void> _prepareEnvironment() async {
    final prepare = widget.onPrepare;
    if (prepare == null || !widget.enabled) return;
    final choice = _choiceSeq;
    final lookup = _locateSeq;
    await prepare();
    if (!mounted || choice != _choiceSeq || lookup != _locateSeq) return;
    _locate();
  }

  Future<void> _browse() async {
    final choice = _choiceSeq;
    final file = await openFile();
    // A pick finishing after the agent changed belongs to the old one.
    if (file == null || !mounted || choice != _choiceSeq || !widget.enabled) {
      return;
    }
    setState(() => _program.text = file.path);
    _emit();
    _locate();
  }

  /// The program and its arguments, under Advanced.
  List<Widget> _programFields(AppLocalizations l10n) => [
    const SizedBox(height: 4),
    // What a program may be is shown while it is being entered.
    FocusHelp(
      help: l10n.acpProgramHint,
      child: LayoutBuilder(
        builder: (context, constraints) =>
            _programRow(context, l10n, constraints.maxWidth),
      ),
    ),
    const SizedBox(height: 18),
    ArgvEditor(
      key: const Key('acp-argv-editor'),
      initial: _argsSeed,
      enabled: widget.enabled,
      onChanged: (args) {
        _args = args;
        _emit();
      },
    ),
  ];

  /// The program field with its Browse button: side by side only while the
  /// field keeps room for a short program name and its label beside the
  /// button in [width]; otherwise the button goes under the field, which then
  /// has the whole width.
  Widget _programRow(
    BuildContext context,
    AppLocalizations l10n,
    double width,
  ) {
    final enabled = widget.enabled;
    final field = TextField(
      key: const Key('acp-program-field'),
      controller: _program,
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: l10n.acpProgram),
      onChanged: (_) {
        _emit();
        _locate();
      },
    );
    final browse = OutlinedButton(
      key: const Key('acp-program-browse'),
      onPressed: enabled ? _browse : null,
      style: OutlinedButton.styleFrom(padding: _browsePadding),
      child: Text(l10n.acpProgramBrowse, maxLines: 1, softWrap: false),
    );
    final browseWidth =
        _browsePadding.horizontal +
        measureTextLine(
          context,
          l10n.acpProgramBrowse,
          OutlinedButtonTheme.of(context).style?.textStyle?.resolve(const {}) ??
              Theme.of(context).textTheme.labelLarge,
        ).width;
    final fieldMinimum =
        MediaQuery.textScalerOf(context).scale(16) * _programFieldGlyphs;
    if (width - 8 - browseWidth >= fieldMinimum) {
      return Row(
        // The button is centred on the field it fills.
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: field),
          const SizedBox(width: 8),
          browse,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        field,
        const SizedBox(height: 8),
        Align(alignment: AlignmentDirectional.centerEnd, child: browse),
      ],
    );
  }

  /// What the lookup of the program found, once it answered: why it
  /// failed (with a retry), the Claude preset's environment, or whether the
  /// program is there.
  Widget? _lookupStatus(
    AppLocalizations l10n,
    ColorScheme scheme,
    TextStyle small,
  ) {
    final enabled = widget.enabled;
    if (_program.text.trim().isEmpty || _locating) return null;
    if (_locateError case final error?) {
      return Row(
        key: const Key('acp-program-locate-failed'),
        children: [
          Expanded(
            child: Text(
              error,
              style: small.copyWith(color: scheme.error),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            key: const Key('acp-program-locate-retry'),
            onPressed: enabled ? _locate : null,
            child: Text(l10n.retry),
          ),
        ],
      );
    }
    if (_claude case final claude?) {
      return ClaudeEnvironment(
        status: claude,
        onRecheck: enabled ? _locate : null,
        onPrepare: widget.onPrepare == null ? null : _prepareEnvironment,
        enabled: enabled,
      );
    }
    if (_located case final located?) {
      return Text(
        l10n.acpProgramFound(located),
        key: const Key('acp-program-found'),
        style: small.copyWith(color: successColor(scheme)),
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
      );
    }
    return EditorNote(
      l10n.acpProgramNotFound,
      key: const Key('acp-program-missing'),
      color: scheme.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final small = helpTextStyle(Theme.of(context));
    final api = ref.watch(bridgeApiProvider);
    final enabled = widget.enabled;
    if (!api.acpHostingSupported()) {
      return Text(
        l10n.acpHostingUnsupported,
        key: const Key('acp-hosting-unsupported'),
        style: TextStyle(color: cautionColor(scheme)),
      );
    }
    final status = _lookupStatus(l10n, scheme, small);
    return Column(
      key: const Key('acp-host-form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isCustom) ...[
          TextField(
            key: const Key('acp-display-name-field'),
            controller: _displayName,
            enabled: enabled,
            decoration: InputDecoration(labelText: l10n.acpAgentName),
            onChanged: (_) => _emit(),
          ),
          const SizedBox(height: 14),
        ],
        HostNameField(
          fieldKey: const Key('acp-instance-name-field'),
          controller: _name,
          enabled: enabled,
          fixed: widget.fixedName != null,
          taken: widget.takenNames,
          onChanged: (_) {
            // The field's clash check reads the typed name.
            setState(() => _nameEdited = true);
            _emit();
          },
        ),
        if (status != null) ...[const SizedBox(height: 10), status],
        const SizedBox(height: 6),
        AdvancedToggle(
          key: const Key('acp-advanced-toggle'),
          open: _advanced,
          // Reseed the argument editor from the current vector, so folding
          // and unfolding keeps edits.
          onChanged: (open) => setState(() {
            _advanced = open;
            _argsSeed = List.of(_args);
          }),
        ),
        if (_advanced) ..._programFields(l10n),
        if (_isCustom) ...[
          const SizedBox(height: 6),
          // What saving means for secrets is the switch's own subtitle.
          SwitchListTile(
            key: const Key('acp-save-agent'),
            contentPadding: EdgeInsets.zero,
            value: _save,
            title: Text(l10n.acpSaveAgent),
            subtitle: EditorNote(l10n.acpSecretsNote),
            onChanged: !enabled
                ? null
                : (value) {
                    setState(() => _save = value);
                    _emit();
                  },
          ),
        ],
      ],
    );
  }
}

/// What the Claude preset will run on this computer: its ACP adapter (or
/// an explicit preparation action), the Node.js that runs it and the native
/// CLI it drives. Shown before preparation, so a download is never a surprise.
class ClaudeEnvironment extends StatelessWidget {
  /// Creates the panel for [status].
  const ClaudeEnvironment({
    super.key,
    required this.status,
    this.onRecheck,
    this.onPrepare,
    this.enabled = true,
  });

  /// The detected environment.
  final AcpClaudeStatus status;

  /// Detect again (after installing something); `null` disables it.
  final VoidCallback? onRecheck;

  /// Prepare the missing adapter independently of hosting.
  final VoidCallback? onPrepare;

  /// Whether an editor operation permits starting preparation.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = helpTextStyle(theme);
    // One row per component: a state mark and what was found. A found
    // component is one line, its full path in the tooltip; a problem wraps,
    // since what to do about it is the information.
    Widget line(String key, String text, _Tone tone) {
      final (icon, color) = switch (tone) {
        _Tone.ok => (AppIcons.check_circle, successColor(scheme)),
        _Tone.caution => (AppIcons.warning_amber_rounded, cautionColor(scheme)),
        _Tone.bad => (AppIcons.error_outline, scheme.error),
        _Tone.neutral => (AppIcons.info_outline, scheme.onSurfaceVariant),
      };
      final wrap = tone == _Tone.caution || tone == _Tone.bad;
      final row = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              key: Key(key),
              maxLines: wrap ? null : 1,
              overflow: wrap ? null : TextOverflow.ellipsis,
              style: body.copyWith(
                color: tone == _Tone.bad ? scheme.error : scheme.onSurface,
              ),
            ),
          ),
        ],
      );
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: wrap
            ? row
            : Tooltip(
                message: text,
                waitDuration: const Duration(milliseconds: 600),
                excludeFromSemantics: true,
                child: row,
              ),
      );
    }

    final adapter = switch (status.adapter) {
      'unavailable' => null,
      'installed' => line(
        'claude-adapter',
        l10n.claudeAdapterInstalled(status.adapterPath ?? ''),
        _Tone.ok,
      ),
      'prepared' => line(
        'claude-adapter',
        l10n.claudeAdapterPrepared(status.adapterPath ?? ''),
        _Tone.ok,
      ),
      _ when status.canPrepare => line(
        'claude-adapter-will-prepare',
        l10n.claudeAdapterWillPrepare(status.package),
        _Tone.caution,
      ),
      _ => line(
        'claude-adapter-missing',
        l10n.claudeAdapterMissing(status.package),
        _Tone.bad,
      ),
    };
    final version = status.runtimeVersion ?? '';
    final runtime = switch (status.runtime) {
      'found' => line(
        'claude-node',
        l10n.claudeNodeFound(version, status.runtimePath ?? ''),
        _Tone.ok,
      ),
      'tooOld' => line(
        'claude-node-old',
        l10n.claudeNodeTooOld(version),
        _Tone.bad,
      ),
      'missing' => line(
        'claude-node-missing',
        l10n.claudeNodeMissing,
        _Tone.bad,
      ),
      _ => null,
    };
    final cli = switch (status.cli) {
      'found' => line(
        'claude-cli',
        l10n.claudeCliFound(status.cliPath ?? ''),
        _Tone.ok,
      ),
      'inherited' => line(
        'claude-cli-inherited',
        l10n.claudeCliInherited,
        _Tone.ok,
      ),
      _ => line('claude-cli-bundled', l10n.claudeCliBundled, _Tone.neutral),
    };
    final problem = status.problem;
    return Column(
      key: const Key('claude-environment'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.claudeRuntimeTitle,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              key: const Key('claude-recheck'),
              onPressed: onRecheck,
              child: Text(l10n.claudeEnvRecheck),
            ),
          ],
        ),
        ?adapter,
        ?runtime,
        cli,
        if (!status.ready && !status.canPrepare && problem != null)
          line('claude-problem', problem, _Tone.bad),
        if (!status.ready && status.canPrepare && onPrepare != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('claude-prepare-environment'),
            onPressed: enabled ? onPrepare : null,
            icon: const Icon(AppIcons.download_rounded, size: 18),
            label: Text(l10n.claudePrepareEnvironment),
          ),
        ],
      ],
    );
  }
}

/// How a runtime component's line reads.
enum _Tone { ok, caution, bad, neutral }

/// A compact "Advanced" disclosure, shared by the Codex and ACP forms: a text button with a chevron that
/// reveals rarely-changed fields below it.
class AdvancedToggle extends StatelessWidget {
  /// Creates the toggle, [open] or folded.
  const AdvancedToggle({
    super.key,
    required this.open,
    required this.onChanged,
  });

  /// Whether the advanced fields are shown.
  final bool open;

  /// Called with the new state.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        onPressed: () => onChanged(!open),
        icon: Icon(
          open ? AppIcons.expand_less_rounded : AppIcons.expand_more_rounded,
          size: 18,
        ),
        label: Text(l10n.hostAdvanced),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(0, 40),
        ),
      ),
    );
  }
}

/// The Browse button's own padding, so its width is known before layout.
const _browsePadding = EdgeInsets.symmetric(horizontal: 16);

/// How many 16 px glyphs the program field keeps beside the Browse button.
const _programFieldGlyphs = 12;
