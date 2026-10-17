import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// The agent a new host runs, as picked in [AgentChoiceGrid].
///
/// `codex` (native app-server), `opencode` (native `opencode serve`),
/// `preset:<id>` (a built-in ACP preset), `saved:<profileId>` (a saved
/// configuration) or `custom` (a new ACP agent).
typedef AgentChoice = String;

/// The native Codex choice.
const AgentChoice codexChoice = 'codex';

/// The native OpenCode choice.
const AgentChoice openCodeChoice = 'opencode';

/// A new custom ACP agent.
const AgentChoice customAgentChoice = 'custom';

/// Whether [choice] hosts an ACP agent.
bool isAcpChoice(AgentChoice choice) =>
    choice != codexChoice && choice != openCodeChoice;

/// One tile per agent this device can host, grouped by launch source:
/// built-in presets (Codex, OpenCode and the ACP presets) and saved
/// configurations (then "custom", which creates one). A tile shows the
/// agent's mark and name; its section and its tooltip name the source, so a
/// saved agent sharing a preset's name and mark stays distinguishable.
/// Tiles are identified by profile id, never by a host name.
///
/// Tile width follows the text scale and each section wraps its tiles to the
/// available width.
class AgentChoiceGrid extends StatelessWidget {
  /// Creates the grid with [value] selected.
  const AgentChoiceGrid({
    super.key,
    required this.value,
    required this.presets,
    required this.saved,
    required this.onChanged,
  });

  /// The selected choice.
  final AgentChoice value;

  /// Built-in ACP presets.
  final List<AcpPreset> presets;

  /// Saved custom ACP agents.
  final List<AcpAgentSpec> saved;

  /// Called with a new choice; null disables every tile.
  final ValueChanged<AgentChoice>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final builtIn = <Widget>[
      _AgentTile(
        choice: codexChoice,
        selected: value == codexChoice,
        title: l10n.providerCodex,
        source: l10n.agentChoiceNative,
        icon: const AgentIcon(kind: AgentKind.codex, size: 22),
        onTap: onChanged,
      ),
      _AgentTile(
        choice: openCodeChoice,
        selected: value == openCodeChoice,
        title: l10n.providerOpenCode,
        source: l10n.agentChoiceNativeServer,
        icon: const AgentIcon(kind: AgentKind.opencode, size: 22),
        onTap: onChanged,
      ),
      for (final preset in presets)
        _AgentTile(
          choice: 'preset:${preset.id}',
          selected: value == 'preset:${preset.id}',
          title: preset.displayName,
          source: l10n.agentChoicePreset,
          icon: AgentIcon.of(
            provider: 'acp',
            profileId: preset.id,
            name: preset.displayName,
            size: 22,
          ),
          onTap: onChanged,
        ),
    ];
    final mine = <Widget>[
      for (final agent in saved)
        _AgentTile(
          choice: 'saved:${agent.profileId}',
          selected: value == 'saved:${agent.profileId}',
          title: agent.displayName,
          source: l10n.agentChoiceSaved,
          icon: AgentIcon.of(
            provider: 'acp',
            profileId: agent.profileId,
            name: agent.displayName,
            size: 22,
          ),
          onTap: onChanged,
        ),
      _AgentTile(
        choice: customAgentChoice,
        selected: value == customAgentChoice,
        title: l10n.acpAgentCustom,
        source: l10n.agentChoiceNew,
        icon: Icon(
          AppIcons.add_rounded,
          size: 22,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        onTap: onChanged,
      ),
    ];
    return Semantics(
      container: true,
      label: l10n.providerLabel,
      child: Column(
        key: const Key('agent-choice-grid'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Section(
            key: const Key('agent-choice-builtin'),
            title: l10n.agentChoiceBuiltinTitle,
            note: l10n.agentChoiceBuiltinNote,
            tiles: builtIn,
          ),
          const SizedBox(height: 16),
          // Custom creates a configuration, so it sits with the saved ones.
          _Section(
            key: const Key('agent-choice-mine'),
            title: saved.isEmpty
                ? l10n.agentChoiceCustomTitle
                : l10n.agentChoiceSavedTitle,
            note: saved.isEmpty
                ? l10n.agentChoiceCustomNote
                : l10n.agentChoiceSavedNote,
            tiles: mine,
          ),
        ],
      ),
    );
  }
}

/// A heading (its note behind an info mark) and the tiles in a [Wrap].
class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.title,
    required this.note,
    required this.tiles,
  });

  final String title;
  final String note;
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InfoTitle(
          title: Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          info: note,
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 10, runSpacing: 10, children: tiles),
      ],
    );
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({
    required this.choice,
    required this.selected,
    required this.title,
    required this.source,
    required this.icon,
    required this.onTap,
  });

  final AgentChoice choice;
  final bool selected;
  final String title;

  /// Where the agent comes from: the tile's tooltip and part of its label.
  final String source;
  final Widget icon;
  final ValueChanged<AgentChoice>? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Tooltip(
      message: source,
      waitDuration: const Duration(milliseconds: 600),
      // The node below already carries the title and source.
      excludeFromSemantics: true,
      // One node with the full label, the selection state and the action;
      // the InkWell beneath keeps keyboard focus and Enter/Space.
      child: Semantics(
        container: true,
        button: true,
        selected: selected,
        enabled: enabled,
        label: '$title, $source',
        onTap: enabled ? () => onTap!(choice) : null,
        excludeSemantics: true,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: AnimatedContainer(
            duration: Motion.of(context, Motion.fast),
            curve: Motion.emphasized,
            decoration: BoxDecoration(
              // A calm plate at rest; the chosen one is lifted and ringed.
              color: selected ? raisedCardColor(scheme) : fieldFill(scheme),
              borderRadius: BorderRadius.circular(kControlRadius),
              border: Border.all(
                color: selected
                    ? scheme.onSurface.withValues(alpha: 0.75)
                    : Colors.transparent,
                width: 1.5,
              ),
              boxShadow: selected ? raisedCardShadows(scheme) : null,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: Key('agent-choice-$choice'),
                mouseCursor: enabled ? clickable : SystemMouseCursors.basic,
                borderRadius: BorderRadius.circular(kControlRadius),
                onTap: enabled ? () => onTap!(choice) : null,
                child: SizedBox(
                  // Grows with the text size; the section's width caps it.
                  width: MediaQuery.textScalerOf(context).scale(124),
                  child: _body(scheme),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The agent's mark (with a check when chosen) over its name.
  Widget _body(ColorScheme scheme) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            icon,
            const Spacer(),
            if (selected)
              Icon(AppIcons.check_circle, size: 16, color: scheme.onSurface),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}
