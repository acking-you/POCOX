part of '../../fake_bridge_api.dart';

mixin _FakeUpdates on _FakeBridgeState {
  final StreamController<UpdateState> _updates =
      StreamController<UpdateState>.broadcast();

  /// What the update engine reports; [setUpdate] changes it.
  UpdateState update = const UpdateState(
    current: '0.5.0',
    phase: 'up_to_date',
    method: 'replace_bundle',
    page: 'https://github.com/acking-you/POCOX/releases/tag/v0.5.0',
    latest: '0.5.0',
  );

  /// What [updateDownload] ends in (`ready` by default).
  UpdateState? downloadResult;

  /// What [updateInstall] ends in (`installing` by default).
  UpdateState? installResult;

  /// Every update call so far, in order.
  final List<String> updateCalls = [];

  /// Replaces the update state and tells the watchers.
  void setUpdate(UpdateState next) {
    update = next;
    _updates.add(next);
  }

  UpdateState _with(String phase) => UpdateState(
    current: update.current,
    phase: phase,
    method: update.method,
    page: update.page,
    latest: update.latest,
    newer: update.newer,
    size: update.size,
    received: update.size ?? 0,
    path: update.path,
    announced: update.announced,
  );

  @override
  UpdateState updateState() => update;

  @override
  Stream<UpdateState> updateWatch() async* {
    yield update;
    yield* _updates.stream;
  }

  @override
  void updateStartBackground() => updateCalls.add('background');

  @override
  Future<UpdateState> updateCheck({required bool force}) async {
    updateCalls.add('check:$force');
    return update;
  }

  @override
  Future<UpdateState> updateDownload() async {
    updateCalls.add('download');
    setUpdate(downloadResult ?? _with('ready'));
    return update;
  }

  @override
  void updateCancel() => updateCalls.add('cancel');

  @override
  Future<UpdateState> updateInstall() async {
    updateCalls.add('install');
    setUpdate(installResult ?? _with('installing'));
    return update;
  }

  @override
  void updateReport(String kind, String detail) =>
      updateCalls.add('report:$kind');

  @override
  void updateAnnounce(String version) {
    updateCalls.add('announce:$version');
    update = UpdateState(
      current: update.current,
      phase: update.phase,
      method: update.method,
      page: update.page,
      latest: update.latest,
      newer: update.newer,
      size: update.size,
      announced: version,
    );
  }
}
