part of '../bridge_api_rust.dart';

mixin _RustUpdates implements BridgeApi {
  static UpdateState _updateState(frb.UpdateStateDto dto) => UpdateState(
    current: dto.current,
    phase: dto.phase,
    latest: dto.latest,
    newer: dto.newer,
    method: dto.method,
    size: dto.size,
    received: dto.received,
    page: dto.page,
    checkedAtMs: dto.checkedAtMs,
    failure: dto.failure,
    failureDetail: dto.failureDetail,
    path: dto.path,
    announced: dto.announced,
  );

  @override
  UpdateState updateState() => _updateState(frb.updateState());

  @override
  Stream<UpdateState> updateWatch() => frb.updateWatch().map(_updateState);

  @override
  void updateStartBackground() => frb.updateStartBackground();

  @override
  Future<UpdateState> updateCheck({required bool force}) async =>
      _updateState(await frb.updateCheck(force: force));

  @override
  Future<UpdateState> updateDownload() async =>
      _updateState(await frb.updateDownload());

  @override
  void updateCancel() => frb.updateCancel();

  @override
  Future<UpdateState> updateInstall() async =>
      _updateState(await frb.updateInstall());

  @override
  void updateReport(String kind, String detail) =>
      frb.updateReport(kind: kind, detail: detail);

  @override
  void updateAnnounce(String version) => frb.updateAnnounce(version: version);
}
