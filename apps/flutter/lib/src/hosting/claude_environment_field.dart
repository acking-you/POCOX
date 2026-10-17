import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/hosting/claude_environment_section.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/hosting/model_service_section.dart'
    show ServiceChoice;
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// The credentials Claude accepts, in the order they are offered. One is
/// used at a time: [ClaudeEnvironmentDraft.setOverride] clears the others.
const claudeCredentials = [
  'ANTHROPIC_AUTH_TOKEN',
  'ANTHROPIC_API_KEY',
  'CLAUDE_CODE_OAUTH_TOKEN',
];

/// The human name of environment variable [name].
String claudeVariableLabel(AppLocalizations l, String name) => switch (name) {
  'ANTHROPIC_BASE_URL' => l.claudeEnvBaseUrl,
  'ANTHROPIC_AUTH_TOKEN' => l.claudeEnvAuthToken,
  'ANTHROPIC_API_KEY' => l.claudeEnvApiKey,
  'CLAUDE_CODE_OAUTH_TOKEN' => l.claudeEnvOAuthToken,
  'ANTHROPIC_MODEL' => l.claudeEnvModel,
  'ANTHROPIC_DEFAULT_OPUS_MODEL' => l.claudeEnvOpus,
  'ANTHROPIC_DEFAULT_SONNET_MODEL' => l.claudeEnvSonnet,
  'ANTHROPIC_DEFAULT_HAIKU_MODEL' => l.claudeEnvHaiku,
  'ANTHROPIC_CUSTOM_MODEL_OPTION' => l.claudeEnvCustomModel,
  'CLAUDE_CODE_SUBAGENT_MODEL' => l.claudeEnvSubagentModel,
  'CLAUDE_CODE_EFFORT_LEVEL' => l.claudeEnvEffort,
  'MAX_THINKING_TOKENS' => l.claudeEnvThinkingTokens,
  'CLAUDE_CODE_MAX_OUTPUT_TOKENS' => l.claudeEnvOutputTokens,
  'CLAUDE_CODE_DISABLE_THINKING' => l.claudeEnvDisableThinking,
  'CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING' => l.claudeEnvDisableAdaptive,
  'API_TIMEOUT_MS' => l.claudeEnvTimeout,
  'HTTP_PROXY' => l.claudeEnvHttpProxy,
  'HTTPS_PROXY' => l.claudeEnvHttpsProxy,
  'NO_PROXY' => l.claudeEnvNoProxy,
  'DISABLE_PROMPT_CACHING' => l.claudeEnvDisableCaching,
  'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' => l.claudeEnvDisableTraffic,
  _ => name,
};

/// An enabled override whose new value is still empty (a stored secret left
/// blank is kept, so it is not missing).
bool claudeValueMissing(Map<String, String?> input, String name) =>
    input[name]?.isEmpty ?? false;

bool _isFlag(ClaudeVariable v) =>
    v.choices.length == 2 && v.choices.contains('0') && v.choices.contains('1');

TextInputType _keyboard(String name) => switch (name) {
  'ANTHROPIC_BASE_URL' || 'HTTP_PROXY' || 'HTTPS_PROXY' => TextInputType.url,
  'MAX_THINKING_TOKENS' ||
  'CLAUDE_CODE_MAX_OUTPUT_TOKENS' ||
  'API_TIMEOUT_MS' => TextInputType.number,
  _ => TextInputType.text,
};

/// An exact variable name in small monospace. It may break after any
/// underscore, so a long name wraps instead of setting the row's width.
class ClaudeVariableName extends StatelessWidget {
  /// Creates the name for [name].
  const ClaudeVariableName(this.name, {super.key});

  /// The exact environment name.
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      name.replaceAll('_', '_\u200B'),
      style: TextStyle(
        fontFamily: monoFontFamily,
        fontFamilyFallback: monoCjkFallback,
        fontSize: 11.5,
        height: 1.35,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

/// The edge of an overridden value: a hairline of ink on its start side, so
/// what this host changes reads at a glance while inherited rows stay quiet.
class ClaudeOverrideRail extends StatelessWidget {
  /// Creates the rail around [child]; [on] draws it.
  const ClaudeOverrideRail({super.key, required this.on, required this.child});

  /// Whether the value is overridden.
  final bool on;

  /// The row.
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsetsDirectional.only(start: 12),
    decoration: BoxDecoration(
      border: BorderDirectional(
        start: BorderSide(
          color: on
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 2,
        ),
      ),
    ),
    child: child,
  );
}

/// The value control of an overridden [variable]: a masked or plain field,
/// or wrapping choices (`0` / `1` read as Off / On, values stay exact).
class ClaudeValueControl extends StatelessWidget {
  /// Creates the control.
  const ClaudeValueControl({
    super.key,
    required this.draft,
    required this.variable,
    required this.enabled,
    required this.missing,
  });

  /// The environment being edited.
  final ClaudeEnvironmentDraft draft;

  /// The variable.
  final ClaudeVariable variable;

  /// Whether it can be edited.
  final bool enabled;

