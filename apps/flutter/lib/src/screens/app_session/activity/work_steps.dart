part of '../activity_cards.dart';

/// The whole of a turn's work behind one line: "已处理 2m 31s ›".
///
/// Deliberately quieter than [GroupedActivityCard] — no border, no fill, just a
/// muted label and a chevron above a hairline. Collapsed is the resting state, so
/// this row appears in every turn and a bordered card per turn would out-shout
/// the answers it sits above.
///
/// Expanding reveals [TurnWork.groups], each of which is itself expandable, so
/// the reader descends only as far as they need: turn, then tool run, then the
/// individual call's output.
class TurnWorkCard extends StatefulWidget {
  /// Creates the fold for one turn's work.
  const TurnWorkCard({
    super.key,
    required this.work,
    this.active = false,
    this.turnRunning = false,
  });

  /// Whether this is the current segment of the running turn.
  final bool active;

  /// Whether a turn runs in this conversation now.
  final bool turnRunning;

  /// The activity to fold away.
  final TurnWork work;

  @override
  State<TurnWorkCard> createState() => _TurnWorkCardState();
}

class _TurnWorkCardState extends State<TurnWorkCard> {
  /// Whether the user has taken control of this fold, and in which direction.
  /// Null means "follow the turn" — open while it runs, shut once it settles.
  bool? _userExpanded;

  /// While a turn runs, only its current segment opens by itself: a step
  /// that streams on in an earlier one (a server the agent left running in
  /// the background) would hold it open for the rest of the turn, and a lazy
  /// transcript would reopen it after every scroll.
  bool get _expanded =>
      _userExpanded ??
      (widget.work.streaming && (widget.active || !widget.turnRunning));

  final _headerKey = GlobalKey();

