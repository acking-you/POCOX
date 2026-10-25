part of '../bridge_api_rust.dart';

mixin _RustHarnesses implements BridgeApi {
  static HarnessOverview _overview(frb.HarnessOverviewDto dto) =>
      HarnessOverview(
        harnesses: [
          for (final h in dto.harnesses)
            HarnessInfo(
              kind: h.kind,
              installed: h.installed,
              version: h.version,
              latest: h.latest,
              updateAvailable: h.updateAvailable,
              method: h.method,
              canUpdate: h.canUpdate,
              problem: h.problem,
              autoUpdate: h.autoUpdate,
              services: h.services,
            ),
        ],
        checkedAtMs: dto.checkedAtMs,
        checking: dto.checking,
        restartServices: dto.restartServices,
        job: switch (dto.job) {
          null => null,
          final job => HarnessJob(
            run: job.run,
            kind: job.kind,
            state: job.state,
            stage: job.stage,
            automatic: job.automatic,
            fromVersion: job.fromVersion,
            toVersion: job.toVersion,
            failure: job.failure,
            restarted: job.restarted,
            notRestarted: [
              for (final s in job.notRestarted)
                HarnessSkip(name: s.name, reason: s.reason),
            ],
            startedAtMs: job.startedAtMs,
            finishedAtMs: job.finishedAtMs,
          ),
        },
      );

  @override
  Future<HarnessOverview?> harnessOverview(String? serviceKey) async {
    final dto = await frb.harnessOverview(serviceKey: serviceKey);
    return dto == null ? null : _overview(dto);
  }

  @override
  Future<HarnessOverview> harnessCheck(String? serviceKey) async =>
      _overview(await frb.harnessCheck(serviceKey: serviceKey));

  @override
  Future<HarnessOverview> harnessUpdate(
    String? serviceKey,
    String kind,
  ) async => _overview(
    await frb.harnessUpdate(serviceKey: serviceKey, kindLabel: kind),
  );

  @override
  Future<HarnessOverview> harnessSettings(
    String? serviceKey, {
    String? kind,
    bool? autoUpdate,
    bool? restartServices,
  }) async => _overview(
    await frb.harnessSettings(
      serviceKey: serviceKey,
      kindLabel: kind,
      autoUpdate: autoUpdate,
      restartServices: restartServices,
    ),
  );
}
