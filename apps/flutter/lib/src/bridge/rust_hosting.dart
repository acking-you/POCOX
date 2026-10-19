part of '../bridge_api_rust.dart';

mixin _RustHosting implements BridgeApi {
  @override
  Future<AppServeResult> appServeStart({
    required int port,
    String? binaryOverride,
    String? name,
    String? proxy,
    required bool embedded,
  }) async {
    final r = await frb.appServeStart(
      port: port,
      binaryOverride: binaryOverride,
      name: name,
      proxy: proxy,
      embedded: embedded,
    );
    return AppServeResult(
      device: r.device,
      name: r.name,
      appServiceKey: r.appServiceKey,
      appListenAddr: r.appListenAddr,
      apiServiceKey: r.apiServiceKey,
      apiListenAddr: r.apiListenAddr,
      metaServiceKey: r.metaServiceKey,
      metaListenAddr: r.metaListenAddr,
      pid: r.pid,
      reused: r.reused,
    );
  }

  @override
  Future<List<AppServeStatus>> appServeStatus() async {
    final list = await frb.appServeStatus();
    return list.map(_serveStatus).toList();
  }

  @override
  Future<void> appServeDeregister({
    required String name,
    required String kind,
  }) => frb.appServeDeregister(name: name, kind: kind);

  @override
  Future<void> appServeReregister({
    required String name,
    required String kind,
  }) => frb.appServeReregister(name: name, kind: kind);

  @override
  Future<void> appServeStop(String name) => frb.appServeStop(name: name);

  @override
  Future<void> appServeStopAll() => frb.appServeStopAll();

  @override
  Future<String?> codexLocate() => frb.codexLocate();

  @override
  List<AcpPreset> acpPresets() => [
    for (final p in frb.acpPresets())
      AcpPreset(
        id: p.id,
        displayName: p.displayName,
        program: p.program,
        args: p.args,
      ),
  ];

  @override
  Future<OpenCodeEnvironment> openCodeDetect({String? binary}) async {
    final e = await frb.opencodeDetect(binary: binary);
    return OpenCodeEnvironment(
      path: e.path,
      version: e.version,
      problem: e.problem,
      backgroundServer: e.backgroundServer,
    );
  }

  @override
  Future<void> openCodeRefresh({required String name}) =>
      frb.opencodeRefresh(name: name);

  @override
  bool acpHostingSupported() => frb.acpHostingSupported();

  @override
  bool hostingOwnedElsewhere() => frb.hostingOwnedElsewhere();

  @override
  Future<String?> acpLocate(String program, {String? profileId}) =>
      frb.acpLocate(program: program, profileId: profileId);

  @override
  Future<AcpClaudeStatus> acpClaudeStatus() async {
    final s = await frb.acpClaudeStatus();
    return AcpClaudeStatus(
      ready: s.ready,
      adapter: s.adapter,
      adapterPath: s.adapterPath,
      runtime: s.runtime,
      runtimeVersion: s.runtimeVersion,
      runtimePath: s.runtimePath,
      cli: s.cli,
      cliPath: s.cliPath,
      canPrepare: s.canPrepare,
      package: s.package,
      problem: s.problem,
    );
  }

  @override
  Future<AcpClaudeSetup> acpClaudePrepareStart() async =>
      _claudeSetup(await frb.acpClaudePrepareStart());

  @override
  AcpClaudeSetup acpClaudePrepareState() =>
      _claudeSetup(frb.acpClaudePrepareState());

  @override
  AcpClaudeSetup acpClaudePrepareCancelRun(int run) =>
      _claudeSetup(frb.acpClaudePrepareCancelRun(run: BigInt.from(run)));

  @override
  Future<AcpServeResult> appServeStartAcp({
    String? name,
    required AcpAgentSpec spec,
  }) async {
    final r = await frb.appServeStartAcp(
      name: name,
      spec: frb.AcpAgentSpecDto(
        profileId: spec.profileId,
        displayName: spec.displayName,
        program: spec.program,
        args: spec.args,
      ),
    );
    return AcpServeResult(
      device: r.device,
      name: r.name,
      serviceKey: r.serviceKey,
      listenAddr: r.listenAddr,
      metaServiceKey: r.metaServiceKey,
      profileId: r.profileId,
      displayName: r.displayName,
      reused: r.reused,
    );
  }

  @override
  Future<void> appServeRestartAcp(String name) =>
      frb.appServeRestartAcp(name: name);

  @override
  Future<HostConfig> hostConfigGet(String name) async =>
      _hostConfig(await frb.hostConfigGet(name: name));

  @override
  HostConfigSupport hostConfigSupported({AcpAgentSpec? spec, String? engine}) {
    final s = frb.hostConfigSupported(spec: _specDto(spec), engine: engine);
    return HostConfigSupport(
      claudeVariables: s.claudeVariables
          .map(
            (v) => ClaudeVariable(
              name: v.name,
              group: v.group,
              secret: v.secret,
              choices: v.choices,
            ),
          )
          .toList(),
      sources: s.sources,
      protocols: s.protocols,
      modelRequired: s.modelRequired,
      keyRequired: s.keyRequired,
    );
  }

  @override
  Future<HostConfig> hostConfigSave({
    required String name,
    required HostConfigInput input,
    required HostKeyAction keyAction,
    String? key,
    int? expectedRevision,
    AcpAgentSpec? spec,
    HostRuntime? runtime,
  }) async => _hostConfig(
    await frb.hostConfigSave(
      name: name,
      input: _inputDto(input),
      keyAction: keyAction.name,
      key: key,
      expectedRevision: expectedRevision == null
          ? null
          : BigInt.from(expectedRevision),
      spec: _specDto(spec),
      runtime: runtime == null ? null : _runtimeDto(runtime),
    ),
  );

  @override
  Future<HostApplyResult> appServeApply(
    String name, {
    String? expectedIncarnation,
    int? expectedRevision,
  }) async {
    final r = await frb.appServeApply(
      name: name,
      expectedIncarnation: expectedIncarnation,
      expectedRevision: expectedRevision == null
          ? null
          : BigInt.from(expectedRevision),
    );
    return HostApplyResult(
      name: r.name,
      applied: r.applied,
      restoredPrevious: r.restoredPrevious,
      error: r.error,
      restoreError: r.restoreError,
      revision: r.revision?.toInt(),
    );
  }

  @override
  Future<HostStartResult> appServeStartConfigured({
    String? name,
    required HostRuntime runtime,
    required HostConfigInput input,
    required HostKeyAction keyAction,
    String? key,
  }) async {
    final r = await frb.appServeStartConfigured(
      name: name,
      runtime: _runtimeDto(runtime),
      input: _inputDto(input),
      keyAction: keyAction.name,
      key: key,
    );
    return HostStartResult(
      name: r.name,
      provider: r.provider,
      serviceKey: r.serviceKey,
      reused: r.reused,
      notice: r.notice,
    );
  }

  @override
  Future<String> codexLocalSessionOpen({String? binary, String? proxy}) =>
      frb.codexLocalSessionOpen(binary: binary, proxy: proxy);

  @override
  Future<void> codexLocalSessionClose(String sessionId) =>
      frb.codexLocalSessionClose(sessionId: sessionId);

  @override
  Future<CodexLoginStart> codexLocalLoginStart(String sessionId) async {
    final s = await frb.codexLocalLoginStart(sessionId: sessionId);
    return CodexLoginStart(
      mode: s.mode,
      loginId: s.loginId,
      authUrl: s.authUrl,
      verificationUrl: s.verificationUrl,
      userCode: s.userCode,
    );
  }

  @override
  Future<CodexAuthStatus> codexLocalAuthStatus(
    String sessionId, {
    String? loginId,
  }) async {
    final s = await frb.codexLocalAuthStatus(
      sessionId: sessionId,
      loginId: loginId,
    );
    return CodexAuthStatus(
      authenticated: s.authenticated,
      method: s.method,
      completed: s.completed,
      error: s.error,
    );
  }

  @override
  Future<void> codexLocalLoginCancel(String sessionId, String loginId) =>
      frb.codexLocalLoginCancel(sessionId: sessionId, loginId: loginId);

  @override
  Future<void> codexLocalLogout(String sessionId) =>
      frb.codexLocalLogout(sessionId: sessionId);
}

