import 'package:flutter/material.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';

import '../fonts.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// Edits an argument vector one argument per row.
///
/// Arguments are never joined, split or interpreted: what a row holds is
/// exactly one argument as the agent will receive it, including spaces,
/// quotes, `$VARS` and empty strings.
class ArgvEditor extends StatefulWidget {
  /// Creates the editor seeded with [initial].
  const ArgvEditor({
    super.key,
    required this.initial,
    required this.onChanged,
    this.enabled = true,
  });

  /// Arguments to start with.
  final List<String> initial;

  /// Called with the full vector after every edit.
  final ValueChanged<List<String>> onChanged;

  /// Whether rows can be edited.
  final bool enabled;

  @override
  State<ArgvEditor> createState() => _ArgvEditorState();
}

class _ArgvEditorState extends State<ArgvEditor> {
  final List<TextEditingController> _rows = [];

  @override
  void initState() {
    super.initState();
    _reset(widget.initial);
  }

  @override
  void didUpdateWidget(ArgvEditor old) {
    super.didUpdateWidget(old);
    // A different seed (another preset picked) replaces the rows.
    if (!identical(old.initial, widget.initial)) _reset(widget.initial);
  }

  void _reset(List<String> args) {
    for (final row in _rows) {
      row.dispose();
    }
    _rows
      ..clear()
      ..addAll(args.map((arg) => TextEditingController(text: arg)));
  }

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  void _emit() => widget.onChanged([for (final row in _rows) row.text]);

  void _add() {
    setState(() => _rows.add(TextEditingController()));
    _emit();
  }

  void _remove(int index) {
    setState(() => _rows.removeAt(index).dispose());
    _emit();
  }

  void _move(int from, int to) {
    setState(() => _rows.insert(to, _rows.removeAt(from)));
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final enabled = widget.enabled;
    return LayoutBuilder(
      builder: (context, constraints) => _rowsColumn(
        l10n,
        enabled,
        constraints.maxWidth >= 340,
        constraints.maxWidth,
      ),
    );
  }

  /// [reorder] adds move buttons; narrow phones keep only remove, so the
  /// field stays wide enough to read.
  Widget _rowsColumn(
    AppLocalizations l10n,
    bool enabled,
    bool reorder,
    double width,
  ) {
    final buttons = (reorder ? 3 : 1) * kMinInteractiveDimension;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // How arguments are passed is behind the label's info mark.
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: InfoTitle(
            title: Text(
              l10n.acpArguments,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            info: l10n.acpArgumentsHint,
          ),
        ),
        const SizedBox(height: 6),
        for (var i = 0; i < _rows.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _row(l10n, enabled, reorder, i, width, buttons),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const Key('acp-arg-add'),
            onPressed: enabled ? _add : null,
            icon: const Icon(AppIcons.add),
            label: Text(l10n.acpArgumentAdd),
          ),
        ),
      ],
    );
  }

  /// One argument. The row's buttons sit beside the field while its whole
  /// resting label still fits there; otherwise they go under a full-width
  /// field, so the label is never cut.
  Widget _row(
    AppLocalizations l10n,
    bool enabled,
    bool reorder,
    int i,
    double width,
    double buttons,
  ) {
    final label = l10n.acpArgumentLabel(i + 1);
    final field = TextField(
      key: Key('acp-arg-field-$i'),
      controller: _rows[i],
      enabled: enabled,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(
        fontFamily: monoFontFamily,
        fontFamilyFallback: monoCjkFallback,
      ),
      decoration: InputDecoration(isDense: true, labelText: label),
      onChanged: (_) => _emit(),
    );
    final actions = [
      if (reorder) ...[
        IconButton(
          key: Key('acp-arg-up-$i'),
          tooltip: l10n.acpArgumentMoveUp,
          icon: const Icon(AppIcons.arrow_upward),
          onPressed: enabled && i > 0 ? () => _move(i, i - 1) : null,
        ),
        IconButton(
          key: Key('acp-arg-down-$i'),
          tooltip: l10n.acpArgumentMoveDown,
          icon: const Icon(AppIcons.arrow_downward),
          onPressed: enabled && i < _rows.length - 1
              ? () => _move(i, i + 1)
              : null,
        ),
      ],
      IconButton(
        key: Key('acp-arg-remove-$i'),
        tooltip: l10n.acpArgumentRemove,
        icon: const Icon(AppIcons.close),
        onPressed: enabled ? () => _remove(i) : null,
      ),
    ];
    if (width - buttons >= _labelRoom(context, label)) {
      return Row(
        children: [
          Expanded(child: field),
          ...actions,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        field,
        Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
      ],
    );
  }
}

/// The field width [label] needs at rest: its text in the decorator's label
/// style at the current text scale, plus the theme's horizontal content
/// padding (Material's dense 12 px a side when the theme sets none) and 4 px
/// a side, so the label never meets the field's edge.
double _labelRoom(BuildContext context, String label) {
  final theme = Theme.of(context);
  final direction = Directionality.of(context);
  final style = theme.textTheme.bodyLarge?.merge(
    theme.inputDecorationTheme.labelStyle,
  );
  final painter = TextPainter(
    text: TextSpan(text: label, style: style),
    textDirection: direction,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  final padding =
      theme.inputDecorationTheme.contentPadding
          ?.resolve(direction)
          .horizontal ??
      24;
  return width + padding + 8;
}
