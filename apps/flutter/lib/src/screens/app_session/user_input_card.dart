/// The card for an `item/tool/requestUserInput` elicitation: the agent asks
/// the user structured questions (Codex `request_user_input`, OpenCode's
/// native `question` tool).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/app_icons.dart';

/// One question parsed from an elicitation.
class _UiQuestion {
  const _UiQuestion({
    required this.id,
    required this.header,
    required this.question,
    required this.isOther,
    required this.isSecret,
    required this.multiple,
    required this.options,
  });
  final String id;
  final String header;
  final String question;
  final bool isOther;
  final bool isSecret;
  final bool multiple;
  final List<({String label, String? description})> options;
}

/// Interactive card for an `item/tool/requestUserInput` elicitation: the model
/// is asking the user structured questions (NOT requesting permission to run a
/// command, so "完全放行" does not — and should not — suppress it). Each
/// question's options render as chips — one choice, or any number when the
/// question allows `multiple`; `isOther` adds a free-text field; `isSecret`
/// obscures it. Submitting sends each question's answers by question id, in
/// option order; cancel sends an empty answer set (the turn proceeds without
/// input, or OpenCode rejects the question).
class UserInputCard extends StatefulWidget {
  /// Creates the card for [prompt].
  const UserInputCard({
    super.key,
    required this.prompt,
    required this.onAnswer,
  });

  /// The elicitation event.
  final AppEvent prompt;

  /// Sends the answers; an empty map cancels.
  final Future<void> Function(AppEvent, Map<String, List<String>>) onAnswer;

  @override
  State<UserInputCard> createState() => _UserInputCardState();
}

class _UserInputCardState extends State<UserInputCard> {
  // Sentinel "choice" meaning the free-text 其他 field for a question.
  static const _other = '\u0000other';
  late final List<_UiQuestion> _questions = _parse(widget.prompt.raw);
  // qid -> chosen option labels (and/or [_other]).
  final Map<String, Set<String>> _choice = {};
  final Map<String, TextEditingController> _otherCtrls = {};
  bool _submitting = false;

  @override
  void dispose() {
    for (final c in _otherCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  static List<_UiQuestion> _parse(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final qs = (m['questions'] as List?) ?? const [];
      final out = <_UiQuestion>[];
      for (final q in qs) {
        if (q is! Map<String, dynamic>) continue;
        final id = q['id'] as String?;
        if (id == null || id.isEmpty) continue;
        final opts = <({String label, String? description})>[];
        for (final o in (q['options'] as List?) ?? const []) {
          if (o is! Map<String, dynamic>) continue;
          final label = o['label'] as String?;
          if (label == null || label.isEmpty) continue;
          opts.add((label: label, description: o['description'] as String?));
        }
        out.add(
          _UiQuestion(
            id: id,
            header: (q['header'] as String?) ?? '',
            question: (q['question'] as String?) ?? '',
            isOther: (q['isOther'] as bool?) ?? false,
            isSecret: (q['isSecret'] as bool?) ?? false,
            multiple: (q['multiple'] as bool?) ?? false,
            options: opts,
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  TextEditingController _ctrl(String qid) =>
      _otherCtrls.putIfAbsent(qid, TextEditingController.new);

  /// [q]'s answers in option order (free text last), or null when it has
  /// none yet.
  List<String>? _answers(_UiQuestion q) {
    String? typed() {
      final t = _ctrl(q.id).text.trim();
      return t.isEmpty ? null : t;
    }

    // No options → pure free-text.
    if (q.options.isEmpty) {
      final t = typed();
      return t == null ? null : [t];
    }
    final chosen = _choice[q.id] ?? const <String>{};
    final out = [
      for (final o in q.options)
        if (chosen.contains(o.label)) o.label,
      if (chosen.contains(_other)) ?typed(),
    ];
    // An "other" pick without text answers nothing yet.
    if (chosen.contains(_other) && typed() == null) return null;
    return out.isEmpty ? null : out;
  }

  bool get _complete =>
      _questions.isNotEmpty && _questions.every((q) => _answers(q) != null);

  void _toggle(_UiQuestion q, String value, bool selected) {
    setState(() {
      final set = _choice.putIfAbsent(q.id, () => <String>{});
      if (!q.multiple) set.clear();
      if (selected) {
        set.add(value);
      } else {
        set.remove(value);
      }
    });
  }

  Future<void> _submit() async {
    final answers = <String, List<String>>{};
    for (final q in _questions) {
      final a = _answers(q);
      if (a != null) answers[q.id] = a;
    }
    setState(() => _submitting = true);
    try {
      await widget.onAnswer(widget.prompt, answers);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _cancel() async {
    setState(() => _submitting = true);
    try {
      await widget.onAnswer(widget.prompt, const {});
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('user-input-card'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        border: Border.all(color: scheme.outlineVariant, width: 0.5),
        borderRadius: BorderRadius.circular(kPanelRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(AppIcons.help_outline, size: 18, color: scheme.primary),
                const SizedBox(width: 9),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      l10n.userInputTitle,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w500,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_questions.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  widget.prompt.raw,
                  style: const TextStyle(fontSize: 12),
                ),
              )
            else
              for (final q in _questions) _questionBlock(context, q, scheme),
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  key: const Key('user-input-cancel'),
                  onPressed: _submitting ? null : _cancel,
                  child: Text(l10n.cancel),
                ),
                FilledButton(
                  key: const Key('user-input-submit'),
                  onPressed: (_complete && !_submitting) ? _submit : null,
                  child: Text(l10n.userInputSubmit),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _questionBlock(
    BuildContext context,
    _UiQuestion q,
    ColorScheme scheme,
  ) {
    final l10n = AppLocalizations.of(context);
    final chosen = _choice[q.id] ?? const <String>{};
    Widget chip(String value, String label, String? tooltip) {
      final selected = chosen.contains(value);
      final onSelected = _submitting
          ? null
          : (bool on) => _toggle(q, value, on);
      return q.multiple
          ? FilterChip(
              key: Key('user-input-${q.id}-$label'),
              label: Text(label),
              tooltip: tooltip,
              selected: selected,
              onSelected: onSelected,
            )
          : ChoiceChip(
              key: Key('user-input-${q.id}-$label'),
              label: Text(label),
              tooltip: tooltip,
              selected: selected,
              onSelected: onSelected,
            );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(
        container: true,
        label: q.header.isEmpty ? null : q.header,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (q.header.isNotEmpty)
              Text(
                q.header,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (q.question.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(q.question, style: const TextStyle(fontSize: 13.5)),
              ),
            if (q.multiple && q.options.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  l10n.userInputChooseAny,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 6),
            // A question with no options is a pure free-text prompt; otherwise
            // show the option chips (+ an "其他" chip when free text is also
            // allowed).
            if (q.options.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final o in q.options)
                    chip(
                      o.label,
                      o.label,
                      (o.description != null && o.description!.isNotEmpty)
                          ? o.description
                          : null,
                    ),
                  if (q.isOther) chip(_other, l10n.userInputOther, null),
                ],
              ),
            if (q.options.isEmpty || (q.isOther && chosen.contains(_other)))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: TextField(
                  key: Key('user-input-${q.id}-text'),
                  controller: _ctrl(q.id),
                  obscureText: q.isSecret,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: q.header.isEmpty ? null : q.header,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
