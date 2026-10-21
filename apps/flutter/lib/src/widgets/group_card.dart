import 'package:flutter/material.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/field_help.dart';

/// A titled card whose rows are separated by hairlines — the app's standard way
/// to group related settings or capabilities.
///
/// Settings, the services hub and the Codex wizard each grew their own copy of
/// this, which is how they came to disagree on header height and inset for what
/// reads as one component. [info] explains a group whose name may need it,
/// behind an info mark beside the title, so the explanation takes no room;
/// [hint] is a short visible line under the title for what the group *is*
/// right now (a computer's system and version), never for instructions;
/// [trailing] puts a count or status pill on the header row, or under the
/// title when the two do not fit on one line.
class GroupCard extends StatelessWidget {
  /// Creates a titled group of [children].
  const GroupCard({
    super.key,
    required this.title,
    required this.children,
    this.hint,
    this.info,
    this.trailing,
  });

  /// The group's name.
  final String title;

  /// A short summary under the title.
  final String? hint;

  /// What the group is for, behind an info mark beside the title.
  final String? info;

  /// Header-row trailing widget — a count pill, a status chip.
  final Widget? trailing;

  /// The rows, each preceded by a hairline so the header reads as their parent.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        InfoTitle(
          title: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: scheme.onSurfaceVariant,
            ),
          ),
          info: info,
        ),
        if (hint != null) ...[
          const SizedBox(height: 3),
          Text(hint!, style: helpTextStyle(Theme.of(context))),
        ],
      ],
    );
    // The heading sits above its plate, the rows inside it — a settings
    // group reads as a label and a stack of controls, not as a box whose
    // first row happens to be a title.
    final header = Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 12, 8),
      child: trailing == null
          ? Row(children: [Expanded(child: heading)])
          // The trailing pill sits at the end of the title's line while both
          // fit there; otherwise (large text, a long translation) it moves
          // under the title rather than squeezing it.
          : SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [heading, trailing!],
              ),
            ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (children.isNotEmpty)
            // A white pane raised off the grouped sheet; its rows are parted
            // by inset hairlines, the way a settings list reads.
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(kCardRadius),
                boxShadow: raisedCardShadows(scheme),
              ),
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 1,
                          thickness: 1,
                          indent: 16,
                          endIndent: 16,
                          color: scheme.outlineVariant,
                        ),
                      children[i],
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
