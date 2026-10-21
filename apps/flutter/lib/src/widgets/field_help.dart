import 'package:flutter/material.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/theme.dart';

/// Help for the field it wraps, shown beneath it only while focus is inside:
/// a form at rest shows names and values, and the instructions for a field
/// appear when someone is filling it in.
///
/// For text that must stay visible (a stored key, a validation problem) use
/// the field's own label, `errorText` or a status line instead.
class FocusHelp extends StatefulWidget {
  /// Wraps [child] with [help]; a null or empty [help] adds nothing.
  const FocusHelp({super.key, required this.help, required this.child});

  /// What to enter, and what it is used for.
  final String? help;

  /// The field (or a row holding it).
  final Widget child;

  @override
  State<FocusHelp> createState() => _FocusHelpState();
}

class _FocusHelpState extends State<FocusHelp> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final help = widget.help;
    if (help == null || help.isEmpty) return widget.child;
    final theme = Theme.of(context);
    // Aligned with the field's text, as Material's own helper text is.
    final inset =
        theme.inputDecorationTheme.contentPadding
            ?.resolve(Directionality.of(context))
            .left ??
        12;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused != _focused) setState(() => _focused = focused);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          widget.child,
          Motion.resize(
            context,
            duration: Motion.fast,
            curve: Motion.emphasized,
            alignment: AlignmentDirectional.topStart,
            child: _focused
                ? Padding(
                    padding: EdgeInsetsDirectional.fromSTEB(inset, 7, inset, 0),
                    child: Text(
                      help,
                      key: const Key('focus-help'),
                      style: helpTextStyle(theme),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// The style of help and notes that explain a control: readable secondary
/// text, never a caption.
TextStyle helpTextStyle(ThemeData theme) => TextStyle(
  fontSize: 12.5,
  height: 1.45,
  color: theme.colorScheme.onSurfaceVariant,
);

/// A quiet mark beside a title or label that holds its explanation. Hovered
/// or focused on desktop, tapped on touch, it shows [message]; the
/// explanation takes no room in the layout.
class InfoTip extends StatefulWidget {
  /// Creates the mark for [message].
  const InfoTip(this.message, {super.key});

  /// The explanation.
  final String message;

  @override
  State<InfoTip> createState() => _InfoTipState();
}

class _InfoTipState extends State<InfoTip> {
  final _tooltip = GlobalKey<TooltipState>();
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lit = _hover || _focused;
    return Tooltip(
      key: _tooltip,
      message: widget.message,
      triggerMode: TooltipTriggerMode.tap,
      showDuration: const Duration(seconds: 8),
      waitDuration: const Duration(milliseconds: 250),
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      textStyle: TextStyle(
        fontSize: 12.5,
        height: 1.5,
        color: scheme.onInverseSurface,
      ),
      child: Focus(
        onFocusChange: (focused) {
          setState(() => _focused = focused);
          if (focused) _tooltip.currentState?.ensureTooltipVisible();
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.help,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Padding(
            // A comfortable target around a small glyph.
            padding: const EdgeInsets.all(4),
            child: Icon(
              AppIcons.info_outline,
              size: 15,
              color: lit ? scheme.onSurfaceVariant : onSurfaceMuted(scheme),
            ),
          ),
        ),
      ),
    );
  }
}

/// [title] with an optional [InfoTip] after it, the mark centred on the
/// title's first line.
class InfoTitle extends StatelessWidget {
  /// Creates the row.
  const InfoTitle({super.key, required this.title, this.info});

  /// The title text, styled by the caller.
  final Widget title;

  /// Its explanation, if it needs one.
  final String? info;

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    if (info == null || info.isEmpty) return title;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: title),
        const SizedBox(width: 2),
        InfoTip(info),
      ],
    );
  }
}
