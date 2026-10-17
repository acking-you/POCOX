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
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/widgets/adaptive_sheet.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/screens/app_session/option_picker.dart';
import 'package:pocket_codex/src/text_measure.dart';
import 'package:pocket_codex/src/app_icons.dart';

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
class AgentSessionOptions extends StatefulWidget {
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
    this.wrap = false,
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

  /// Whether segments that cannot share one line readably may take a
  /// second line (where the composer gives them a line of their own).
  final bool wrap;

  /// A segment's icon, chevron and padding (10 + 15 + 4 + 15 + 10): the
  /// narrowest a segment gets.
  static const double _segmentChrome = 54;

  /// The least of a label a shared line must still show: two glyphs and
  /// the ellipsis.
  static const double _minLabelGlimpse = 24;

  /// The widest a non-model segment grows: room for a whole mode name such
  /// as "Bypass permissions" on a desktop composer, a phone's share of the
  /// line on touch.
  static double get _optionCap => isDesktop ? 200 : 160;

  /// The widest a segment of [category] grows: the model gets the most.
  static double _capOf(String? category) =>
      category == 'model' ? 220 : _optionCap;

  /// The capsule's own edge and inner padding.
  static const double _capsuleChrome = 2;

  /// Each segment's label and widest width, in display order.
  static List<({String label, double cap})> _segments(
    SessionSettings? settings,
    String modeTitle,
  ) => [
    if (settings != null)
      for (final option in orderedOptions(settings.configOptions))
        (label: option.currentLabel, cap: _capOf(option.category)),
    if (settings != null && showsLegacyModes(settings))
      (
        label:
            settings.modes
                .where((m) => m.id == settings.currentMode)
                .firstOrNull
                ?.name ??
            modeTitle,
        cap: _optionCap,
      ),
  ];

  static double _naturalWidth(BuildContext context, String label, double cap) =>
      math.min(
        cap,
        _segmentChrome +
            measureTextLine(
              context,
              label,
              _optionLabelStyle,
            ).width.ceilToDouble(),
      );

  /// The width the capsule takes with every label of [settings] whole (each
  /// within its segment's widest width); 0 when it has no segments. Lets the
  /// composer give the capsule its own line where the toolbar cannot.
  static double preferredWidth(
    BuildContext context,
    SessionSettings? settings,
  ) {
    final segments = _segments(
      settings,
      AppLocalizations.of(context).agentMode,
    );
    if (segments.isEmpty) return 0;
    return _capsuleChrome +
        segments.length -
        1 +
        segments.fold(
          0.0,
          (sum, s) => sum + _naturalWidth(context, s.label, s.cap),
        );
  }

  @override
  State<AgentSessionOptions> createState() => _AgentSessionOptionsState();

