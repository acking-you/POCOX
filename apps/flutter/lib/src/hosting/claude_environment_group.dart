import 'package:flutter/material.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/app_icons.dart';

/// An inset panel in the hosting editor: the ground shared by the Claude
/// environment groups and the adapter preparation card.
BoxDecoration claudePanelDecoration(ColorScheme scheme) => BoxDecoration(
  color: scheme.surfaceContainerLow,
  borderRadius: BorderRadius.circular(kControlRadius),
  border: Border.all(color: scheme.outlineVariant),
);

/// A small rounded count or state, in ink or in [color].
class ClaudeEnvironmentPill extends StatelessWidget {
  /// Creates a pill reading [text].
  const ClaudeEnvironmentPill(this.text, {super.key, this.color});

  /// What it says.
  final String text;

  /// A state colour (caution); ink when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = scheme.brightness == Brightness.light;
    final tone = color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: tone == null
            ? scheme.surfaceContainerHighest
            : tone.withValues(alpha: light ? 0.12 : 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          height: 1.3,
          color: tone == null
              ? scheme.onSurface
              : Color.lerp(tone, scheme.onSurface, 0.3),
        ),
      ),
    );
  }
}

/// One collapsible group of variables. The header is a single button that
/// says what is inside without opening it ([summary]: all inherited, or
/// which values this host overrides), with [attention] for a value still
/// missing. Opening resizes in place, instantly with reduced motion.
class ClaudeEnvironmentGroup extends StatelessWidget {
  /// Creates the group.
  const ClaudeEnvironmentGroup({
    super.key,
    required this.id,
    required this.icon,
    required this.title,
    required this.summary,
    required this.expanded,
    required this.onToggle,
    required this.children,
    this.count = 0,
    this.attention,
  });

  /// The group id, used in the header key.
  final String id;

  /// The group's glyph.
  final IconData icon;

  /// The group's name.
  final String title;

  /// One line on its contents.
  final String summary;

  /// Overrides in it, shown as a pill when any.
  final int count;

  /// A caution line (a value is missing), or null.
  final String? attention;

  /// Whether it is open.
  final bool expanded;

  /// Opens or closes it.
  final VoidCallback onToggle;

  /// The rows.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final caution = cautionColor(scheme);
    final header = Semantics(
      container: true,
      button: true,
      expanded: expanded,
      child: InkWell(
        key: Key('claude-env-group-$id'),
        mouseCursor: clickable,
        onTap: onToggle,
        borderRadius: BorderRadius.circular(kControlRadius),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 10, 12),
          child: Row(
            children: [
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: count > 0
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    if (attention case final text?) ...[
                      const SizedBox(height: 2),
                      Text(
                        text,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: caution,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 8),
                ExcludeSemantics(child: ClaudeEnvironmentPill('$count')),
              ],
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: Motion.of(context, Motion.fast),
                curve: Motion.move,
                child: Icon(
                  AppIcons.expand_more,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return DecoratedBox(
      key: Key('claude-env-panel-$id'),
      decoration: claudePanelDecoration(scheme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          Motion.resize(
            context,
            alignment: AlignmentDirectional.topStart,
            child: expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Divider(height: 1, color: scheme.outlineVariant),
                      Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          14,
                          10,
                          10,
                          12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final (i, row) in children.indexed) ...[
                              if (i > 0) const SizedBox(height: 12),
                              row,
                            ],
                          ],
                        ),
                      ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