AcpClaudeSetup _claudeSetup(frb.AcpClaudeSetupDto s) => AcpClaudeSetup(
  state: s.state,
  stage: s.stage,
  elapsedMs: s.elapsedMs.toInt(),
  downloadedBytes: s.downloadedBytes?.toInt(),
  downloadBytesPerSecond: s.downloadBytesPerSecond?.toInt(),
  error: s.error,
  run: s.run.toInt(),
  started: s.started,
);

frb.AcpAgentSpecDto? _specDto(AcpAgentSpec? spec) => spec == null
    ? null
    : frb.AcpAgentSpecDto(
        profileId: spec.profileId,
        displayName: spec.displayName,
        program: spec.program,
        args: spec.args,
      );

AcpAgentSpec _spec(frb.AcpAgentSpecDto s) => AcpAgentSpec(
  profileId: s.profileId,
  displayName: s.displayName,
  program: s.program,
  args: s.args,
);

HostRuntime _runtime(frb.HostRuntimeDto r) => switch (r.kind) {
  'opencode' => HostRuntime.opencode(
    binary: r.binary,
    separateHistory: r.separateHistory,
  ),
  _ when r.agent != null => HostRuntime.acp(_spec(r.agent!)),
  _ => HostRuntime.codex(binary: r.binary, port: r.port, proxy: r.proxy),
};

