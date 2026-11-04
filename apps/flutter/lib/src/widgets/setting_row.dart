import 'package:flutter/material.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/text_measure.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/field_help.dart';

/// A settings row that leads somewhere: its label, its current value and a
/// chevron. A row with [onTap] null only states its value.
class SettingValueRow extends StatelessWidget {
  /// Creates the row.
  const SettingValueRow({
    super.key,
    required this.label,
    this.icon,
    this.value,
    this.info,
    this.onTap,
    this.chevron = true,
  });

  /// Its mark, in a group whose rows have them.
  final IconData? icon;

  /// Its name.
  final String label;

  /// What it does, behind an info mark.
  final String? info;

  /// What it is set to now.
  final Widget? value;

  /// Where it leads.
  final VoidCallback? onTap;

  /// Whether a tappable row shows a chevron.
  final bool chevron;

  /// The room a label needs beside its value before the value moves under it.
  static const double _sideBySide = 320;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = this.icon;
    final value = this.value;
    final name = InfoTitle(
      title: Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: isDesktop ? 14 : 15,
          color: onTap == null && chevron
              ? scheme.onSurfaceVariant
              : scheme.onSurface,
        ),
      ),
      info: info,
    );
    final shown = value == null
        ? null
        : DefaultTextStyle.merge(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            child: value,
          );
    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: isDesktop ? 52 : 50),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 12, 8),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final scale = MediaQuery.textScalerOf(context).scale(1);
                  if (shown == null) return name;
                  if (box.maxWidth < _sideBySide * scale / 1.5) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [name, const SizedBox(height: 2), shown],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: name),
                      const SizedBox(width: 12),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: box.maxWidth * 0.55,
                        ),
                        child: shown,
                      ),
                    ],
                  );
                },
              ),
            ),
            if (onTap != null && chevron) ...[
              const SizedBox(width: 6),
              Icon(
                AppIcons.chevron_right,
                size: 18,
                color: onSurfaceMuted(scheme),
              ),
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return content;
    return InkWell(mouseCursor: clickable, onTap: onTap, child: content);
  }
}

/// One setting of a settings group: its name (an explanation behind an info
/// mark), a state line only while there is state (pending, failed),
/// and its control at the end, or under it when [stackWhenNarrow] and the row
/// is too narrow for both.
class SettingRow extends StatelessWidget {
  /// Creates the row for [control].
  const SettingRow({
    super.key,
    required this.title,
    required this.control,
    this.info,
    this.state,
    this.stateKey,
    this.failed = false,
    this.stackWhenNarrow = false,
    this.controlWidth,
  });

  /// Its name.
  final String title;

  /// What it does, behind an info mark.
  final String? info;

  /// Pending or failed, never instructions.
  final String? state;

  /// The key of the state line.
  final Key? stateKey;

  /// [state] reports a failure.
  final bool failed;

  /// Put the control under the name when the row is narrow.
  final bool stackWhenNarrow;

  /// The control's natural width beside the name, when known: a row that
  /// cannot hold both whole stacks instead of squeezing the name.
  final double? controlWidth;

  /// The control; `true` asks it to fill the row's width.
  final Widget Function(bool expand) control;

  /// The narrowest row that holds a segmented control beside its title.
  static const double _sideBySide = 480;

  static const double _controlGap = 16;

  /// An info mark and its gap after the name (see [InfoTitle]).
  static const double _infoMark = 25;

  static const _titleStyle = TextStyle(fontWeight: FontWeight.w400);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = this.state;
    final lead = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InfoTitle(
          title: Text(title, style: _titleStyle),
          info: info,
        ),
        Motion.resize(
          context,
          duration: Motion.fast,
          curve: Motion.emphasized,
          alignment: AlignmentDirectional.topStart,
          child: state == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    state,
                    key: stateKey,
                    style: helpTextStyle(
                      theme,
                    ).copyWith(color: failed ? theme.colorScheme.error : null),
                  ),
                ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 13, 10),
      child: LayoutBuilder(
        builder: (context, box) {
          final control = controlWidth;
          final beside = control == null
              ? 0.0
              : measureTextLine(context, title, _titleStyle).width +
                    (info == null ? 0 : _infoMark) +
                    _controlGap +
                    control;
          if (stackWhenNarrow &&
              (box.maxWidth < _sideBySide || box.maxWidth < beside)) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [lead, const SizedBox(height: 12), this.control(true)],
            );
          }
          return Row(
            children: [
              Expanded(child: lead),
              const SizedBox(width: _controlGap),
              this.control(false),
            ],
          );
        },
      ),
    );
  }
}

/// A settings group whose saved values could not be read: [message], and a
/// retry.
class SettingReadFailed extends StatelessWidget {
  /// Creates the row; [retryKey] keys the retry.
  const SettingReadFailed({
    super.key,
    required this.message,
    required this.retryLabel,
    required this.onRetry,
    this.retryKey,
  });

  /// What could not be read.
  final String message;

  /// The retry's label.
  final String retryLabel;

  /// Read again.
  final VoidCallback onRetry;

  /// The key of the retry.
  final Key? retryKey;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(message, style: TextStyle(color: scheme.error)),
          ),
          TextButton(
            key: retryKey,
            onPressed: onRetry,
            child: Text(retryLabel),
          ),
        ],
      ),
    );
  }
}
