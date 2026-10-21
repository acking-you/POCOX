/// The `/` command list above the composer, for an engine that lists its
/// native slash commands ([AppCapabilities.commands]).
///
/// Picking a command only writes `/name ` into the draft; the message is
/// sent as typed, and the host recognizes exact known command names. An
/// unlisted `/text` is ordinary text: nothing here guesses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/providers.dart';

/// The commands of the session service in a project (null: outside one),
/// read once per use. Each project is its own entry: a list read for a
/// project the view has left is never shown for another.
final agentCommandsProvider = FutureProvider.autoDispose
    .family<List<AgentCommand>, ({String service, String? project})>(
      (ref, key) => ref
          .read(bridgeApiProvider)
          .appCommandListForProject(key.service, key.project),
    );

/// The command name being typed in [text] (without `/`), or null when
/// [text] is not a bare `/name` prefix (a space or line break ends it).
String? commandQuery(String text) {
  if (!text.startsWith('/')) return null;
  final rest = text.substring(1);
  if (rest.contains(RegExp(r'\s'))) return null;
  return rest;
}

/// [commands] matching [query]: name prefixes first, then other name
/// matches, each in the engine's order.
List<AgentCommand> filterCommands(List<AgentCommand> commands, String query) {
  final q = query.toLowerCase();
  if (q.isEmpty) return commands;
  return [
    for (final c in commands)
      if (c.name.toLowerCase().startsWith(q)) c,
    for (final c in commands)
      if (!c.name.toLowerCase().startsWith(q) &&
          c.name.toLowerCase().contains(q))
        c,
  ];
}

/// The list. [highlighted] is the keyboard selection; taps select directly.
class CommandPalette extends StatelessWidget {
  /// Creates the list of [commands].
  const CommandPalette({
    super.key,
    required this.commands,
    required this.highlighted,
    required this.onSelect,
  });

  /// The matching commands, in display order.
  final List<AgentCommand> commands;

  /// Index of the keyboard selection.
  final int highlighted;

  /// Writes the command into the draft.
  final ValueChanged<AgentCommand> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: l10n.commandPaletteLabel(commands.length),
      child: Material(
        key: const Key('command-palette'),
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(kPanelRadius),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: commands.length,
            itemBuilder: (context, i) {
              final c = commands[i];
              final selected = i == highlighted;
              final source = switch (c.source) {
                'mcp' => l10n.commandSourceMcp,
                'skill' => l10n.commandSourceSkill,
                _ => null,
              };
              return Semantics(
                button: true,
                selected: selected,
                child: InkWell(
                  key: Key('command-${c.name}'),
                  onTap: () => onSelect(c),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 44),
                    color: selected
                        ? scheme.primaryContainer.withValues(alpha: 0.45)
                        : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Text(
                          '/${c.name}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (c.hints.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Text(
                            c.hints.join(' '),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            c.description ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (source != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            source,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
