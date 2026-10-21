/// Choosing one value of an ACP select option: a menu for a handful of
/// values, a searchable grouped list for long catalogs (an agent may expose
/// every model of every provider it knows).
///
/// Value ids are opaque — OpenCode's model ids are `provider/model` and a
/// model id may itself contain `/` — so nothing here parses them; search
/// matches the label, the group and the raw id as plain text.
library;

import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';
import 'package:pocox/src/app_icons.dart';

/// At most this many values open as a plain menu; more open the searchable
/// list.
const kOptionMenuLimit = 8;

/// The full label of [value]: `Group · Name` when grouped.
String optionValueLabel(SessionConfigValue value) =>
    value.group == null ? value.name : '${value.group} · ${value.name}';

/// The values of [values] matching [query] (case-insensitive substring of the
/// name, group or id), in agent order.
List<SessionConfigValue> filterOptionValues(
  List<SessionConfigValue> values,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return values;
  return [
    for (final value in values)
      if (value.name.toLowerCase().contains(q) ||
          (value.group?.toLowerCase().contains(q) ?? false) ||
          value.value.toLowerCase().contains(q))
        value,
  ];
}

/// Open the searchable list for [option]; resolves with the chosen value id,
/// or null when dismissed.
///
/// A bottom sheet on phones, a bounded dialog on wide windows. The search
/// field takes focus, so on a phone the software keyboard covers the lower
/// part of the screen: the sheet's list then shrinks to the space above it
/// (a dialog already moves out of the keyboard's way by itself).
Future<String?> showOptionPicker(
  BuildContext context,
  SessionConfigOption option,
) {
  final sheet = MediaQuery.sizeOf(context).width < kDesktopPanelWidth;
  return showAdaptivePanel<String>(
    context: context,
    anchored: true,
    scrollable: false,
    maxWidth: 520,
    builder: (_) => OptionPickerList(option: option, avoidKeyboard: sheet),
  );
}

/// The searchable, grouped value list of one option.
class OptionPickerList extends StatefulWidget {
  /// Creates the list for [option].
  const OptionPickerList({
    super.key,
    required this.option,
    this.avoidKeyboard = false,
  });

  /// The option being chosen.
  final SessionConfigOption option;

  /// Keep the list above the software keyboard (bottom sheets).
  final bool avoidKeyboard;

  @override
  State<OptionPickerList> createState() => _OptionPickerListState();
}

class _OptionPickerListState extends State<OptionPickerList> {
  final _query = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final option = widget.option;
    final shown = filterOptionValues(option.values, _query.text);
    // Group headers where the group changes; agents list grouped values
    // contiguously (ACP groups are nested arrays, flattened in order). Only
    // the row plan is built here; the list builds the visible widgets.
    final rows = <({String? header, SessionConfigValue? value})>[];
    String? group;
    for (final value in shown) {
      if (value.group != null && value.group != group) {
        rows.add((header: value.group, value: null));
      }
      group = value.group;
      rows.add((header: null, value: value));
    }
    final headerStyle = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant);
    Widget row(BuildContext context, int index) {
      final (:header, :value) = rows[index];
      if (value == null) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Text(header!, style: headerStyle),
        );
      }
      final selected = value.value == option.currentValue;
      return ListTile(
        key: Key('agent-option-value-${value.value}'),
        dense: true,
        selected: selected,
        title: Text(value.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: value.description == null
            ? null
            : Text(
                value.description!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: selected ? const Icon(AppIcons.check, size: 18) : null,
        onTap: () => Navigator.of(context).pop(value.value),
      );
    }

    final keyboard = widget.avoidKeyboard
        ? MediaQuery.viewInsetsOf(context).bottom
        : 0.0;
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            option.name,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            key: const Key('agent-option-search'),
            controller: _query,
            autofocus: true,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(AppIcons.search, size: 18),
              hintText: l10n.agentOptionSearch(option.name),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (shown.length == 1) {
                Navigator.of(context).pop(shown.single.value);
              }
            },
          ),
        ),
        const SizedBox(height: 8),
        Flexible(
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.agentOptionNoMatch,
                    key: const Key('agent-option-no-match'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : Scrollbar(
                  controller: _scroll,
                  child: ListView.builder(
                    key: const Key('agent-option-list'),
                    controller: _scroll,
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 12),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.manual,
                    itemCount: rows.length,
                    itemBuilder: row,
                  ),
                ),
        ),
      ],
    );
    if (keyboard == 0) return column;
    // The sheet's height was fixed against the whole screen and the keyboard
    // covers its lower part: lift the content above it and give the list
    // only the height that remains.
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxHeight;
        if (!available.isFinite) {
          return Padding(
            padding: EdgeInsets.only(bottom: keyboard),
            child: column,
          );
        }
        const minimum = 140.0;
        final lift = keyboard.clamp(
          0.0,
          (available - minimum).clamp(0.0, available),
        );
        return Padding(
          padding: EdgeInsets.only(bottom: lift),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: available - lift),
            child: column,
          ),
        );
      },
    );
  }
}