frb.HostRuntimeDto _runtimeDto(HostRuntime r) => frb.HostRuntimeDto(
  kind: r.kind,
  binary: r.binary,
  port: r.port,
  proxy: r.proxy,
  agent: _specDto(r.agent),
  separateHistory: r.separateHistory,
);

frb.HostConfigInputDto _inputDto(HostConfigInput input) =>
    frb.HostConfigInputDto(
      claudeEnv: input.claudeEnv?.entries
          .map((v) => frb.HostEnvironmentEntryDto(name: v.key, value: v.value))
          .toList(),
      source: input.source,
      protocol: input.protocol,
      baseUrl: input.baseUrl,
      model: input.model,
    );

HostConfig _hostConfig(frb.HostConfigDto c) => HostConfig(
  claudeEnv: {for (final v in c.claudeEnv) v.name: v.value},
  source: c.source,
  protocol: c.protocol,
  baseUrl: c.baseUrl,
  model: c.model,
  keySet: c.keySet,
  revision: c.revision.toInt(),
  runtime: c.runtime == null ? null : _runtime(c.runtime!),
  problem: c.problem,
  active: c.active == null
      ? null
      : HostActive(
          incarnation: c.active!.incarnation,
          runtime: _runtime(c.active!.runtime),
          source: c.active!.source,
          revision: c.active!.revision.toInt(),
        ),
);

AppServeStatus _serveStatus(frb.AppServeStatusDto s) => AppServeStatus(
  name: s.name,
  device: s.device,
  pid: s.pid,
  alive: s.alive,
  appListenAddr: s.appListenAddr,
  appServiceKey: s.appServiceKey,
  appRegistered: s.appRegistered,
  apiListenAddr: s.apiListenAddr,
  apiServiceKey: s.apiServiceKey,
  apiRegistered: s.apiRegistered,
  metaListenAddr: s.metaListenAddr,
  metaServiceKey: s.metaServiceKey,
  metaRegistered: s.metaRegistered,
  embedded: s.embedded,
  codexBinary: s.codexBinary,
  proxy: s.proxy,
  provider: s.provider,
  providerVersion: s.providerVersion,
  protocol: s.protocol,
  providerName: s.providerName,
  profileId: s.profileId,
  agentPhase: s.agentPhase,
  agentError: s.agentError,
  authRequired: s.authRequired,
  opencode: s.opencode == null
      ? null
      : OpenCodeHostStatus(
          version: s.opencode!.version,
          providersConnected: s.opencode!.providersConnected,
          models: s.opencode!.models,
          defaultModel: s.opencode!.defaultModel,
          agents: s.opencode!.agents,
          problem: s.opencode!.problem,
          separateHistory: s.opencode!.separateHistory,
          backgroundServer: s.opencode!.backgroundServer,
        ),
  configSource: s.configSource,
  configRevision: s.configRevision?.toInt(),
  incarnation: s.incarnation,
  busy: s.busy,
);
