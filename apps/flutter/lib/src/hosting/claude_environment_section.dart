import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/claude_environment_field.dart';
import 'package:pocket_codex/src/hosting/claude_environment_group.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// Per-field inheritance and secret retention, owned by one host draft.
class ClaudeEnvironmentDraft extends ChangeNotifier {
  List<ClaudeVariable> variables = const [];
  Map<String, String?> _saved = const {};
  final Set<String> _overrides = {};
  final Map<String, TextEditingController> _fields = {};

  TextEditingController field(String name) =>
      _fields.putIfAbsent(name, TextEditingController.new);
  bool custom(String name) => _overrides.contains(name);
  bool stored(String name) => _saved.containsKey(name);

  void load(Map<String, String?> values) {
    _saved = Map.of(values);
    _overrides
      ..clear()
      ..addAll(values.keys);
    for (final controller in _fields.values) {
      controller.clear();
    }
    for (final entry in values.entries) {
      field(entry.key).text = entry.value ?? '';
    }
    notifyListeners();
  }

  void setOverride(String name, bool value) {
    if (value) {
      if (claudeCredentials.contains(name)) {
        _overrides.removeAll(claudeCredentials.where((c) => c != name));
      }
      _overrides.add(name);
    } else {
      _overrides.remove(name);
    }
    notifyListeners();
  }

  void edited() => notifyListeners();

  Map<String, String?> get input => {
    for (final name in _overrides)
      name:
          field(name).text.trim().isEmpty &&
              _saved.containsKey(name) &&
              _saved[name] == null
          ? null
          : field(name).text.trim(),
  };

  bool get valid => input.values.every((v) => v == null || v.isNotEmpty);

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }
}

/// Explicit host overrides of Claude's startup environment. No credential
/// values are fetched for display, and this editor never writes shell files.
///
/// Defaults are quiet and changes stand out. The header counts this host's
/// overrides. Each closed group says whether it inherits everything or which
/// values it overrides. An overridden row carries an ink rail and its value.
/// The credential is one choice, since only one is used. With a custom
/// provider, its fields win: the connection group and the default model are
/// initially hidden, and their values stay in the draft unchanged. They can
/// be revealed to fix or remove an inactive override before saving.
class ClaudeEnvironmentSection extends StatefulWidget {
  /// Creates the section for [draft].
  const ClaudeEnvironmentSection({
    super.key,
    required this.draft,
    required this.enabled,
    required this.customProvider,
  });

  /// The environment being edited.
  final ClaudeEnvironmentDraft draft;

  /// Whether it can be edited.
  final bool enabled;

  /// A custom provider supplies the connection and default model.
  final bool customProvider;

  @override
  State<ClaudeEnvironmentSection> createState() =>
      _ClaudeEnvironmentSectionState();
}

class _ClaudeEnvironmentSectionState extends State<ClaudeEnvironmentSection> {
  /// Open groups; kept here, never in PageStorage, whose slots the fields'
  /// own scroll offsets would share.
  final Set<String> _open = {};
  bool _showDormant = false;

  static const _groups = {
    'connection': AppIcons.vpn_key_outlined,
    'models': AppIcons.layers_outlined,
    'reasoning': AppIcons.psychology_outlined,
    'network': AppIcons.lan_outlined,
  };

  bool _dormant(ClaudeVariable v) =>
      widget.customProvider &&
      (v.group == 'connection' || v.name == 'ANTHROPIC_MODEL');

  bool _hidden(ClaudeVariable v) => _dormant(v) && !_showDormant;

  String _groupTitle(AppLocalizations l, String id) => switch (id) {
    'connection' => l.claudeEnvConnection,
    'models' => l.claudeEnvModels,
    'reasoning' => l.claudeEnvReasoning,
    _ => l.claudeEnvNetwork,
  };

