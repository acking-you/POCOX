part of '../../fake_bridge_api.dart';

/// One device's pairing identity, in memory. Stage screens seed [pairingState] and
/// [pairingGroup], and a test sets [pairingRefusal] to see a call refused.
mixin _FakePairing on _FakeBridgeState {
  /// `no_device`, `inactive`, `active`, `removed`, `superseded`, `unknown` or
  /// `pending`.
  String pairingState = 'no_device';

  /// Whether this identity is the active account here.
  bool pairingActiveHere = false;

  /// This device's group.
  List<PairingDevice> pairingGroup = const [];

  /// What the next call throws, once.
  PairingFailure? pairingRefusal;

  /// The login of a set-aside GitHub session.
  String? pairingParkedGithub;

  /// Whether linking through this device's code is paused.
  bool pairingPaused = false;

  /// Every mutation so far, in order.
  final List<String> pairingCalls = [];

  void _pairingRefuse() {
    final refusal = pairingRefusal;
    pairingRefusal = null;
    if (refusal != null) throw refusal;
  }

  PairingSession get _pairingSession => PairingSession(
    deviceId: 'device-self',
    accountId: 'user-self',
    label: 'This device',
    activated: pairingState == 'active',
  );

  PairingCode get _pairingCode => PairingCode(
    code: 'K7M2-F9QX-3RTB',
    uri: 'pocox://pair?c=K7M2F9QX3RTB',
    issuedAt: 0,
    nextRotationAt: 86400,
    paused: pairingPaused,
  );

  PairingOperation _pairingDone(String kind) {
    pairingCalls.add(kind);
    return PairingOperation(id: 'op-$kind', kind: kind, status: 'completed');
  }

  // Native storage belongs to the platform; the fake keeps everything in memory.
  @override
  Future<void> pairingInstallNativeStore({
    required String lockDir,
    required Future<NativeStoreAnswer> Function(String slot) read,
    required Future<String?> Function(String slot, String value) write,
  }) async {}

  @override
  Future<PairingStatus> pairingStatus({String? backend}) async {
    _pairingRefuse();
    return PairingStatus(
      state: pairingState,
      backend: backend ?? 'https://backend.example',
      activeHere: pairingActiveHere,
      session: pairingState == 'no_device' ? null : _pairingSession,
      parkedGithub: pairingParkedGithub,
    );
  }

  @override
  Future<PairingPrepared> pairingPrepare({
    String? label,
    String? backend,
  }) async {
    _pairingRefuse();
    if (pairingState == 'no_device') pairingState = 'inactive';
    return PairingPrepared(session: _pairingSession, code: _pairingCode);
  }

  @override
  Future<PairingSession> pairingActivate({
    NativeHardwareHint? hint,
    String? backend,
  }) async {
    _pairingRefuse();
    pairingCalls.add('activate');
    pairingState = 'active';
    pairingActiveHere = true;
    return _pairingSession;
  }

  @override
  Future<PairingCode> pairingCode({String? backend}) async {
    _pairingRefuse();
    return _pairingCode;
  }

  @override
  Future<PairingCode> pairingSetPaused({
    required bool paused,
    String? backend,
  }) async {
    _pairingRefuse();
    pairingPaused = paused;
    return _pairingCode;
  }

  @override
  Future<PairingCode> pairingRotate({String? backend}) async {
    _pairingRefuse();
    pairingCalls.add('rotate');
    return _pairingCode;
  }

  @override
  String? pairingParseInvitation(String uri) {
    const prefix = 'pocox://pair?c=';
    return uri.startsWith(prefix) ? uri.substring(prefix.length) : null;
  }

  @override
  Future<PairingPreview> pairingPreview(String code, {String? backend}) async {
    _pairingRefuse();
    return PairingPreview(
      ticket: 'ticket',
      expiresAt: 300,
      targetDeviceId: 'device-peer',
      alreadyMember: false,
      devices: const [
        PairingPreviewDevice(id: 'device-peer', name: 'Peer', lastActiveDay: 0),
      ],
    );
  }

  @override
  Future<PairingOperation> pairingLink({
    required String ticket,
    required bool leaveCurrent,
    NativeHardwareHint? hint,
    String? backend,
  }) async {
    _pairingRefuse();
    pairingState = 'active';
    pairingActiveHere = true;
    return _pairingDone('link');
  }

  @override
  Future<PairingOperation> pairingLeave({String? backend}) async {
    _pairingRefuse();
    return _pairingDone('leave');
  }

  @override
  Future<List<PairingOperation>> pairingSettle({String? backend}) async {
    _pairingRefuse();
    return const [];
  }

  @override
  Future<PairingDevices> pairingDevices({
    String? cursor,
    String? backend,
  }) async {
    _pairingRefuse();
    return PairingDevices(devices: pairingGroup, pendingRequests: const []);
  }

  @override
  Future<void> pairingRenameDevice({
    required String deviceId,
    required String name,
    String? backend,
  }) async {
    _pairingRefuse();
    pairingCalls.add('rename');
  }

  @override
  Future<PairingOperation> pairingRemoveDevice(
    String deviceId, {
    String? backend,
  }) async {
    _pairingRefuse();
    pairingGroup = [
      for (final device in pairingGroup)
        if (device.id != deviceId) device,
    ];
    return _pairingDone('remove');
  }

  @override
  Future<void> pairingDecideRestore({
    required String deviceId,
    required String requestId,
    required bool allow,
    String? backend,
  }) async {
    _pairingRefuse();
    pairingCalls.add(allow ? 'allow' : 'deny');
  }

  @override
  Future<PairingRestoreRequest> pairingRestoreRequest({
    NativeHardwareHint? hint,
    String? backend,
  }) async {
    _pairingRefuse();
    return const PairingRestoreRequest(
      requestId: 'request',
      status: 'pending',
      matchingId: '4827',
    );
  }

  @override
  Future<PairingRestoreRequest> pairingRestorePoll(
    String requestId, {
    String? backend,
  }) async {
    _pairingRefuse();
    return PairingRestoreRequest(requestId: requestId, status: 'pending');
  }

  @override
  Future<PairingOperation> pairingRestoreConfirm({
    String? ticket,
    String? targetDeviceId,
    String? requestId,
    bool retake = false,
    NativeHardwareHint? hint,
    String? backend,
  }) async {
    _pairingRefuse();
    pairingState = 'active';
    pairingActiveHere = true;
    return _pairingDone(retake ? 'retake' : 'restore');
  }

  @override
  Future<PairingPrepared> pairingStartOver({
    String? label,
    String? backend,
  }) async {
    _pairingRefuse();
    pairingState = 'inactive';
    return PairingPrepared(session: _pairingSession, code: _pairingCode);
  }

  @override
  Future<String?> pairingResumeGithub({String? backend}) async {
    _pairingRefuse();
    final login = pairingParkedGithub;
    pairingParkedGithub = null;
    if (login != null) pairingActiveHere = false;
    return login;
  }
}
