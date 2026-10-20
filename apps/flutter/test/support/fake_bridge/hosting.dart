part of '../../fake_bridge_api.dart';

mixin _FakeHosting on _FakeBridgeState {
  /// Read-only identity requests, independent of session connections.
  final List<String> agentIdentityCalls = [];
  final Map<String, AgentIdentity> agentIdentities = {};
  final Map<String, Future<AgentIdentity>> agentIdentityReplies = {};

  @override
  Future<AppServeResult> appServeStart({
    required int port,
    String? binaryOverride,
    String? name,
    String? proxy,
    required bool embedded,
  }) async {
    final gate = serveStartGate;
    if (gate != null) {
      serveStartGate = null;
      await gate.future;
    }
    if (serveStartError case final error?) {
      serveStartError = null;
      throw error;
    }
    lastServePort = port;
    lastServeBinary = binaryOverride;
    lastServeName = name;
    lastServeProxy = proxy;
    lastServeEmbedded = embedded;
    final n = name ?? 'default';
    const device = 'local';
    final appKey = 'pcx:$device:app:$n';
    final apiKey = 'pcx:$device:api:$n';
    final metaKey = 'pcx:$device:meta:$n';
    activeRuntimes.remove(n);
    serveHosts
      ..removeWhere((h) => h.name == n)
      ..add(
        AppServeStatus(
          name: n,
          device: device,
          pid: 4242,
          alive: true,
          appListenAddr: '127.0.0.1:$port',
          appServiceKey: appKey,
          appRegistered: true,
          apiListenAddr: '127.0.0.1:18080',
          apiServiceKey: apiKey,
          apiRegistered: true,
          metaListenAddr: '127.0.0.1:18090',
          metaServiceKey: metaKey,
          metaRegistered: true,
        ),
      );
    // Hosting registers on the relay, so discovery finds the new tunnels —
    // mirror that (idempotently) for flows that re-discover after a start.
    if (!_services.any((s) => s.key == appKey)) {
      _services.add(
        ServiceEntry(device: device, kind: 'app', name: n, key: appKey),
      );
    }
    if (!_services.any((s) => s.key == apiKey)) {
      _services.add(
        ServiceEntry(device: device, kind: 'api', name: n, key: apiKey),
      );
    }
    return AppServeResult(
      device: device,
      name: n,
      appServiceKey: appKey,
      appListenAddr: '127.0.0.1:$port',
      apiServiceKey: apiKey,
      apiListenAddr: '127.0.0.1:18080',
      metaServiceKey: metaKey,
      metaListenAddr: '127.0.0.1:18090',
      pid: 4242,
      reused: false,
    );
  }

  @override
  Future<List<AppServeStatus>> appServeStatus() async {
    serveStatusCalls++;
    return List.unmodifiable(serveHosts);
  }

  @override
  Future<void> appServeDeregister({
    required String name,
    required String kind,
  }) async {
    final i = serveHosts.indexWhere((h) => h.name == name);
    if (i < 0) return;
    serveHosts[i] = _withTunnel(serveHosts[i], kind, false);
  }

  @override
  Future<void> appServeReregister({
    required String name,
    required String kind,
  }) async {
    final i = serveHosts.indexWhere((h) => h.name == name);
    if (i < 0) return;
    serveHosts[i] = _withTunnel(serveHosts[i], kind, true);
  }

  @override
  Future<void> appServeStop(String name) async {
    final gate = serveStopGate;
    if (gate != null) {
      serveStopGate = null;
      await gate.future;
    }
    if (serveStopFailures > 0) {
      serveStopFailures--;
      throw StateError(
        "an earlier codex of `$name` did not exit; stop the host again",
      );
    }
    serveHosts.removeWhere((h) => h.name == name);
    activeRuntimes.remove(name);
  }

  @override
  Future<void> appServeStopAll() async {
    serveHosts.clear();
    activeRuntimes.clear();
  }

  @override
  Future<String?> codexLocate() async {
    codexLocateCalls++;
    final gate = codexLocateGate;
    if (gate != null) {
      codexLocateGate = null;
      await gate.future;
    }
    return codexPath;
  }

  @override
  Future<AgentIdentity> appAgentIdentity(String serviceKey) async {
    agentIdentityCalls.add(serviceKey);
    return await agentIdentityReplies[serviceKey] ??
        agentIdentities[serviceKey] ??
        const AgentIdentity(provider: 'acp');
  }

  @override
  AppCapabilities appCapabilities(String serviceKey) {
    capabilityCalls.add(serviceKey);
    return switch (sessionProtocolOf(serviceKey)) {
      SessionProtocol.acp => acpCapabilities[serviceKey] ?? AppCapabilities.acp,
      SessionProtocol.opencode =>
        acpCapabilities[serviceKey] ?? AppCapabilities.opencode,
      SessionProtocol.codexAppServer => AppCapabilities.codex,
    };
  }

  @override
  Future<List<String>> appRunningThreads(String serviceKey) async =>
      runningThreads[serviceKey] ?? const [];

  @override
  List<AcpPreset> acpPresets() => presets;

  @override
  Future<OpenCodeEnvironment> openCodeDetect({String? binary}) async {
    openCodeDetectCalls.add(binary);
    final gate = openCodeDetectGate;
    if (gate != null) {
      openCodeDetectGate = null;
      await gate.future;
    }
    if (binary == null) return openCodeEnvironment;
    return OpenCodeEnvironment(
      path: binary,
      version: openCodeEnvironment.version,
      backgroundServer: openCodeEnvironment.backgroundServer,
    );
  }

  @override
  Future<void> openCodeRefresh({required String name}) async {
    openCodeRefreshCalls.add(name);
    final gate = openCodeRefreshGate;
    if (gate != null) {
      openCodeRefreshGate = null;
      await gate.future;
    }
    final err = openCodeRefreshError;
    if (err != null) {
      openCodeRefreshError = null;
      throw err;
    }
    final status = openCodeRefreshStatus;
    openCodeRefreshStatus = null;
    final i = serveHosts.indexWhere((h) => h.name == name && h.isOpenCode);
    if (i < 0) throw StateError('no running OpenCode host named $name');
    if (status == null) return;
    final h = serveHosts[i];
    // Same host, same incarnation: only the catalog summary changes.
    serveHosts[i] = AppServeStatus(
      name: h.name,
      device: h.device,
      pid: h.pid,
      alive: h.alive,
      appListenAddr: h.appListenAddr,
      appServiceKey: h.appServiceKey,
      appRegistered: h.appRegistered,
      apiListenAddr: h.apiListenAddr,
      apiServiceKey: h.apiServiceKey,
      apiRegistered: h.apiRegistered,
      metaListenAddr: h.metaListenAddr,
      metaServiceKey: h.metaServiceKey,
      metaRegistered: h.metaRegistered,
      embedded: h.embedded,
      codexBinary: h.codexBinary,
      proxy: h.proxy,
      provider: h.provider,
      providerVersion: h.providerVersion,
      protocol: h.protocol,
      providerName: h.providerName,
      profileId: h.profileId,
      agentPhase: h.agentPhase,
      agentError: h.agentError,
      authRequired: h.authRequired,
      opencode: status,
      configSource: h.configSource,
      configRevision: h.configRevision,
      incarnation: h.incarnation,
      busy: h.busy,
    );
  }

  @override
  bool acpHostingSupported() {
    acpHostingSupportedCalls++;
    return acpHosting;
  }

  @override
  bool hostingOwnedElsewhere() => hostingElsewhere;

  @override
  Future<String?> acpLocate(String program, {String? profileId}) async {
    acpLocateCalls.add(program);
    final gate = acpLocateGates[program];
    if (gate != null) await gate.future;
    if (acpLocateFailures.remove(program)) {
      throw StateError('lookup of $program failed');
    }
    return program.startsWith('/') ? program : acpPrograms[program];
  }

  @override
  Future<AcpClaudeStatus> acpClaudeStatus() async {
    claudeStatusCalls++;
    final gate = claudeStatusGate;
    if (gate != null) {
      claudeStatusGate = null;
      await gate.future;
    }
    return claudeStatus;
  }

  @override
  Future<AcpClaudeSetup> acpClaudePrepareStart() async {
    final error = claudePrepareError;
    if (error != null) {
      claudePrepareError = null;
      throw error;
    }
    // Captured at admission, as the bridge answers: `started` only for the
    // call that started its run; a join is a plain snapshot.
    final AcpClaudeSetup response;
    if (claudeSetup.running) {
      response = claudeSetup;
    } else {
      claudePrepareStarts++;
      final run = claudeSetup.run + 1;
      final answer = claudePrepareAnswer;
      claudePrepareAnswer = null;
      claudeSetup = AcpClaudeSetup(
        state: answer?.state ?? 'running',
        stage: answer == null ? 'installing' : answer.stage,
        error: answer?.error,
        run: run,
      );
      response = AcpClaudeSetup(
        state: claudeSetup.state,
        stage: claudeSetup.stage,
        error: claudeSetup.error,
        run: run,
        started: true,
      );
    }
    final gate = claudePrepareGate;
    if (gate != null) {
      claudePrepareGate = null;
      await gate.future;
    }
    return response;
  }

  @override
  AcpClaudeSetup acpClaudePrepareState() => claudeSetup;

  @override
  AcpClaudeSetup acpClaudePrepareCancelRun(int run) {
    claudePrepareCancels++;
    claudeCancelledRuns.add(run);
    if (claudeSetup.running && claudeSetup.run == run) {
      claudeSetup = AcpClaudeSetup(state: 'cancelled', run: run);
    }
    return claudeSetup;
  }

  @override
  Future<AcpServeResult> appServeStartAcp({
    String? name,
    required AcpAgentSpec spec,
  }) async {
    final gate = serveStartAcpGate;
    if (gate != null) {
      serveStartAcpGate = null;
      await gate.future;
    }
    acpServeCalls.add((name, spec));
    final err = acpServeError;
    if (err != null) {
      acpServeError = null;
      throw err;
    }
    final n = name ?? spec.profileId;
    if (serveHosts.any((h) => h.name == n && !h.isAcp)) {
      throw StateError('`$n` is already hosting on this device');
    }
    const device = 'local';
    final key = 'pcx:$device:acp:$n';
    final metaKey = 'pcx:$device:meta:$n';
    activeRuntimes.remove(n);
    serveHosts
      ..removeWhere((h) => h.name == n)
      ..add(
        AppServeStatus(
          name: n,
          device: device,
          alive: true,
          appListenAddr: '127.0.0.1:18200',
          appServiceKey: key,
          appRegistered: true,
          metaListenAddr: '127.0.0.1:18201',
          metaServiceKey: metaKey,
          metaRegistered: true,
          codexBinary: spec.program,
          provider: 'acp',
          protocol: 'acp',
          providerName: spec.displayName,
          profileId: spec.profileId,
          agentPhase: 'ready',
        ),
      );
    if (!_services.any((s) => s.key == key)) {
      _services.add(
        ServiceEntry(device: device, kind: 'acp', name: n, key: key),
      );
    }
    return AcpServeResult(
      device: device,
      name: n,
      serviceKey: key,
      listenAddr: '127.0.0.1:18200',
      metaServiceKey: metaKey,
      profileId: spec.profileId,
      displayName: spec.displayName,
      reused: false,
    );
  }

  @override
  Future<void> appServeRestartAcp(String name) async {
    acpRestartCalls.add(name);
    final gate = acpRestartGate;
    if (gate != null) {
      acpRestartGate = null;
      await gate.future;
    }
    final error = acpRestartError;
    if (error != null) {
      acpRestartError = null;
      throw error;
    }
  }

  @override
  Future<HostConfig> hostConfigGet(String name) async {
    hostConfigGets++;
    final gate = hostConfigGetGate;
    if (gate != null) {
      hostConfigGetGate = null;
      await gate.future;
    }
    final err = hostConfigGetError;
    if (err != null) {
      hostConfigGetError = null;
      throw err;
    }
    return _withActive(hostConfigs[name] ?? const HostConfig(), name);
  }

  @override
  HostConfigSupport hostConfigSupported({AcpAgentSpec? spec, String? engine}) {
    // Mirrors the bridge's matrix (`host_config_supported`). OpenCode uses
    // its own configuration or a custom provider (no official account).
    if (engine == 'opencode') {
      return const HostConfigSupport(
        sources: ['inherited', 'custom'],
        protocols: ['responses', 'anthropic-messages', 'chat-completions'],
        modelRequired: true,
        keyRequired: true,
      );
    }
    if (spec == null) {
      return const HostConfigSupport(
        sources: ['inherited', 'official', 'custom'],
        protocols: ['responses'],
      );
    }
    return switch (spec.profileId) {
      'claude' => const HostConfigSupport(
        claudeVariables: [
          ClaudeVariable(
            name: 'ANTHROPIC_AUTH_TOKEN',
            group: 'connection',
            secret: true,
          ),
          ClaudeVariable(name: 'ANTHROPIC_DEFAULT_OPUS_MODEL', group: 'models'),
          ClaudeVariable(
            name: 'CLAUDE_CODE_EFFORT_LEVEL',
            group: 'reasoning',
            choices: ['auto', 'low', 'medium', 'high', 'xhigh', 'max'],
          ),
        ],
        sources: ['inherited', 'custom'],
        protocols: ['anthropic-messages'],
        keyRequired: true,
      ),
      // Grok: its own sign-in, or a custom provider in a home of its own.
      'grok' => const HostConfigSupport(
        sources: ['inherited', 'official', 'custom'],
        protocols: ['responses', 'anthropic-messages', 'chat-completions'],
        modelRequired: true,
        keyRequired: true,
      ),
      _ => const HostConfigSupport(),
    };
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
  }) async {
    hostConfigSaves.add((name, input, keyAction, key, spec));
    hostConfigSaveRuntimes.add(runtime);
    final gate = hostConfigSaveGate;
    if (gate != null) {
      hostConfigSaveGate = null;
      await gate.future;
    }
    final err = hostConfigSaveError;
    if (err != null) {
      hostConfigSaveError = null;
      throw err;
    }
    final saved = _store(
      name,
      input,
      keyAction,
      expectedRevision,
      spec,
      runtime,
    );
    return _withActive(saved, name);
  }

  @override
  Future<HostApplyResult> appServeApply(
    String name, {
    String? expectedIncarnation,
    int? expectedRevision,
  }) async {
    applyCalls.add((name, expectedIncarnation, expectedRevision));
    final gate = applyGate;
    if (gate != null) {
      applyGate = null;
      await gate.future;
    }
    final i = serveHosts.indexWhere((h) => h.name == name);
    if (i < 0) throw StateError('`$name` is not hosting');
    final config = hostConfigs[name] ?? const HostConfig();
    final running = activeOf(serveHosts[i])!;
    if (expectedIncarnation != null &&
        expectedIncarnation != running.incarnation) {
      throw StateError('`$name` was restarted since; reload it');
    }
    if (expectedRevision != null && expectedRevision != config.revision) {
      throw StateError('the saved configuration changed; reload it');
    }
    final result = applyResult;
    if (result != null) {
      applyResult = null;
      return result;
    }
    serveHosts[i] = relaunched(
      serveHosts[i],
      runtime: config.runtime,
      config: config,
    );
    return HostApplyResult(
      name: name,
      applied: true,
      revision: config.revision,
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
    startConfiguredCalls.add((name, runtime, input, keyAction, key));
    final agent = runtime.agent;
    final n = (name == null || name.trim().isEmpty)
        ? (agent?.profileId ?? 'default')
        : name.trim();
    // As the bridge: one instance per canonical name, and one host at a
    // time on OpenCode's default database.
    if (serveHosts.any(
      (h) => canonicalHostName(h.name) == canonicalHostName(n),
    )) {
      throw StateError(
        '`$n` is already hosting; edit it instead, or choose another name',
      );
    }
    if (runtime.isOpenCode &&
        !runtime.separateHistory &&
        serveHosts.any((h) => h.servesOpenCodeHistory)) {
      throw StateError(
        'opencode_already_hosted: this native source already has a Pocket host',
      );
    }
    final previous = hostConfigs[n];
    hostConfigs.remove(n);
    final saved = _store(n, input, keyAction, null, agent, runtime);
    try {
      if (runtime.isOpenCode) {
        final err = openCodeServeError;
        if (err != null) {
          openCodeServeError = null;
          throw err;
        }
        final host = FakeBridgeApi.openCodeHost(
          n,
          binary: runtime.binary,
          separateHistory: runtime.separateHistory,
        );
        serveHosts.add(relaunched(host, runtime: runtime, config: saved));
        if (!_services.any((s) => s.key == host.appServiceKey)) {
          _services.add(
            ServiceEntry(
              device: host.device,
              kind: 'opencode',
              name: n,
              key: host.appServiceKey,
            ),
          );
        }
        return HostStartResult(
          name: n,
          provider: 'opencode',
          serviceKey: host.appServiceKey,
        );
      }
      if (agent != null) {
        final r = await appServeStartAcp(name: name, spec: agent);
        final i = serveHosts.indexWhere((h) => h.name == r.name);
        serveHosts[i] = relaunched(
          serveHosts[i],
          runtime: runtime,
          config: saved,
        );
        return HostStartResult(
          name: r.name,
          provider: 'acp',
          serviceKey: r.serviceKey,
          reused: r.reused,
        );
      }
      final r = await appServeStart(
        port: runtime.port,
        binaryOverride: runtime.binary,
        name: name,
        proxy: runtime.proxy,
        embedded: false,
      );
      final i = serveHosts.indexWhere((h) => h.name == r.name);
      serveHosts[i] = relaunched(
        serveHosts[i],
        runtime: runtime,
        config: saved,
      );
      return HostStartResult(
        name: r.name,
        provider: 'codex',
        serviceKey: r.appServiceKey,
        reused: r.reused,
      );
    } catch (_) {
      // A failed start puts the previous saved configuration back.
      if (previous == null) {
        hostConfigs.remove(n);
      } else {
        hostConfigs[n] = previous;
      }
      rethrow;
    }
  }

  @override
  Future<String> codexLocalSessionOpen({String? binary, String? proxy}) async {
    localSessionProxies.add(proxy);
    localSessionBinaries.add(binary);
    final gate = localSessionGate;
    if (gate != null) {
      localSessionGate = null;
      await gate.future;
    }
    final err = signInOpenError;
    if (err != null) {
      signInOpenError = null;
      throw err;
    }
    // Sessions are independent, as in the bridge: opening one never closes
    // another.
    final id = 'local-${signInSessions.length + closedSignInSessions.length}';
    signInSessions.add(id);
    return id;
  }

  @override
  Future<void> codexLocalSessionClose(String sessionId) async {
    if (signInSessions.remove(sessionId)) closedSignInSessions.add(sessionId);
  }

  @override
  Future<CodexLoginStart> codexLocalLoginStart(String sessionId) async {
    _requireLocal(sessionId);
    return const CodexLoginStart(
      mode: 'browser',
      loginId: 'fake-login',
      authUrl: 'https://auth.openai.com/fake',
    );
  }

  @override
  Future<CodexAuthStatus> codexLocalAuthStatus(
    String sessionId, {
    String? loginId,
  }) async {
    _requireLocal(sessionId);
    final gate = localAuthGates.remove(sessionId);
    if (gate != null) await gate.future;
    final err = localAuthError;
    if (err != null) {
      localAuthError = null;
      throw err;
    }
    return localAuth[sessionId] ?? const CodexAuthStatus(authenticated: false);
  }

  @override
  Future<void> codexLocalLoginCancel(String sessionId, String loginId) async {
    _requireLocal(sessionId);
    localCancels.add((sessionId, loginId));
  }

  @override
  Future<void> codexLocalLogout(String sessionId) async {
    _requireLocal(sessionId);
    final gate = localLogoutGate;
    if (gate != null) {
      localLogoutGate = null;
      await gate.future;
    }
    localLogouts++;
    localLogoutSessions.add(sessionId);
  }
}

/// [status] as a relaunch with [runtime] reports it: an OpenCode runtime
/// brings its history choice.
OpenCodeHostStatus? _withHistory(
  OpenCodeHostStatus? status,
  HostRuntime? runtime,
) => status == null || runtime == null || !runtime.isOpenCode
    ? status
    : OpenCodeHostStatus(
        version: status.version,
        providersConnected: status.providersConnected,
        models: status.models,
        defaultModel: status.defaultModel,
        agents: status.agents,
        problem: status.problem,
        separateHistory: runtime.separateHistory,
      );
