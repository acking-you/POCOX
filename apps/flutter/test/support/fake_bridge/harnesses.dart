part of '../../fake_bridge_api.dart';

/// One recorded harness call: `check`, `update` or `settings`, on the device
/// [key] names (null for this device).
typedef HarnessCall = ({String op, String? key, Object? arg});

/// Scripted harness management. Devices live in [harnessOverviews], keyed by
/// management key (`''` for this device); an absent key is an older host
/// without harness management. An update starts a running job, which
/// [finishHarnessUpdate] ends as the host would.
mixin _FakeHarnesses on _FakeBridgeState {
  /// Each device's harnesses.
  final Map<String, HarnessOverview> harnessOverviews = {};

  /// Every call, in order.
  final List<HarnessCall> harnessCalls = [];

  /// Thrown by the next [harnessUpdate] (then cleared), after recording it.
  Object? harnessUpdateError;

  HarnessOverview _harnesses(String? key) =>
      harnessOverviews[key ?? ''] ??
      (throw Exception('host_error (404): no harness management'));

  @override
  Future<HarnessOverview?> harnessOverview(String? serviceKey) async =>
      harnessOverviews[serviceKey ?? ''];

  @override
  Future<HarnessOverview> harnessCheck(String? serviceKey) async {
    harnessCalls.add((op: 'check', key: serviceKey, arg: null));
    final current = _harnesses(serviceKey);
    return harnessOverviews[serviceKey ?? ''] = HarnessOverview(
      harnesses: current.harnesses,
      checkedAtMs: DateTime.now().millisecondsSinceEpoch,
      restartServices: current.restartServices,
      job: current.job,
    );
  }

  @override
  Future<HarnessOverview> harnessUpdate(String? serviceKey, String kind) async {
    harnessCalls.add((op: 'update', key: serviceKey, arg: kind));
    if (harnessUpdateError case final error?) {
      harnessUpdateError = null;
      throw error;
    }
    final current = _harnesses(serviceKey);
    final from = current.harnesses
        .where((h) => h.kind == kind)
        .firstOrNull
        ?.version;
    return harnessOverviews[serviceKey ?? ''] = HarnessOverview(
      harnesses: current.harnesses,
      checkedAtMs: current.checkedAtMs,
      restartServices: current.restartServices,
      job: HarnessJob(
        run: (current.job?.run ?? 0) + 1,
        kind: kind,
        state: 'running',
        stage: 'updating',
        fromVersion: from,
      ),
    );
  }

  @override
  Future<HarnessOverview> harnessSettings(
    String? serviceKey, {
    String? kind,
    bool? autoUpdate,
    bool? restartServices,
  }) async {
    harnessCalls.add((
      op: 'settings',
      key: serviceKey,
      arg: (kind: kind, autoUpdate: autoUpdate, restart: restartServices),
    ));
    final current = _harnesses(serviceKey);
    return harnessOverviews[serviceKey ?? ''] = HarnessOverview(
      harnesses: [
        for (final h in current.harnesses)
          h.kind == kind && autoUpdate != null
              ? _withVersion(h, h.version, autoUpdate: autoUpdate)
              : h,
      ],
      checkedAtMs: current.checkedAtMs,
      restartServices: restartServices ?? current.restartServices,
      job: current.job,
    );
  }

  /// End [key]'s running update as its host would: the harness now reports
  /// [toVersion], and the job lists what was restarted.
  void finishHarnessUpdate(
    String? key, {
    String? toVersion,
    List<String> restarted = const [],
    List<HarnessSkip> notRestarted = const [],
    String? failure,
  }) {
    final current = _harnesses(key);
    final job = current.job!;
    final installed = failure == null ? toVersion : job.fromVersion;
    harnessOverviews[key ?? ''] = HarnessOverview(
      harnesses: [
        for (final h in current.harnesses)
          h.kind == job.kind ? _withVersion(h, installed) : h,
      ],
      checkedAtMs: current.checkedAtMs,
      restartServices: current.restartServices,
      job: HarnessJob(
        run: job.run,
        kind: job.kind,
        state: failure == null ? 'done' : 'failed',
        fromVersion: job.fromVersion,
        toVersion: installed,
        failure: failure,
        restarted: restarted,
        notRestarted: notRestarted,
        startedAtMs: job.startedAtMs,
        finishedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  static HarnessInfo _withVersion(
    HarnessInfo h,
    String? version, {
    bool? autoUpdate,
  }) => HarnessInfo(
    kind: h.kind,
    installed: h.installed,
    version: version,
    latest: h.latest,
    updateAvailable: h.latest != null && version != h.latest,
    method: h.method,
    canUpdate: h.canUpdate,
    problem: h.problem,
    autoUpdate: autoUpdate ?? h.autoUpdate,
    services: h.services,
  );
}
