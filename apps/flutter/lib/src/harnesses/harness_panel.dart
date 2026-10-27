import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/harnesses/harness_progress.dart';
import 'package:pocox/src/harnesses/harness_text.dart';
import 'package:pocox/src/hosting/editor_block.dart';
import 'package:pocox/src/managed/managed_host_editor.dart';
import 'package:pocox/src/managed/managed_providers.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/time_ago.dart';
import 'package:pocox/src/widgets/action_row.dart';
import 'package:pocox/src/widgets/field_help.dart';
import 'package:pocox/src/widgets/group_card.dart';
import 'package:pocox/src/widgets/status_dots.dart';

/// A device's harnesses by its management key; null is this device. Null
/// data means the other computer's POCOX has no harness management. Reads
/// only: a stale check it starts runs on that device and changes nothing.
final harnessOverviewProvider = FutureProvider.autoDispose
    .family<HarnessOverview?, String?>((ref, serviceKey) {
      ref.watch(configProvider);
      return ref.watch(bridgeApiProvider).harnessOverview(serviceKey);
    });

/// The agents a computer has installed: their versions, newer releases, and
/// updating them with each agent's own installer, after which its services
/// restart on the new version. The same card serves this computer
/// ([serviceKey] null, under its local hosting) and a managed one (its
/// `host:` key): each computer checks, updates and keeps its own settings.
///
/// An older POCOX without harness management shows nothing.
class HarnessPanel extends ConsumerStatefulWidget {
  /// Creates the card for the computer behind [serviceKey].
  const HarnessPanel({super.key, this.serviceKey});

  /// The computer's management key; null for this computer.
  final String? serviceKey;

  @override
  ConsumerState<HarnessPanel> createState() => _HarnessPanelState();
}

class _HarnessPanelState extends ConsumerState<HarnessPanel> {
  /// How often a computer that is checking or updating is read again.
  static const _poll = Duration(seconds: 1);

  Timer? _timer;

  /// The control whose request is in flight (`check`, `update:<kind>`,
  /// `auto:<kind>`, `restart`); one at a time.
  String? _pending;

  /// The last request's failure.
  String? _error;

  /// Moves whenever the card shows another computer: an answer for the one
  /// it was asked on never lands on another.
  int _generation = 0;

