part of '../bridge_api_rust.dart';

mixin _RustPairing implements BridgeApi {
  /// Run [call], turning the bridge's refusal into the UI's own failure type.
  Future<T> _pairing<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on frb.PairingErrorDto catch (error) {
      throw PairingFailure(
        code: error.code,
        message: error.message,
        retryAfterSecs: error.retryAfterSecs?.toInt(),
        operationId: error.operationId,
        graceDeadline: error.graceDeadline?.toInt(),
      );
    }
  }

  frb.NativeHintDto? _hint(NativeHardwareHint? hint) => hint == null
      ? null
      : frb.NativeHintDto(source: hint.source, rawId: hint.rawId);

  PairingSession _session(frb.PairingSessionDto s) => PairingSession(
    deviceId: s.deviceId,
    accountId: s.accountId,
    label: s.label,
    activated: s.activated,
    membershipChange: s.membershipChange,
    membershipChangedAt: s.membershipChangedAt?.toInt(),
  );

  PairingCode _code(frb.PairingCodeDto c) => PairingCode(
    code: c.code,
    uri: c.uri,
    issuedAt: c.issuedAt.toInt(),
    nextRotationAt: c.nextRotationAt.toInt(),
    paused: c.paused,
  );

  PairingPrepared _prepared(frb.PairingPreparedDto p) =>
      PairingPrepared(session: _session(p.session), code: _code(p.code));

  PairingOperation _operation(frb.PairingOperationDto o) => PairingOperation(
    id: o.id,
    kind: o.kind,
    status: o.status,
    error: o.error,
  );

  List<PairingPreviewDevice> _previewDevices(
    List<frb.PairingPreviewDeviceDto> devices,
  ) => [
    for (final device in devices)
      PairingPreviewDevice(
        id: device.id,
        name: device.name,
        lastActiveDay: device.lastActiveDay.toInt(),
      ),
  ];

  PairingRestoreRequest _restoreRequest(frb.PairingRestoreRequestDto r) =>
      PairingRestoreRequest(
        requestId: r.requestId,
        status: r.status,
        matchingId: r.matchingId,
        expiresAt: r.expiresAt?.toInt(),
        targetDeviceId: r.targetDeviceId,
        devices: _previewDevices(r.devices),
      );

  @override
  Future<void> pairingInstallNativeStore({
    required String lockDir,
    required Future<NativeStoreAnswer> Function(String slot) read,
    required Future<String?> Function(String slot, String value) write,
  }) => frb.pairingInstallNativeStore(
    lockDir: lockDir,
    read: (slot) async {
      final answer = await read(slot);
      return frb.NativeStoreRead(value: answer.value, error: answer.error);
    },
    write: write,
  );

  @override
  Future<PairingStatus> pairingStatus({String? backend}) => _pairing(() async {
    final s = await frb.pairingStatus(backend: backend);
    final session = s.session;
    return PairingStatus(
      state: s.state,
      backend: s.backend,
      activeHere: s.activeHere,
      session: session == null ? null : _session(session),
      graceDeadline: s.graceDeadline?.toInt(),
      pending: s.pending.map(_operation).toList(),
      parkedGithub: s.parkedGithub,
    );
  });

  @override
  Future<PairingPrepared> pairingPrepare({String? label, String? backend}) =>
      _pairing(() async {
        return _prepared(
          await frb.pairingPrepare(label: label, backend: backend),
        );
      });

  @override
  Future<PairingSession> pairingActivate({
    NativeHardwareHint? hint,
    String? backend,
  }) => _pairing(() async {
    return _session(
      await frb.pairingActivate(nativeHint: _hint(hint), backend: backend),
    );
  });

  @override
  Future<PairingCode> pairingCode() =>
      _pairing(() async => _code(await frb.pairingCode()));

  @override
  Future<PairingCode> pairingSetPaused({required bool paused}) =>
      _pairing(() async => _code(await frb.pairingSetPaused(paused: paused)));

  @override
  Future<PairingCode> pairingRotate() =>
      _pairing(() async => _code(await frb.pairingRotate()));

  @override
  String? pairingParseInvitation(String uri) =>
      frb.pairingParseInvitation(uri: uri);

  @override
  Future<PairingPreview> pairingPreview(String code, {String? backend}) =>
      _pairing(() async {
        final p = await frb.pairingPreview(code: code, backend: backend);
        return PairingPreview(
          ticket: p.ticket,
          expiresAt: p.expiresAt.toInt(),
          targetDeviceId: p.targetDeviceId,
          alreadyMember: p.alreadyMember,
          devices: _previewDevices(p.devices),
        );
      });

  @override
  Future<PairingOperation> pairingLink({
    required String ticket,
    required bool leaveCurrent,
    NativeHardwareHint? hint,
    String? backend,
  }) => _pairing(() async {
    return _operation(
      await frb.pairingLink(
        ticket: ticket,
        leaveCurrent: leaveCurrent,
        nativeHint: _hint(hint),
        backend: backend,
      ),
    );
  });

  @override
  Future<PairingOperation> pairingLeave() =>
      _pairing(() async => _operation(await frb.pairingLeave()));

  @override
  Future<List<PairingOperation>> pairingSettle({String? backend}) =>
      _pairing(() async {
        final outcomes = await frb.pairingSettle(backend: backend);
        return outcomes.map(_operation).toList();
      });

  @override
  Future<PairingDevices> pairingDevices({String? cursor}) => _pairing(() async {
    final page = await frb.pairingDevices(cursor: cursor);
    return PairingDevices(
      devices: [
        for (final device in page.devices)
          PairingDevice(
            id: device.id,
            name: device.name,
            platform: device.platform,
            joinedAt: device.joinedAt.toInt(),
            lastActiveDay: device.lastActiveDay.toInt(),
            activated: device.activated,
            isSelf: device.isSelf,
          ),
      ],
      pendingRequests: [
        for (final request in page.pendingRequests)
          PairingRecoveryAsk(
            requestId: request.requestId,
            targetDeviceId: request.targetDeviceId,
            requesterName: request.requesterName,
            matchingId: request.matchingId,
            expiresAt: request.expiresAt.toInt(),
          ),
      ],
      nextCursor: page.nextCursor,
    );
  });

  @override
  Future<void> pairingRenameDevice({
    required String deviceId,
    required String name,
  }) => _pairing(() => frb.pairingRenameDevice(deviceId: deviceId, name: name));

  @override
  Future<PairingOperation> pairingRemoveDevice(String deviceId) => _pairing(
    () async => _operation(await frb.pairingRemoveDevice(deviceId: deviceId)),
  );

  @override
  Future<void> pairingDecideRestore({
    required String deviceId,
    required String requestId,
    required bool allow,
  }) => _pairing(
    () => frb.pairingDecideRestore(
      deviceId: deviceId,
      requestId: requestId,
      allow: allow,
    ),
  );

  @override
  Future<PairingRestoreRequest> pairingRestoreRequest({
    NativeHardwareHint? hint,
    String? backend,
  }) => _pairing(() async {
    return _restoreRequest(
      await frb.pairingRestoreRequest(
        nativeHint: _hint(hint),
        backend: backend,
      ),
    );
  });

  @override
  Future<PairingRestoreRequest> pairingRestorePoll(
    String requestId, {
    String? backend,
  }) => _pairing(() async {
    return _restoreRequest(
      await frb.pairingRestorePoll(requestId: requestId, backend: backend),
    );
  });

  @override
  Future<PairingOperation> pairingRestoreConfirm({
    String? ticket,
    String? targetDeviceId,
    String? requestId,
    bool retake = false,
    NativeHardwareHint? hint,
    String? backend,
  }) => _pairing(() async {
    return _operation(
      await frb.pairingRestoreConfirm(
        ticket: ticket,
        targetDeviceId: targetDeviceId,
        requestId: requestId,
        retake: retake,
        nativeHint: _hint(hint),
        backend: backend,
      ),
    );
  });

  @override
  Future<PairingPrepared> pairingStartOver({String? label, String? backend}) =>
      _pairing(() async {
        return _prepared(
          await frb.pairingStartOver(label: label, backend: backend),
        );
      });

  @override
  Future<String?> pairingResumeGithub() => _pairing(frb.pairingResumeGithub);
}
