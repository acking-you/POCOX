import 'package:flutter/material.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/text_measure.dart';
import 'package:pocox/src/widgets/field_help.dart';
import 'package:pocox/src/widgets/icon_badge.dart';

/// One setting of a settings group: its mark and name (an explanation behind
/// an info mark), a state line only while there is state (pending, failed),
/// and its control at the end, or under it when [stackWhenNarrow] and the row
/// is too narrow for both.
class SettingRow extends StatelessWidget {
  /// Creates the row for [control].
  const SettingRow({
    super.key,
    required this.icon,
    required this.title,
    required this.control,
    this.info,
    this.state,
    this.stateKey,
    this.failed = false,
    this.stackWhenNarrow = false,
    this.controlWidth,
  });

  /// The setting's mark.
  final IconData icon;

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

  static const double _badge = 32;
  static const double _badgeGap = 11;
  static const double _controlGap = 16;

  /// An info mark and its gap after the name (see [InfoTitle]).
  static const double _infoMark = 25;

  static const _titleStyle = TextStyle(fontWeight: FontWeight.w600);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = this.state;
    final lead = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconBadge(icon: icon, size: _badge),
        const SizedBox(width: _badgeGap),
        Expanded(
          child: Padding(
            // Centres a one-line title on the badge.
            padding: const EdgeInsets.only(top: 6),
            child: Column(
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
                            style: helpTextStyle(theme).copyWith(
                              color: failed ? theme.colorScheme.error : null,
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(13, 10, 13, 10),
      child: LayoutBuilder(
        builder: (context, box) {
          final control = controlWidth;
          final beside = control == null
              ? 0.0
              : _badge +
                    _badgeGap +
                    measureTextLine(context, title, _titleStyle).width +
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
    required this.icon,
    required this.message,
    required this.retryLabel,
    required this.onRetry,
    this.retryKey,
  });

  /// The group's mark.
  final IconData icon;

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
      padding: const EdgeInsets.fromLTRB(13, 8, 8, 8),
      child: Row(
        children: [
          IconBadge(icon: icon),
          const SizedBox(width: 11),
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