  @override
  void didUpdateWidget(HarnessPanel old) {
    super.didUpdateWidget(old);
    if (old.serviceKey != widget.serviceKey) {
      _generation++;
      _pending = null;
      _error = null;
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Read the computer again shortly, while it checks or updates.
  void _schedulePoll() {
    if (_timer != null) return;
    final key = widget.serviceKey;
    _timer = Timer(_poll, () {
      _timer = null;
      if (mounted && key == widget.serviceKey) {
        ref.invalidate(harnessOverviewProvider(key));
      }
    });
  }

  /// An update that finished restarted services: show them as they run now.
  void _onChange(HarnessOverview? before, HarnessOverview? after) {
    final was = before?.job;
    final now = after?.job;
    if (was == null || now == null || !was.running || now.running) return;
    if (was.run != now.run) return;
    if (widget.serviceKey case final key?) {
      ref.invalidate(managedDeviceProvider(key));
    } else {
      ref.invalidate(localServeListProvider);
    }
  }

  /// Send one request for the computer shown now. A lost answer is reported
  /// and the computer is read again; nothing is sent again by itself.
  Future<void> _run(
    String pending,
    Future<void> Function(BridgeApi api, String? key) request,
  ) async {
    if (_pending != null) return;
    final key = widget.serviceKey;
    final generation = _generation;
    final l10n = AppLocalizations.of(context);
    // The container outlives this card: the re-read still happens after the
    // page is left.
    final container = ProviderScope.containerOf(context, listen: false);
    final api = ref.read(bridgeApiProvider);
    setState(() {
      _pending = pending;
      _error = null;
    });
    String? error;
    try {
      await request(api, key);
    } catch (e) {
      error = harnessFailureText(l10n, e, local: key == null);
    }
    container.invalidate(harnessOverviewProvider(key));
    if (!mounted || generation != _generation) return;
    setState(() {
      _pending = null;
      _error = error;
    });
  }

  Future<void> _update(HarnessInfo harness, bool restart) async {
    final l10n = AppLocalizations.of(context);
    final key = widget.serviceKey;
    final names = harness.services.join(', ');
    final confirmed = await confirmManaged(
      context,
      l10n.harnessConfirmTitle(harnessName(harness.kind), harness.latest ?? ''),
      harness.services.isEmpty
          ? l10n.harnessConfirmPlain
          : restart
          ? l10n.harnessConfirmRestart(names)
          : l10n.harnessConfirmKeep(names),
      l10n.harnessUpdate,
    );
    // The computer moved while the confirmation was open: nothing is sent.
    if (!confirmed || !mounted || key != widget.serviceKey) return;
    await _run(
      'update:${harness.kind}',
      (api, key) => api.harnessUpdate(key, harness.kind),
    );
  }

  String? _checkedLine(AppLocalizations l10n, HarnessOverview overview) {
    if (overview.checking) return l10n.harnessChecking;
    final at = overview.checkedAtMs;
    if (at == null) return l10n.harnessNotChecked;
    return l10n.harnessCheckedAgo(
      relativeTime(at ~/ 1000, DateTime.now(), l10n),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final provider = harnessOverviewProvider(widget.serviceKey);
    ref.listen(provider, (before, after) {
      _onChange(before?.valueOrNull, after.valueOrNull);
    });
    final async = ref.watch(provider);
    final overview = async.valueOrNull;
    // An older POCOX has no harness management: nothing to show.
    if (overview == null && async.hasValue) return const SizedBox.shrink();
    if (overview?.busy ?? false) _schedulePoll();
    final job = overview?.job;
    final updating = job?.running ?? false;
    final children = <Widget>[];
    if (overview == null && async.hasError) {
      children.add(
        EditorBlock(
          child: EditorNote(
            harnessFailureText(
              l10n,
              async.error!,
              local: widget.serviceKey == null,
            ),
            key: const Key('harness-load-error'),
            color: scheme.error,
            action: TextButton(
              key: const Key('harness-retry'),
              onPressed: () => ref.invalidate(provider),
              child: Text(l10n.retry),
            ),
          ),
        ),
      );
    } else if (overview == null ||
        overview.harnesses.isEmpty && overview.checking) {
      // Nothing is listed before the computer's first check.
      children.add(const LinearProgressIndicator(minHeight: 2));
    }
    if (_error case final error?) {
      children.add(
        EditorBlock(
          child: EditorNote(
            error,
            key: const Key('harness-error'),
            color: scheme.error,
          ),
        ),
      );
    }
    if (overview != null) {
      for (final harness in overview.harnesses) {
        children.add(
          _HarnessRow(
            key: Key('harness-${harness.kind}'),
            harness: harness,
            job: job?.kind == harness.kind ? job : null,
            pending: _pending == 'update:${harness.kind}',
            canStart: _pending == null && !updating,
            canChange: _pending == null,
            onUpdate: () => _update(harness, overview.restartServices),
            onAutoUpdate: (value) => _run(
              'auto:${harness.kind}',
              (api, key) => api.harnessSettings(
                key,
                kind: harness.kind,
                autoUpdate: value,
              ),
            ),
          ),
        );
      }
      children.add(
        EditorBlock(
          child: SwitchListTile(
            key: const Key('harness-restart'),
            contentPadding: EdgeInsets.zero,
            secondary: _pending == 'restart'
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(AppIcons.restart_alt, color: scheme.primary),
            // What either choice does to running services, behind its mark.
            title: InfoTitle(
              title: Text(l10n.harnessRestartTitle),
              info: overview.restartServices
                  ? l10n.harnessRestartOn
                  : l10n.harnessRestartOff,
            ),
            value: overview.restartServices,
            onChanged: _pending != null
                ? null
                : (value) => _run(
                    'restart',
                    (api, key) =>
                        api.harnessSettings(key, restartServices: value),
                  ),
          ),
        ),
      );
    }
    final checking = (overview?.checking ?? false) || _pending == 'check';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GroupCard(
        key: Key('harnesses-${widget.serviceKey ?? 'local'}'),
        title: l10n.harnessesTitle,
        info: l10n.harnessesInfo,
        hint: overview == null ? null : _checkedLine(l10n, overview),
        trailing: IconButton(
          key: const Key('harness-check'),
          tooltip: l10n.harnessCheckNow,
          icon: checking
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(AppIcons.refresh, size: 20),
          onPressed: overview == null || checking || _pending != null
              ? null
              : () => _run('check', (api, key) => api.harnessCheck(key)),
        ),
        children: children,
      ),
    );
  }
}

class _HarnessRow extends StatelessWidget {
  const _HarnessRow({
    super.key,
    required this.harness,
    required this.job,
    required this.pending,
    required this.canStart,
    required this.canChange,
    required this.onUpdate,
    required this.onAutoUpdate,
  });

  final HarnessInfo harness;

  /// The computer's running or last update, when it is this harness's.
  final HarnessJob? job;

  /// This row's update request is in flight.
  final bool pending;

  /// No other request or update runs: an update may start.
  final bool canStart;

  /// No other request runs: a setting may change.
  final bool canChange;
  final VoidCallback onUpdate;
  final ValueChanged<bool> onAutoUpdate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final kind = harness.kind;
    final running = job?.running ?? false;
    final updating = running || pending;
    final latest = harness.latest;
    final lead = Row(
      children: [
        managedKindIcon(kind, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(harnessName(kind), style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                harnessVersionLine(l10n, harness, updating: updating),
                key: Key('harness-version-$kind'),
                style: muted,
              ),
            ],
          ),
        ),
      ],
    );
    final Widget header;
    if (updating) {
      // The progress under the name is the busy state: no button beside it,
      // only how long it has run.
      header = Row(
        children: [
          Expanded(child: lead),
          if (job case final job? when job.running) ...[
            const SizedBox(width: 12),
            HarnessElapsed(job: job),
          ],
        ],
      );
    } else if (harness.updateAvailable && harness.canUpdate && latest != null) {
      header = ActionRow(
        lead: lead,
        action: FilledButton(
          key: Key('harness-update-$kind'),
          onPressed: canStart ? onUpdate : null,
          child: Text(l10n.harnessUpdateTo(latest)),
        ),
      );
    } else if (harness.installed &&
        latest != null &&
        !harness.updateAvailable) {
      header = ActionRow(
        lead: lead,
        action: StatusChip(
          key: Key('harness-current-$kind'),
          color: successColor(scheme),
          label: l10n.harnessUpToDate,
          filled: true,
        ),
      );
    } else {
      header = lead;
    }
    final problem = harnessProblemText(l10n, harness);
    // The update's progress, then its outcome, in the same place.
    final Widget status = switch (job) {
      _ when updating => HarnessProgress(
        key: Key('harness-progress-$kind'),
        kind: kind,
        job: running ? job : null,
      ),
      final job? => switch (harnessOutcome(l10n, job)) {
        (final text, final failed) when text.isNotEmpty => Padding(
          key: Key('harness-result-$kind'),
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            text,
            style: muted?.copyWith(
              color: failed ? scheme.error : successColor(scheme),
            ),
          ),
        ),
        _ => const SizedBox(width: double.infinity),
      },
      null => const SizedBox(width: double.infinity),
    };
    return EditorBlock(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          // One move: what leaves folds away while what arrives unfolds.
          AnimatedSwitcher(
            duration: Motion.of(context, Motion.medium),
            switchInCurve: Motion.emphasized,
            switchOutCurve: Motion.move,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SizeTransition(
                sizeFactor: animation,
                alignment: AlignmentDirectional.topStart,
                child: child,
              ),
            ),
            layoutBuilder: (current, previous) => Stack(
              alignment: AlignmentDirectional.topStart,
              children: [...previous, ?current],
            ),
            child: status,
          ),
          if (harness.updateAvailable && !harness.canUpdate && latest != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(l10n.updateAvailable(latest), style: muted),
            ),
          if (problem != null)
            EditorNote(
              problem,
              key: Key('harness-problem-$kind'),
              color: harness.problem == 'bundled' ? null : cautionColor(scheme),
            ),
          if (harness.services.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                l10n.harnessUsedBy(harness.services.join(', ')),
                key: Key('harness-services-$kind'),
                style: muted,
              ),
            ),
          if (harness.installed && harness.canUpdate)
            SwitchListTile(
              key: Key('harness-auto-$kind'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.harnessAutoUpdate),
              value: harness.autoUpdate,
              onChanged: canChange ? onAutoUpdate : null,
            ),
        ],
      ),
    );
  }
}
