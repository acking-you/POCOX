/// An ACP agent's own per-session controls in the composer toolbar, drawn as
/// one capsule: a segment per select configuration option it reported
/// (model, effort, mode, …) plus the legacy mode when it reports no mode
/// option. Before the agent's session exists the capsule is a single state
/// segment instead — opening, or unavailable with a retry. An agent that
/// reports nothing gets nothing: there is no invented model catalog behind
/// the segments.
///
/// Options follow ACP's session config options: categories are UX hints that
/// order the segments (model, then thought level, then mode, then the rest);
/// ids and values are opaque and sent back verbatim. After every change the
/// agent returns its complete option set, which replaces this one — a model
/// change may add, drop or reset the effort option.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/screens/app_session/option_picker.dart';

/// [options] in display order: model, thought level, mode, then the others,
/// each group in agent order.
List<SessionConfigOption> orderedOptions(List<SessionConfigOption> options) {
  int rank(SessionConfigOption option) => switch (option.category) {
    'model' => 0,
    'thought_level' => 1,
    'mode' => 2,
    _ => 3,
  };
  final indexed = options.indexed.toList()
    ..sort((a, b) {
      final byRank = rank(a.$2).compareTo(rank(b.$2));
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
  return [for (final (_, option) in indexed) option];
}

/// [base] (a service's defaults for a new session) with a draft's
/// [choices] (option id -> value id) over them. A choice that is not one of
/// its option's values is ignored. Every value shown is what the session
/// gets once the choices are applied (see [draftChoiceAfter]): an option
/// without a choice shows the default it keeps.
///
/// Variants depend on the model. When the variant (`thought_level`) values
/// carry a `group`, it names the model value they belong to and only the
/// chosen model's variants are offered; without groups the variants are the
/// default model's, so they are withheld once another model is chosen
/// rather than offered for a model they may not belong to. Choosing a model
/// resets its variant (as the host does), so a chosen model's variant is
/// its default (the empty value, named [defaultName] when the agent did not
/// name one) until a variant is chosen.
SessionSettings draftSessionSettings(
  SessionSettings base,
  Map<String, String> choices, {
  String defaultName = 'Default',
}) {
  String? chosenIn(
    SessionConfigOption option,
    List<SessionConfigValue> values,
  ) {
    final chosen = choices[option.id];
    return chosen != null && values.any((v) => v.value == chosen)
        ? chosen
        : null;
  }

  final model = base.configOptions
      .where((o) => o.category == 'model')
      .firstOrNull;
  final modelValue = model == null
      ? null
      : chosenIn(model, model.values) ?? model.currentValue;
  final modelChanged = model != null && modelValue != model.currentValue;
  final options = <SessionConfigOption>[];
  for (final option in base.configOptions) {
    var values = option.values;
    var current = option.currentValue;
    if (option.category == 'thought_level' && model != null) {
      final grouped = values.any((v) => v.group != null);
      if (grouped) {
        values = [
          for (final v in values)
            if (v.group == modelValue)
              SessionConfigValue(
                value: v.value,
                name: v.name,
                description: v.description,
              ),
        ];
      } else if (modelChanged) {
        values = const [];
      }
      if (values.isEmpty) continue;
      if (modelChanged) {
        // The new model starts without a variant: that is what is shown
        // and, unless a variant is chosen, what the session gets.
        current = '';
        if (!values.any((v) => v.value == '')) {
          values = [
            SessionConfigValue(value: '', name: defaultName),
            ...values,
          ];
        }
      }
    }
    final chosen = chosenIn(option, values);
    if (chosen != null) {
      current = chosen;
    } else if (!values.any((v) => v.value == current) && values.isNotEmpty) {
      // A default the agent does not offer here cannot be shown truthfully
      // as any of these values; the empty value means "not chosen".
      current = '';
      if (!values.any((v) => v.value == '')) {
        values = [SessionConfigValue(value: '', name: defaultName), ...values];
      }
    }
    options.add(
      SessionConfigOption(
        id: option.id,
        name: option.name,
        category: option.category,
        description: option.description,
        currentValue: current,
        values: values,
      ),
    );
  }
  return SessionSettings(
    configOptions: options,
    currentMode: base.currentMode,
    modes: base.modes,
    usageUsed: base.usageUsed,
    usageSize: base.usageSize,
  );
}

/// A draft's [choices] after choosing [value] for option [id] of [base]: a
/// value equal to what the option shows without a choice is no choice, and
/// a model choice drops every variant choice (a model resets its variant).
Map<String, String> draftChoiceAfter(
  SessionSettings base,
  Map<String, String> choices,
  String id,
  String value,
) {
  final category = base.configOptions
      .where((o) => o.id == id)
      .firstOrNull
      ?.category;
  final next = {...choices}..remove(id);
  if (category == 'model') {
    final variants = {
      for (final o in base.configOptions)
        if (o.category == 'thought_level') o.id,
    };
    next.removeWhere((key, _) => variants.contains(key));
  }
  final unchosen = draftSessionSettings(
    base,
    next,
  ).configOptions.where((o) => o.id == id).firstOrNull?.currentValue;
  if (value != unchosen) next[id] = value;
  return next;
}

/// Whether the legacy `modes` should show: ACP clients that use config
/// options ignore them once a `mode` option exists.
bool showsLegacyModes(SessionSettings settings) =>
    settings.modes.isNotEmpty &&
    !settings.configOptions.any((o) => o.category == 'mode');

/// Where an ACP view's own agent session stands before its first message.
enum AgentSessionPhase {
  /// Nothing to report: an existing conversation, an agent without
  /// per-session options, or a view still waiting for its host.
  idle,

  /// No project is chosen, so no session can open yet.
  needsProject,

  /// The session is being opened.
  opening,

  /// The session is open; its options (if it reported any) are offered.
  ready,

  /// Opening failed; a retry is offered.
  failed,
}

/// The capsule; selecting a value calls back with the opaque ids verbatim.
class AgentSessionOptions extends StatelessWidget {
  /// Creates the controls from [settings].
  const AgentSessionOptions({
    super.key,
    required this.settings,
    required this.enabled,
    required this.onSelectConfig,
    required this.onSelectMode,
    this.phase = AgentSessionPhase.idle,
    this.agentName = '',
    this.onRetry,
  });

  /// The agent's current session state, or null before a session exists.
  final SessionSettings? settings;

  /// Whether the segments can be used right now.
  final bool enabled;

  /// Sets select option `configId` to `value`.
  final Future<void> Function(String configId, String value) onSelectConfig;

  /// Switches the legacy mode.
  final Future<void> Function(String modeId) onSelectMode;

  /// The session's state while it has no options to show.
  final AgentSessionPhase phase;

  /// The agent's display name, for the opening state.
  final String agentName;

  /// Opens the session again after [AgentSessionPhase.failed].
  final VoidCallback? onRetry;

  // The segments scroll horizontally inside the space the composer leaves;
  // each one is bounded by that space too, so a revealed segment is always
  // entirely visible and a long label ellipsizes inside it instead.
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _build(context, constraints.maxWidth),
  );

  Widget _build(BuildContext context, double room) {
    final l10n = AppLocalizations.of(context);
    final settings = this.settings;
    // The capsule's own edge and inner padding come out of the room first.
    final inner = room.isFinite ? math.max(room - 6, 0.0) : room;
    // Never below a segment's icon, chevron and padding (10 + 15 + 4 + 15 +
    // 10).
    double fit(double width) =>
        inner.isFinite ? math.min(width, math.max(inner, 54)) : width;
    final chips = <Widget>[
      if (settings != null)
        for (final option in orderedOptions(settings.configOptions))
          _OptionChip(
            key: Key('agent-config-${option.id}'),
            title: option.name,
            description: option.description,
            label: option.currentLabel,
            fullLabel:
                option.values
                    .where((v) => v.value == option.currentValue)
                    .map(optionValueLabel)
                    .firstOrNull ??
                option.currentValue,
            icon: switch (option.category) {
              'model' => Icons.auto_awesome,
              'thought_level' => Icons.psychology_outlined,
              'mode' => Icons.swap_horiz,
              _ => Icons.tune,
            },
            maxWidth: fit(option.category == 'model' ? 220 : 160),
            enabled: enabled,
            entries: [
              for (final value in option.values)
                (
                  id: value.value,
                  label: optionValueLabel(value),
                  selected: value.value == option.currentValue,
                ),
            ],
            onSearch: option.values.length > kOptionMenuLimit
                ? (context) => showOptionPicker(context, option)
                : null,
            onSelected: (value) => onSelectConfig(option.id, value),
          ),
      if (settings != null && showsLegacyModes(settings))
        _OptionChip(
          key: const Key('agent-mode'),
          title: l10n.agentMode,
          label:
              settings.modes
                  .where((m) => m.id == settings.currentMode)
                  .firstOrNull
                  ?.name ??
              l10n.agentMode,
          icon: Icons.swap_horiz,
          maxWidth: fit(160),
          enabled: enabled,
          entries: [
            for (final mode in settings.modes)
              (
                id: mode.id,
                label: mode.name,
                selected: mode.id == settings.currentMode,
              ),
          ],
          onSelected: onSelectMode,
        ),
    ];
    final scheme = Theme.of(context).colorScheme;
    if (chips.isEmpty) return _stateSegment(context, l10n, room);
    // One capsule, one hairline between neighbours: the options read as a
    // single control for "how the agent works", not a row of loose pills.
    final divider = Container(
      width: 1,
      height: 18,
      color: scheme.outlineVariant.withValues(alpha: 0.7),
    );
    return Semantics(
      container: true,
      label: l10n.agentOptions,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: room),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow.withValues(alpha: 0.6),
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: SingleChildScrollView(
                key: const Key('agent-session-options'),
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < chips.length; i++) ...[
                      if (i > 0) divider,
                      chips[i],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The single segment shown while the session has no options yet:
  /// opening (with progress), or unavailable (select to retry).
  Widget _stateSegment(
    BuildContext context,
    AppLocalizations l10n,
    double room,
  ) {
    final failed = phase == AgentSessionPhase.failed && onRetry != null;
    if (phase != AgentSessionPhase.opening && !failed) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final label = failed
        ? l10n.agentOptionsUnavailable
        : l10n.agentOpening(agentName.isEmpty ? l10n.agentOptions : agentName);
    final face = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: 40,
        maxWidth: room.isFinite ? math.max(room, 54) : 260,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: failed
              ? scheme.errorContainer.withValues(alpha: 0.45)
              : scheme.surfaceContainerLow.withValues(alpha: 0.6),
          border: Border.all(
            color: failed
                ? scheme.error.withValues(alpha: 0.4)
                : scheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (failed)
              Icon(Icons.refresh_rounded, size: 15, color: scheme.error)
            else
              SizedBox.square(
                dimension: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  // A determinate ring under reduced motion: the label
                  // still says what is happening.
                  value: Motion.ambientAllowed(context) ? null : 0.7,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: failed ? scheme.onErrorContainer : scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final tip = failed ? l10n.agentOptionsRetry : l10n.agentOpeningHint;
    return Semantics(
      container: true,
      button: failed,
      liveRegion: true,
      label: '$label. $tip',
      onTap: failed ? onRetry : null,
      excludeSemantics: true,
      child: Tooltip(
        message: tip,
        child: failed
            ? InkWell(
                key: const Key('agent-session-retry'),
                borderRadius: BorderRadius.circular(999),
                onTap: onRetry,
                child: face,
              )
            : KeyedSubtree(
                key: const Key('agent-session-opening'),
                child: face,
              ),
      ),
    );
  }
}

/// One option's trigger. Short lists open a menu; long ones the searchable
/// list ([onSearch]). While a change is in flight the chip shows progress
/// and ignores taps; the agent's answer (or the failure the screen reports)
/// settles it.
///
/// The selection callback and the offered values are captured when the menu
/// or list OPENS, not when it closes: a menu left open across a conversation,
/// host or catalog change answers to the target it was opened for (which the
/// screen then refuses as stale) and never to whatever the chip shows now.
class _OptionChip extends StatefulWidget {
  const _OptionChip({
    super.key,
    required this.title,
    required this.label,
    required this.icon,
    required this.maxWidth,
    required this.enabled,
    required this.entries,
    required this.onSelected,
    this.description,
    this.fullLabel,
    this.onSearch,
  });

  final String title;
  final String? description;
  final String label;
  final String? fullLabel;
  final IconData icon;
  final double maxWidth;
  final bool enabled;
  final List<({String id, String label, bool selected})> entries;
  final Future<String?> Function(BuildContext context)? onSearch;
  final Future<void> Function(String id) onSelected;

  @override
  State<_OptionChip> createState() => _OptionChipState();
}

class _OptionChipState extends State<_OptionChip> {
  bool _pending = false;
  bool _open = false;

  bool get _usable =>
      widget.enabled && !_pending && !_open && widget.entries.isNotEmpty;

  Future<void> _activate() async {
    if (!_usable) return;
    // Bound now: see the class doc.
    final select = widget.onSelected;
    final entries = widget.entries;
    final search = widget.onSearch;
    setState(() => _open = true);
    String? id;
    try {
      id = search != null ? await search(context) : await _showMenu(entries);
    } finally {
      if (mounted) setState(() => _open = false);
    }
    if (id == null || !mounted) return;
    final offered = entries.where((e) => e.id == id).firstOrNull;
    if (offered == null || offered.selected) return;
    setState(() => _pending = true);
    try {
      await select(id);
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  Future<String?> _showMenu(
    List<({String id, String label, bool selected})> entries,
  ) {
    final box = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(box.size.bottomLeft(Offset.zero), ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    return showMenu<String>(
      context: context,
      position: position,
      items: [
        for (final entry in entries)
          CheckedPopupMenuItem<String>(
            value: entry.id,
            checked: entry.selected,
            child: Text(entry.label, overflow: TextOverflow.ellipsis),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usable = _usable;
    final full = widget.fullLabel ?? widget.label;
    // Name and full value, so a truncated label is still readable (hover)
    // and announced completely.
    final tooltip = widget.description == null
        ? '${widget.title}: $full'
        : '${widget.title}: $full\n${widget.description}';
    final face = ConstrainedBox(
      constraints: BoxConstraints(minHeight: 40, maxWidth: widget.maxWidth),
      // A segment of the capsule: the capsule draws the edge, the segment
      // only its own press and pending states.
      child: AnimatedContainer(
        duration: Motion.of(context, Motion.fast),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: _pending || _open
              ? scheme.onSurface.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pending)
              const SizedBox.square(
                dimension: 13,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            else
              Icon(widget.icon, size: 15, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Flexible(
              child: TailEllipsisText(
                widget.label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: usable || _pending
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            Icon(
              widget.onSearch == null ? Icons.expand_more : Icons.search,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
    // One node: the full label, the button role and the action that opens
    // the menu or list. The InkWell beneath keeps focus and Enter/Space.
    return Semantics(
      container: true,
      button: true,
      enabled: usable,
      label: '${widget.title}: $full',
      onTap: usable ? _activate : null,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: usable ? _activate : null,
          child: face,
        ),
      ),
    );
  }
}

/// One line of [text] that, when too long, drops its START ("…tail"). Agent
/// labels tend to lead with what all values share (a provider) and end with
/// what tells them apart (the model), so the tail is the part worth keeping.
/// The text itself is not parsed or altered otherwise.
class TailEllipsisText extends StatelessWidget {
  /// Creates the text.
  const TailEllipsisText(this.text, {super.key, this.style});

  /// The full text.
  final String text;

  /// Its style.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(this.style);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        bool fits(String candidate) {
          final painter = TextPainter(
            text: TextSpan(text: candidate, style: style),
            maxLines: 1,
            textDirection: direction,
            textScaler: scaler,
          )..layout();
          final ok = painter.width <= constraints.maxWidth;
          painter.dispose();
          return ok;
        }

        var shown = text;
        if (constraints.maxWidth.isFinite && !fits(text)) {
          final chars = text.characters.toList();
          // Longest tail that fits after the ellipsis.
          var lo = 0, hi = chars.length;
          while (lo < hi) {
            final mid = (lo + hi + 1) ~/ 2;
            if (fits('…${chars.sublist(chars.length - mid).join()}')) {
              lo = mid;
            } else {
              hi = mid - 1;
            }
          }
          shown = '…${chars.sublist(chars.length - lo).join()}';
        }
        return Text(
          shown,
          maxLines: 1,
          overflow: TextOverflow.clip,
          softWrap: false,
          style: style,
        );
      },
    );
  }
}