  /// Fold from the bottom control: shut, then bring the header back into view
  /// so the reader lands where the fold now is, not in the reply below it.
  void _collapseFromBottom() {
    setState(() => _userExpanded = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final header = _headerKey.currentContext;
      if (header == null || !header.mounted) return;
      _revealInTranscript(header, alignment: 0.2);
    });
  }

  /// The turn's duration, or null where the server did not report one.
  String? _duration(AppLocalizations l10n) {
    final ms = widget.work.durationMs;
    if (ms == null) return null;
    return formatElapsed((ms / 1000).round());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final duration = _duration(l10n);
    // Missing timing is common for interrupted/imported turns. It is not
    // evidence that historical work is still running.
    final label = switch (duration) {
      _ when widget.active => l10n.turnProcessing(widget.work.items.length),
      final d? => l10n.turnProcessed(d),
      _ => l10n.turnActivityCount(widget.work.items.length),
    };
    final running = widget.active && widget.work.streaming;
    final touch = !isDesktop;
    final reviews = widget.work.reviews;
    void toggle() => setState(() => _userExpanded = !_expanded);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The fold header: a small pill with an icon, so "the agent did work
        // here" is a recognisable object rather than a grey caption. It turns
        // the accent while the turn runs.
        Padding(
          key: _headerKey,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Material(
            color: running
                ? softWash(scheme)
                : scheme.surfaceContainer.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(kControlRadius),
            child: InkWell(
              key: const Key('turn-work-toggle'),
              mouseCursor: clickable,
              borderRadius: BorderRadius.circular(kControlRadius),
              onTap: toggle,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: touch ? 9 : 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (running)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: signalColor(scheme),
                        ),
                      )
                    else
                      Icon(
                        AppIcons.construction_rounded,
                        size: 14,
                        color: muted,
                      ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: running
                              ? signalColor(scheme)
                              : scheme.onSurface,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (reviews.total > 0) ...[
                      const SizedBox(width: 8),
                      // Reviews made on the user's behalf are visible from
                      // the closed fold; a refusal turns the mark red.
                      Tooltip(
                        message: l10n.reviewResult,
                        child: Row(
                          key: const Key('turn-work-reviews'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              reviews.refused > 0
                                  ? AppIcons.gpp_bad_outlined
                                  : AppIcons.verified_user_outlined,
                              size: 13,
                              color: reviews.refused > 0 ? scheme.error : muted,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${reviews.total}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: reviews.refused > 0
                                        ? scheme.error
                                        : muted,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _expanded ? 0.25 : 0,
                      duration: Motion.of(context, Motion.fast),
                      curve: Motion.move,
                      child: Icon(
                        AppIcons.keyboard_arrow_right_rounded,
                        size: 16,
                        color: muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        _workExpansion(
          animate:
              widget.work.items.length <= 40 &&
              !MediaQuery.disableAnimationsOf(context),
          child: !_expanded
              ? const SizedBox(width: double.infinity)
              : Padding(
                  // The step cards themselves group the run; a leading rule
                  // beside them added a line that meant nothing.
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (widget.work.items.length > 40)
                        _WorkSteps(
                          items: widget.work.items,
                          active: widget.active,
                        )
                      else
                        for (final row in widget.work.groups)
                          if (row is ActivityGroup)
                            GroupedActivityCard(
                              key: ValueKey('wg:${row.items.first.id}'),
                              group: row,
                            )
                          else
                            activityRow(row as TranscriptItem),
                      // Fold from the bottom too: after reading a long run
                      // the header is a screen or more away, and on a phone
                      // reaching it means a long swipe back up.
                      if (widget.work.items.length > 3)
                        _CollapseRow(
                          key: const Key('turn-work-collapse'),
                          label: l10n.showLess,
                          touch: touch,
                          onTap: _collapseFromBottom,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

Widget _workExpansion({required bool animate, required Widget child}) => animate
    ? AnimatedSize(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: child,
      )
    : child;

/// Long work stays in a bounded viewport; changing pages never loads history.
class _WorkSteps extends StatefulWidget {
  const _WorkSteps({required this.items, this.active = false});
  final List<TranscriptItem> items;
  final bool active;
  @override
  State<_WorkSteps> createState() => _WorkStepsState();
}

class _WorkStepsState extends State<_WorkSteps> {
  static const _pageSize = 25;

  /// How far the newest step may sit below the screen's edge and still count
  /// as being watched: about one collapsed step row.
  static const _followSlack = 48.0;

  late int _start = widget.active ? _tailStart : 0;

  /// The reader picked a range (a page, a step number), which new steps must
  /// not move. Only "Latest steps" — or paging onto the latest page — clears it.
  bool _pinned = false;

  /// Whether the bottom of the step list is on screen. Scrolling up to read
  /// older steps pauses following without pinning: coming back resumes it.
  bool _tailInView = true;

  ScrollPosition? _position;
  final _pagerKey = GlobalKey();
  final _listKey = GlobalKey();

  int get _tailStart => math.max(0, widget.items.length - _pageSize);

  @override
  void initState() {
    super.initState();
    // Opened by hand above the fold's end, the tail starts out of view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _trackTail();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    if (identical(position, _position)) return;
    _position?.removeListener(_trackTail);
    _position = position?..addListener(_trackTail);
  }

  @override
  void dispose() {
    _position?.removeListener(_trackTail);
    super.dispose();
  }

  void _trackTail() {
    final list = _listKey.currentContext;
    final below = list == null ? null : _belowViewport(list);
    if (below != null) _tailInView = below <= _followSlack;
  }

  @override
  void didUpdateWidget(_WorkSteps old) {
    super.didUpdateWidget(old);
    // Only a running turn is followed; the update that ends it still counts,
    // so its final steps reach a reader who was watching. A history refresh
    // of a settled turn leaves the page alone.
    final running = widget.active || old.active;
    if (!running || _pinned || !_tailInView || _start == _tailStart) return;
    _start = _tailStart;
    // The page now ends on the newest step; keep it on screen, not just in
    // the page range. The transcript's own follow has already run by then.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final list = _listKey.currentContext;
      if (mounted && list != null) _revealBottomInTranscript(list);
    });
  }

  void _go(int start) {
    setState(() {
      _start = start.clamp(0, math.max(0, widget.items.length - 1)).toInt();
      _pinned = _start != _tailStart;
    });
    // A new page starts at its first step: bring the pager back into view
    // rather than leaving the reader at the old page's tail.
    final pager = _pagerKey.currentContext;
    if (pager != null) _revealInTranscript(pager);
  }

  /// Resume following: show the latest page and land on its newest step.
  void _latest() {
    setState(() {
      _start = _tailStart;
      _pinned = false;
      // Steps that land while the reveal below animates follow too.
      _tailInView = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final list = _listKey.currentContext;
      if (mounted && list != null) {
        _revealBottomInTranscript(list, animate: true);
      }
    });
  }

  Future<void> _choose() async {
    final l10n = AppLocalizations.of(context);
    var input = '${_start + 1}';
    final picked = await showAppDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.jumpToStep),
        content: TextFormField(
          initialValue: input,
          onChanged: (value) => input = value,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: l10n.stepNumber,
            helperText: '1–${widget.items.length}',
          ),
          onFieldSubmitted: (value) =>
              Navigator.pop(context, int.tryParse(value)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, int.tryParse(input)),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    );
    if (mounted && picked != null) _go(picked - 1);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final start = _start.clamp(0, math.max(0, widget.items.length - 1)).toInt();
    final end = math.min(start + _pageSize, widget.items.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          key: _pagerKey,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 2,
          children: [
            TextButton(
              key: const Key('work-step-picker'),
              onPressed: _choose,
              child: Text(l10n.stepRange(start + 1, end, widget.items.length)),
            ),
            IconButton(
              tooltip: l10n.previousSteps,
              icon: const Icon(AppIcons.chevron_left),
              onPressed: start == 0
                  ? null
                  : () => _go(math.max(0, start - _pageSize)),
            ),
            IconButton(
              tooltip: l10n.nextSteps,
              icon: const Icon(AppIcons.chevron_right),
              onPressed: end == widget.items.length ? null : () => _go(end),
            ),
            TextButton(onPressed: _latest, child: Text(l10n.latestSteps)),
          ],
        ),
        // Laid out inline, not in a nested scroll viewport. A bounded inner
        // list captured the drag on touch, so a reader who swiped inside it
        // scrolled steps instead of the page and could reach neither the
        // fold above nor the reply below. A page is at most [_pageSize] rows,
        // so building them all is cheap.
        KeyedSubtree(key: _listKey, child: _stepList(context, start, end)),
      ],
    );
  }

  Widget _stepList(BuildContext context, int start, int end) => Column(
    key: const Key('work-step-list'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = start; i < end; i++)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 36,
              child: Padding(
                padding: const EdgeInsets.only(top: 13),
                child: Text(
                  '${i + 1}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
            Expanded(
              child: KeyedSubtree(
                key: ValueKey('work-step-${widget.items[i].id}'),
                child: activityRow(widget.items[i]),
              ),
            ),
          ],
        ),
    ],
  );
}

/// "Collapse" at the foot of an expanded fold.
class _CollapseRow extends StatelessWidget {
  const _CollapseRow({
    super.key,
    required this.label,
    required this.touch,
    required this.onTap,
  });

  final String label;
  final bool touch;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: TextButton.icon(
        onPressed: onTap,
        icon: const Icon(AppIcons.keyboard_arrow_up_rounded, size: 18),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          // A full touch target on phones, where this is the control that
          // matters; compact on desktop.
          minimumSize: Size(0, touch ? 44 : 30),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
