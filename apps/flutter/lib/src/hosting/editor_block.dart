import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/hosting/host_names.dart';
import 'package:pocox/src/text_measure.dart';
import 'package:pocox/src/widgets/app_dialog.dart';
import 'package:pocox/src/widgets/field_help.dart';

/// One padded block inside a hosting editor [GroupCard] section, inset like
/// the card's own header.
class EditorBlock extends StatelessWidget {
  /// Creates a block around [child].
  const EditorBlock({super.key, required this.child});

  /// The block's content.
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(18, 14, 18, 16), child: child);
}

/// A line of state under the control it belongs to: what was detected, a
/// change waiting to be applied, a problem. Explanations of what a control
/// is for belong in its [InfoTip] or [FocusHelp], not here.
class EditorNote extends StatelessWidget {
  /// Creates a note.
  const EditorNote(this.text, {super.key, this.color, this.action});

  /// The note.
  final String text;

  /// Its colour; muted by default.
  final Color? color;

  /// What to do about it (a reload), at the end of the line.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final style = helpTextStyle(Theme.of(context));
    final note = Text(
      text,
      style: color == null ? style : style.copyWith(color: color),
    );
    if (action case final action?) {
      return Row(
        children: [
          Expanded(child: note),
          action,
        ],
      );
    }
    return note;
  }
}

/// Ask before an editor's [action] (a restart, leaving with edits); true
/// only when the user chose it. [cancel] names the way back (Cancel by
/// default).
Future<bool> confirmEditorAction(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  String? cancel,
  Key? dialogKey,
  Key? cancelKey,
  Key? confirmKey,
}) async {
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: dialogKey,
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          key: cancelKey,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancel ?? AppLocalizations.of(context).cancel),
        ),
        FilledButton(
          key: confirmKey,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

/// An editor page's action bar, under its form: the actions side by side at
/// the end while they fit; otherwise (a narrow phone, large text, a long
/// translation) stacked at the end, each label free to wrap, rather than
/// overflowing the bar.
class EditorActionBar extends StatelessWidget {
  /// Creates the bar of [children].
  const EditorActionBar({super.key, required this.children});

  /// The actions, the primary one last.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: OverflowBar(
          alignment: MainAxisAlignment.end,
          spacing: 8,
          overflowAlignment: OverflowBarAlignment.end,
          overflowSpacing: 8,
          children: children,
        ),
      ),
    ),
  );
}

/// Whether a [SegmentedButton] of [labels] fits side by side in [width],
/// each label on one line beside the selected segment's check mark. The
/// [disabled] labels are never selected: no check mark, only the 12 px
/// segment padding on either side.
bool segmentsFitAcross(
  BuildContext context,
  double width,
  List<String> labels, {
  List<String> disabled = const [],
}) {
  final style = Theme.of(context).textTheme.labelLarge;
  double text(String label) => measureTextLine(context, label, style).width;
  // Any selectable segment may be the selected one, with Material's 18 px
  // check mark, its icon padding (12 + 16) and gap (8).
  final segment = [
    for (final label in labels) 12 + 16 + 18 + 8 + text(label),
    for (final label in disabled) 24 + text(label),
  ].fold<double>(0, math.max);
  // The segments plus the outer and dividing borders.
  final count = labels.length + disabled.length;
  return count * segment + count + 1 <= width;
}

/// A new host's instance name, unique on this device: a name another host
/// already uses ([taken], by canonical identity) is marked on the field,
/// which then shows no help. A running host's [fixed] name is shown, not
/// editable.
class HostNameField extends StatelessWidget {
  /// Creates the field; [fieldKey] keys its [TextField].
  const HostNameField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.onChanged,
    this.enabled = true,
    this.fixed = false,
    this.taken = const {},
  });

  /// The text field's key.
  final Key fieldKey;

  /// The name.
  final TextEditingController controller;

  /// Called on every edit.
  final ValueChanged<String> onChanged;

  /// Whether the name can be edited.
  final bool enabled;

  /// A running host's name.
  final bool fixed;

  /// Names this device's other hosts use.
  final Set<String> taken;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final clash = fixed ? null : hostNameClash(controller.text, taken);
    return FocusHelp(
      help: fixed || clash != null ? null : l10n.hostNameHelper,
      child: TextField(
        key: fieldKey,
        controller: controller,
        enabled: enabled && !fixed,
        decoration: InputDecoration(
          labelText: l10n.localHostName,
          errorText: clash == null ? null : l10n.hostNameInUse(clash),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

/// A running host's provider [badge] beside its state: a dot and [label] in
/// the state's [color].
class HostStateLine extends StatelessWidget {
  /// Creates the line; [labelKey] keys the label.
  const HostStateLine({
    super.key,
    required this.badge,
    required this.label,
    required this.color,
    this.labelKey,
  });

  /// The host's provider badge.
  final Widget badge;

  /// The state in words.
  final String label;

  /// The state's colour.
  final Color color;

  /// The label's key.
  final Key? labelKey;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      badge,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.circle, size: 10, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              key: labelKey,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    ],
  );
}

/// One fact of a running host: [label] with its [value] at the line's end.
class DetailRow extends StatelessWidget {
  /// Creates the row.
  const DetailRow(this.label, this.value, {super.key});

  /// What the value is.
  final String label;

  /// The value.
  final String value;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(value, style: style, textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}
