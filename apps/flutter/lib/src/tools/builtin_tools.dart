/// POCOX's built-in tools in the composer: the user picks some for a
/// message, the message names them for the agent (a `<pocox_tools>` block at
/// its end), and a gated one is allowed for that conversation without a
/// consent prompt. The host's catalog says which tools it offers, so a newer
/// host's tools appear here by its own title.
library;

import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/widgets/adaptive_sheet.dart';

export 'package:pocket_codex/src/tools/builtin_tags.dart';
export 'package:pocket_codex/src/tools/tools_providers.dart'
    show toolsOverviewProvider;

/// The built-in tools the host of agent service [serviceKey] offers its
/// conversations: none while its tools are off or its catalog has not
/// answered (an older POCOX).
List<ToolsBuiltinTool> hostBuiltinTools(
  ToolsOverview overview,
  String serviceKey,
) {
  final device = parseServiceKey(serviceKey).device;
  for (final d in overview.devices) {
    if (d.name == device) {
      return d.toolsEnabled == true ? d.builtinTools : const [];
    }
  }
  return const [];
}

/// A built-in tool's name: this app's words for the tools it knows, the
/// host's title for one it does not.
String builtinToolTitle(AppLocalizations l10n, String id, {String? fallback}) =>
    switch (id) {
      'services' => l10n.builtinToolServices,
      'share' => l10n.builtinToolShare,
      'connect' => l10n.builtinToolConnect,
      _ => fallback ?? id,
    };

String _summary(AppLocalizations l10n, ToolsBuiltinTool tool) =>
    switch (tool.id) {
      'services' => l10n.builtinToolServicesSummary,
      'share' => l10n.builtinToolShareSummary,
      'connect' => l10n.builtinToolConnectSummary,
      _ => tool.summary,
    };

/// A built-in tool's mark.
IconData builtinToolIcon(String id) => switch (id) {
  'services' => AppIcons.devices_outlined,
  'share' => AppIcons.share_port,
  'connect' => AppIcons.plug,
  _ => AppIcons.extension,
};

/// Offer the built-in [tools] of the conversation's host for the next
/// message, [picked] checked; every toggle reaches [onChanged] at once, and
/// the panel stays open for more.
Future<void> showBuiltinToolsPanel({
  required BuildContext context,
  required List<ToolsBuiltinTool> tools,
  required List<String> picked,
  required ValueChanged<List<String>> onChanged,
  Rect? anchor,
}) {
  final l10n = AppLocalizations.of(context);
  var current = List.of(picked);
  return showAdaptivePanel<void>(
    context: context,
    anchored: true,
    anchorRect: anchor,
    maxWidth: 320,
    insetTop: false,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) {
        final theme = Theme.of(c);
        return Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            key: const Key('builtin-tools-panel'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: Text(
                  l10n.builtinTools,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final tool in tools)
                Tooltip(
                  message: _summary(l10n, tool),
                  child: ChoiceRow<String>(
                    value: tool.id,
                    label: builtinToolTitle(
                      l10n,
                      tool.id,
                      fallback: tool.title,
                    ),
                    checked: current.contains(tool.id),
                    onTap: () {
                      // Kept in the host's order, whatever the order of taps.
                      final next = {...current};
                      if (!next.remove(tool.id)) next.add(tool.id);
                      current = [
                        for (final t in tools)
                          if (next.contains(t.id)) t.id,
                      ];
                      setState(() {});
                      onChanged(current);
                    },
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}

/// The built-in tools of a message: picked ones above the composer's field
/// (removable), or the ones a sent message named.
class BuiltinToolChips extends StatelessWidget {
  /// Creates chips for [ids].
  const BuiltinToolChips({
    super.key,
    required this.ids,
    this.titles = const {},
    this.onRemove,
  });

  /// The tools, in order.
  final List<String> ids;

  /// Hosts' titles for tools this app does not know.
  final Map<String, String> titles;

  /// Removes a picked tool; null for a sent message.
  final ValueChanged<String>? onRemove;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final id in ids)
          Container(
            key: ValueKey('builtin-tool-chip-$id'),
            padding: EdgeInsetsDirectional.fromSTEB(
              10,
              5,
              onRemove == null ? 10 : 4,
              5,
            ),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  builtinToolIcon(id),
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  builtinToolTitle(l10n, id, fallback: titles[id]),
                  style: style,
                ),
                if (onRemove case final remove?) ...[
                  const SizedBox(width: 2),
                  SizedBox.square(
                    dimension: 22,
                    child: IconButton(
                      key: ValueKey('builtin-tool-remove-$id'),
                      padding: EdgeInsets.zero,
                      iconSize: 14,
                      tooltip: l10n.builtinToolRemove(
                        builtinToolTitle(l10n, id, fallback: titles[id]),
                      ),
                      onPressed: () => remove(id),
                      icon: Icon(
                        AppIcons.close,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