  /// It is enabled with no value yet.
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final name = variable.name;
    final controller = draft.field(name);
    final caution = cautionColor(Theme.of(context).colorScheme);
    if (variable.choices.isEmpty) {
      final stored = variable.secret && draft.stored(name);
      return TextField(
        key: Key('claude-env-value-$name'),
        controller: controller,
        enabled: enabled,
        obscureText: variable.secret,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: variable.secret ? TextInputType.text : _keyboard(name),
        decoration: InputDecoration(
          isDense: true,
          hintText: stored ? l.claudeEnvStored : l.claudeEnvValue,
          hintMaxLines: 2,
          prefixIcon: variable.secret
              ? const Icon(AppIcons.lock_outline, size: 18)
              : null,
          helperText: missing ? l.claudeEnvNeedsValue : null,
          helperMaxLines: 3,
          helperStyle: TextStyle(color: caution),
        ),
        onChanged: (_) => draft.edited(),
      );
    }
    final flag = _isFlag(variable);
    final choices = flag ? const ['1', '0'] : variable.choices;
    return Column(
      key: Key('claude-env-value-$name'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in choices)
              ServiceChoice(
                key: Key('claude-env-choice-$name-$value'),
                label: flag
                    ? (value == '1' ? l.claudeEnvFlagOn : l.claudeEnvFlagOff)
                    : value,
                selected: controller.text == value,
                onSelected: enabled
                    ? () {
                        controller.text = value;
                        draft.edited();
                      }
                    : null,
              ),
          ],
        ),
        if (missing) ...[
          const SizedBox(height: 6),
          EditorNote(l.claudeEnvNeedsValue, color: caution),
        ],
      ],
    );
  }
}

/// One variable: its name and exact identifier, a switch between inheriting
/// and overriding it for this host, and its value once overridden.
class ClaudeEnvironmentRow extends StatelessWidget {
  /// Creates the row for [variable].
  const ClaudeEnvironmentRow({
    super.key,
    required this.draft,
    required this.variable,
    required this.enabled,
    required this.missing,
  });

  /// The environment being edited.
  final ClaudeEnvironmentDraft draft;

  /// The variable.
  final ClaudeVariable variable;

  /// Whether it can be edited.
  final bool enabled;

  /// It is enabled with no value yet.
  final bool missing;

  /// The variable's label and name, marked when it is set here.
  Widget _heading(
    AppLocalizations l,
    ThemeData theme, {
    required bool custom,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        claudeVariableLabel(l, variable.name),
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w500,
          height: 1.3,
        ),
      ),
      const SizedBox(height: 2),
      ClaudeVariableName(variable.name),
      if (custom) ...[
        const SizedBox(height: 2),
        Text(
          l.claudeEnvCustom,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final name = variable.name;
    final custom = draft.custom(name);
    final toggle = enabled ? (bool v) => draft.setOverride(name, v) : null;
    return ClaudeOverrideRail(
      on: custom,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          MergeSemantics(
            child: InkWell(
              mouseCursor: clickable,
              onTap: toggle == null ? null : () => toggle(!custom),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(child: _heading(l, theme, custom: custom)),
                    const SizedBox(width: 12),
                    Switch.adaptive(
                      key: Key('claude-env-override-$name'),
                      value: custom,
                      onChanged: toggle,
                    ),
                  ],
                ),
              ),
            ),
          ),
          Motion.resize(
            context,
            alignment: AlignmentDirectional.topStart,
            child: custom
                ? Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 4),
                    child: ClaudeValueControl(
                      draft: draft,
                      variable: variable,
                      enabled: enabled,
                      missing: missing,
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// The credential, chosen once: inherit, or one of [variables]. Choosing
/// one calls [ClaudeEnvironmentDraft.setOverride], which already clears the
/// competing ones; Inherit turns every overridden credential off. Each
/// overridden credential shows its masked field (normally just one).
class ClaudeCredentialChoice extends StatelessWidget {
  /// Creates the choice.
  const ClaudeCredentialChoice({
    super.key,
    required this.draft,
    required this.variables,
    required this.enabled,
    required this.input,
  });

  /// The environment being edited.
  final ClaudeEnvironmentDraft draft;

  /// The credential variables offered, in order.
  final List<ClaudeVariable> variables;

  /// Whether it can be edited.
  final bool enabled;

  /// The draft's current input, for missing values.
  final Map<String, String?> input;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final active = [
      for (final v in variables)
        if (draft.custom(v.name)) v,
    ];
    return ClaudeOverrideRail(
      on: active.isNotEmpty,
      child: Column(
        key: const Key('claude-env-credential'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // That only one credential is used is behind the info mark.
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: InfoTitle(
              title: Text(
                l.claudeEnvCredential,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              info: l.claudeEnvCredentialNote,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ServiceChoice(
                key: const Key('claude-env-credential-inherit'),
                label: l.claudeEnvInherited,
                selected: active.isEmpty,
                onSelected: enabled
                    ? () {
                        for (final v in active) {
                          draft.setOverride(v.name, false);
                        }
                      }
                    : null,
              ),
              for (final v in variables)
                ServiceChoice(
                  key: Key('claude-env-override-${v.name}'),
                  label: claudeVariableLabel(l, v.name),
                  selected: draft.custom(v.name),
                  onSelected: enabled
                      ? () => draft.setOverride(v.name, true)
                      : null,
                ),
            ],
          ),
          Motion.resize(
            context,
            alignment: AlignmentDirectional.topStart,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final v in active) ...[
                  const SizedBox(height: 12),
                  ClaudeVariableName(v.name),
                  const SizedBox(height: 6),
                  ClaudeValueControl(
                    draft: draft,
                    variable: v,
                    enabled: enabled,
                    missing: claudeValueMissing(input, v.name),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