  /// [segmentKey] keeps each segment's state (an open menu or list, a
  /// change in flight) while the segments move between lines.
  Widget _build(
    BuildContext context,
    double room,
    GlobalKey Function(Object id) segmentKey,
  ) {
    final l10n = AppLocalizations.of(context);
    final settings = this.settings;
    final segments = _segments(settings, l10n.agentMode);
    final natural = [
      for (final s in segments) _naturalWidth(context, s.label, s.cap),
    ];
    // The segments of one capsule line: whole labels where they fit, shared
    // room where they do not, or each bounded by the room (and scrolling)
    // when not even their icons and chevrons fit.
    List<double> line(List<double> natural) {
      // The capsule's own edge, inner padding and dividers come out first.
      final inner = room.isFinite
          ? math.max(room - _capsuleChrome - (natural.length - 1), 0.0)
          : room;
      return _shares(natural, inner) ??
          [
            for (final w in natural)
              inner.isFinite ? math.min(w, math.max(inner, _segmentChrome)) : w,
          ];
    }

    var widths = line(natural);
    // Sharing that cuts a label to under half (long labels or large text on
    // a phone) gives the first segment, the model, a line of its own and
    // the rest the line below, where the composer allows it.
    final wrapped =
        wrap &&
        segments.length > 1 &&
        [
          for (var i = 0; i < natural.length; i++)
            widths[i] - _segmentChrome < (natural[i] - _segmentChrome) / 2,
        ].any((cut) => cut);
    if (wrapped) {
      final first = _naturalWidth(
        context,
        segments.first.label,
        double.infinity,
      );
      widths = [
        math.max(math.min(first, room - _capsuleChrome), _segmentChrome),
        ...line(natural.sublist(1)),
      ];
    }
    var index = 0;
    double fit(double _) => widths[index++];

    final chips = <Widget>[
      if (settings != null)
        for (final option in orderedOptions(settings.configOptions))
          KeyedSubtree(
            key: segmentKey(option.id),
            child: _OptionChip(
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
                'model' => AppIcons.auto_awesome,
                'thought_level' => AppIcons.psychology_outlined,
                'mode' => AppIcons.swap_horiz,
                _ => AppIcons.tune,
              },
              maxWidth: fit(_capOf(option.category)),
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
          ),
      if (settings != null && showsLegacyModes(settings))
        KeyedSubtree(
          key: segmentKey(_legacyModeSegment),
          child: _OptionChip(
            key: const Key('agent-mode'),
            title: l10n.agentMode,
            label:
                settings.modes
                    .where((m) => m.id == settings.currentMode)
                    .firstOrNull
                    ?.name ??
                l10n.agentMode,
            icon: AppIcons.swap_horiz,
            maxWidth: fit(_optionCap),
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
        ),
    ];
    if (chips.isEmpty) return _stateSegment(context, l10n, room);
    // Loose quiet chips, the way an assistant's composer offers its model and
    // mode: no frame of their own, each one filling in on hover or while its
    // menu is open.
    const divider = SizedBox(width: 2);
    Widget capsule(List<Widget> chips, {Key? key}) => ConstrainedBox(
      constraints: BoxConstraints(maxWidth: room),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: SingleChildScrollView(
          key: key,
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
    );
    return Semantics(
      container: true,
      label: l10n.agentOptions,
      child: wrapped
          ? Column(
              key: const Key('agent-session-options'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                capsule([chips.first]),
                const SizedBox(height: 6),
                capsule(chips.sublist(1)),
              ],
            )
          : capsule(chips, key: const Key('agent-session-options')),
    );
  }

  /// Each segment's width, from its [natural] one, when the labels do not
  /// all fit in [inner] but every segment's minimum does: the narrow ones
  /// keep their natural width and the rest share what is left equally. Null when no sharing is
  /// needed (everything fits) or possible (the segments must scroll).
  static List<double>? _shares(List<double> natural, double inner) {
    if (natural.isEmpty || !inner.isFinite) return null;
    final total = natural.fold(0.0, (sum, w) => sum + w);
    // Sharing must leave every label a readable glimpse; a line that can
    // only give each segment its icon and chevron scrolls whole labels
    // instead of showing three ellipses.
    if (total <= inner ||
        inner < natural.length * (_segmentChrome + _minLabelGlimpse)) {
      return null;
    }
    final order = List.generate(natural.length, (i) => i)
      ..sort((a, b) => natural[a].compareTo(natural[b]));
    final shares = List<double>.filled(natural.length, 0);
    var left = inner;
    for (var k = 0; k < order.length; k++) {
      final i = order[k];
      final share = (left / (order.length - k)).floorToDouble();
      shares[i] = math.min(natural[i], share);
      left -= shares[i];
    }
    return shares;
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
              Icon(AppIcons.refresh_rounded, size: 15, color: scheme.error)
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

/// Identifies the legacy mode segment among option ids, which are strings.
const Object _legacyModeSegment = Object();

class _AgentSessionOptionsState extends State<AgentSessionOptions> {
  final _segmentKeys = <Object, GlobalKey>{};

  // Where every segment's label fits, each takes its own width. Otherwise
  // the room is shared so the short labels stay whole and the long ones
  // ellipsize their start; only when not even each segment's icon and
  // chevron fit do the segments scroll horizontally, each bounded by the
  // room so a revealed segment is always entirely visible.
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => widget._build(
      context,
      constraints.maxWidth,
      (id) => _segmentKeys.putIfAbsent(id, GlobalKey.new),
    ),
  );
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
    return showChoicePanel<String>(
      context: context,
      title: widget.title,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      current: entries.where((entry) => entry.selected).lastOrNull?.id,
      maxWidth: 340,
      choices: [for (final entry in entries) (entry.id, entry.label)],
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
                style: _optionLabelStyle.copyWith(
                  color: usable || _pending
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            Icon(
              AppIcons.expand_more,
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
          mouseCursor: clickable,
          borderRadius: BorderRadius.circular(999),
          onTap: usable ? _activate : null,
          child: face,
        ),
      ),
    );
  }
}

/// The type of an option chip's label; measured and drawn alike.
const TextStyle _optionLabelStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w500,
);

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