  List<Widget> _rows(List<ClaudeVariable> vars, Map<String, String?> input) {
    final d = widget.draft;
    final credentials = [
      for (final v in vars)
        if (claudeCredentials.contains(v.name)) v,
    ];
    final rows = <Widget>[];
    var credentialShown = false;
    for (final v in vars) {
      if (claudeCredentials.contains(v.name)) {
        if (credentialShown) continue;
        credentialShown = true;
        rows.add(
          ClaudeCredentialChoice(
            draft: d,
            variables: credentials,
            enabled: widget.enabled,
            input: input,
          ),
        );
        continue;
      }
      rows.add(
        ClaudeEnvironmentRow(
          key: ValueKey('claude-env-row-${v.name}'),
          draft: d,
          variable: v,
          enabled: widget.enabled,
          missing: claudeValueMissing(input, v.name),
        ),
      );
    }
    return rows;
  }

  Widget _group(
    AppLocalizations l,
    String id,
    List<ClaudeVariable> vars,
    Map<String, String?> input,
  ) {
    final d = widget.draft;
    final changed = [
      for (final v in vars)
        if (d.custom(v.name)) v,
    ];
    final missing = changed.any((v) => claudeValueMissing(input, v.name));
    return ClaudeEnvironmentGroup(
      id: id,
      icon: _groups[id]!,
      title: _groupTitle(l, id),
      summary: changed.isEmpty
          ? l.claudeEnvGroupInherited
          : changed.map((v) => claudeVariableLabel(l, v.name)).join(' · '),
      count: changed.length,
      attention: missing ? l.claudeEnvGroupMissing : null,
      expanded: _open.contains(id),
      onToggle: () => setState(() {
        if (!_open.remove(id)) _open.add(id);
      }),
      children: _rows(vars, input),
    );
  }

  Widget _providerNote(AppLocalizations l, int dormant) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const Key('claude-env-provider-wins'),
      decoration: claudePanelDecoration(scheme),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              AppIcons.info_outline,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  EditorNote(l.claudeEnvProviderWins),
                  if (dormant > 0) ...[
                    const SizedBox(height: 4),
                    EditorNote(
                      l.claudeEnvDormant(dormant),
                      key: const Key('claude-env-dormant'),
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        key: const Key('claude-env-edit-dormant'),
                        onPressed: () => setState(() {
                          _showDormant = !_showDormant;
                        }),
                        child: Text(
                          _showDormant ? l.showLess : l.claudeEnvEditDormant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final d = widget.draft;
    final input = d.input;
    final visible = [
      for (final v in d.variables)
        if (!_hidden(v)) v,
    ];
    final overrides = visible.where((v) => d.custom(v.name)).length;
    final missing = visible
        .where((v) => d.custom(v.name) && claudeValueMissing(input, v.name))
        .length;
    final dormant = d.variables
        .where((v) => _dormant(v) && d.custom(v.name))
        .length;
    final sections = <Widget>[
      if (widget.customProvider) _providerNote(l, dormant),
      for (final id in _groups.keys)
        if (visible.where((v) => v.group == id).toList() case final vars
            when vars.isNotEmpty)
          _group(l, id, vars, input),
    ];
    return Column(
      key: const Key('claude-environment-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              // How inheritance and overrides work is behind the info mark.
              InfoTitle(
                title: Text(
                  l.claudeEnvTitle,
                  style: theme.textTheme.titleSmall,
                ),
                info: l.claudeEnvHint,
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ClaudeEnvironmentPill(
                    key: const Key('claude-env-status'),
                    overrides == 0
                        ? l.claudeEnvAllInherited
                        : l.claudeEnvOverrides(overrides),
                  ),
                  if (missing > 0)
                    ClaudeEnvironmentPill(
                      key: const Key('claude-env-missing'),
                      l.claudeEnvMissing(missing),
                      color: cautionColor(theme.colorScheme),
                    ),
                ],
              ),
            ],
          ),
        ),
        for (final section in sections) ...[
          const SizedBox(height: 10),
          section,
        ],
      ],
    );
  }
}
