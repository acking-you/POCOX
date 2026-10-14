part of '../../fake_bridge_api.dart';

mixin _FakeConnection on _FakeBridgeState {
  @override
  Future<ThreadHistory?> appHistoryCached(
    String serviceKey,
    String threadId,
  ) async => cachedHistories[threadId];
  @override
  Future<bool> appHistorySyncPrepare(String serviceKey) async => false;
  @override
  Future<void> appHistoryPrefetch(String serviceKey, String threadId) async {}
  @override
  Future<void> appHistoryFocus(String serviceKey, String? threadId) async {}
  @override
  Future<HistoryCacheStatus> historyCacheStatus() async =>
      const HistoryCacheStatus(limitMb: 512, usedBytes: 0);
  @override
  Future<void> historyCacheSetLimit(int limitMb) async {}

  @override
  Future<ConfigInfo> getConfig() async => _config;

  @override
  Future<void> setRelay(String relay) async => _config = ConfigInfo(
    relay: relay,
    hasKey: _config.hasKey,
    locale: _config.locale,
  );

  @override
  Future<void> setKey(String key) async {
    if (key.length != 32) throw ArgumentError('key must be 32 bytes');
    _config = ConfigInfo(
      relay: _config.relay,
      hasKey: true,
      locale: _config.locale,
    );
  }

  @override
  Future<String> importConfig(String text) async {
    if (!text.startsWith('pcx1:')) {
      throw const FormatException('not a pcx1 string');
    }
    _config = const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true);
    return 'lb7666.top:7666';
  }

  @override
  Future<String> exportConfig() async => 'pcx1:ZmFrZQ';

  @override
  Future<List<ServiceEntry>> discoverServices() async {
    discoverCalls++;
    final gate = discoverGate;
    if (gate != null) await gate.future;
    if (discoverError != null) throw discoverError!;
    return _services;
  }

  @override
  Future<SubInfo> apiSubscribe(String serviceKey, int localPort) async {
    final s = SubInfo(
      key: serviceKey,
      localAddr: '127.0.0.1:$localPort',
      alive: true,
    );
    _subs[serviceKey] = s;
    return s;
  }

  @override
  Future<void> apiUnsubscribe(String serviceKey) async =>
      _subs.remove(serviceKey);

  @override
  Future<List<SubInfo>> subscriptions() async => _subs.values.toList();

  @override
  Future<void> setLocale(String locale) async => _config = ConfigInfo(
    relay: _config.relay,
    hasKey: _config.hasKey,
    locale: locale.isEmpty ? null : locale,
  );

  @override
  Future<CodexSetupStatus> codexSetupStatus() async => codexStatus;

  @override
  Future<void> codexSetupProvider({
    required String baseUrl,
    required String apiKey,
    String? model,
  }) async {
    lastProvider = (baseUrl: baseUrl, apiKey: apiKey, model: model);
    codexStatus = CodexSetupStatus(
      codexHome: codexStatus.codexHome,
      hasConfig: true,
      hasAuth: codexStatus.hasAuth,
      hasCustomProvider: true,
      authMode: codexStatus.authMode,
      needsSetup: false,
      promptVariant: codexStatus.promptVariant,
    );
  }

  @override
  Future<String> codexPromptVariant() async => codexStatus.promptVariant;

  @override
  Future<void> codexSetPromptVariant(String variant) async {
    codexStatus = CodexSetupStatus(
      codexHome: codexStatus.codexHome,
      hasConfig: codexStatus.hasConfig,
      hasAuth: codexStatus.hasAuth,
      hasCustomProvider: codexStatus.hasCustomProvider,
      authMode: codexStatus.authMode,
      needsSetup: codexStatus.needsSetup,
      promptVariant: variant,
    );
  }

  @override
  Future<CodexLoginStart> codexLoginChatgptStart(String serviceKey) async =>
      const CodexLoginStart(
        mode: 'browser',
        loginId: 'fake-login',
        authUrl: 'https://auth.openai.com/fake',
      );

  @override
  Future<CodexAuthStatus> codexAuthStatus(String serviceKey) async => codexAuth;

  @override
  Future<void> codexLoginCancel(String serviceKey, String loginId) async {}

  @override
  Future<void> codexLogout(String serviceKey) async {}

  @override
  Future<DeviceCode> accountLoginStart({String? backend}) async => DeviceCode(
    userCode: 'ABCD-1234',
    verificationUri: 'https://github.com/login/device',
    pollHandle: 'handle',
    intervalSecs: 0,
    expiresInSecs: 900,
    backend: backend ?? 'https://backend.example',
  );

  @override
  Future<AccountPoll> accountLoginPoll(
    String pollHandle,
    String backend,
  ) async {
    if (accountPollStatus == 'authorized') {
      accountUser = const AccountUser(login: 'octocat', accountId: '42');
      _signIn(accountUser!);
    }
    return AccountPoll(
      status: accountPollStatus,
      login: accountUser?.login,
      accountId: accountUser?.accountId,
    );
  }

  @override
  Future<WebLoginStart> accountWebLoginStart({
    required String redirectUri,
    String? backend,
  }) async {
    lastWebRedirectUri = redirectUri;
    return WebLoginStart(
      authorizeUrl: 'https://github.com/login/oauth/authorize?state=s',
      state: 'fake-state',
      codeVerifier: 'fake-verifier',
      backend: backend ?? 'https://backend.example',
    );
  }

  @override
  Future<AccountUser> accountWebLoginExchange({
    required String exchangeCode,
    required String codeVerifier,
    required String backend,
  }) async {
    accountUser = const AccountUser(login: 'octocat', accountId: '42');
    _signIn(accountUser!);
    return accountUser!;
  }

  @override
  Future<AccountUser?> accountCurrentUser() async => accountUser;

  @override
  Future<void> accountLogout() async {
    accountUser = null;
    // The token goes with it, so the mode derives back off `account`.
    _config = ConfigInfo(
      relay: _config.relay,
      hasKey: _config.hasKey,
      locale: _config.locale,
      mode: _config.relay == null ? 'unconfigured' : 'self_host',
    );
  }

  @override
  Future<List<AccountService>> accountServices() async => accountServiceList;

  @override
  Future<void> accountDeregisterService({
    required String device,
    required String kind,
    required String name,
  }) async {
    lastDeregistered = 'pcx:$device:$kind:$name';
    deregistered.add(lastDeregistered!);
    if (keepOnDeregister) return;
    _services.removeWhere(
      (s) => s.device == device && s.kind == kind && s.name == name,
    );
  }

  @override
  SessionSettings? appSessionSettings(String serviceKey, String threadId) =>
      sessionSettings['$serviceKey|$threadId'];

  @override
  Future<SessionSettings?> appSessionSettingsRefresh(
    String serviceKey,
    String threadId,
  ) async {
    sessionSettingsRefreshCalls.add(threadId);
    // Read when asked: an answer held by the gate is what the host had then.
    final settings = appSessionSettings(serviceKey, threadId);
    await sessionSettingsRefreshGate?.future;
    return settings;
  }

  @override
  Future<SessionSettings?> appDraftSessionSettings(
    String serviceKey,
    String? directory,
  ) async {
    draftSettingsProjects.add(directory);
    final settings =
        draftSettings['$serviceKey|${directory ?? ''}'] ??
        appSessionSettings(serviceKey, '');
    await draftSettingsGates[directory]?.future;
    return settings;
  }

  @override
  Future<void> appSetSessionConfig(
    String serviceKey,
    String threadId,
    String configId,
    String value,
  ) async {
    sessionConfigCalls.add((threadId, configId, value));
    final gate = sessionConfigGate;
    if (gate != null) {
      sessionConfigGate = null;
      await gate.future;
    }
    final err = sessionConfigError;
    if (err != null) {
      sessionConfigError = null;
      throw err;
    }
    final key = '$serviceKey|$threadId';
    final next = onSessionConfig?.call(configId, value, sessionSettings[key]);
    if (next != null) sessionSettings[key] = next;
  }

  @override
  Future<void> appSetSessionMode(
    String serviceKey,
    String threadId,
    String modeId,
  ) async => sessionConfigCalls.add((threadId, 'mode', modeId));

  @override
  Future<void> appConnect(String serviceKey, int localPort) async {
    appConnectCount++;
    await appConnectGate;
    _appConnected.add(serviceKey);
    _appEvents.putIfAbsent(serviceKey, StreamController<AppEvent>.broadcast);
  }

  @override
  bool appIsConnected(String serviceKey) => _appConnected.contains(serviceKey);

  @override
  Future<void> appDisconnect(String serviceKey) async {
    _appConnected.remove(serviceKey);
    await _appEvents.remove(serviceKey)?.close();
  }

  @override
  Future<bool> appProbe(String serviceKey) async {
    appProbeCalls.add(serviceKey);
    return _appConnected.contains(serviceKey) ||
        (reachable[serviceKey] ?? true);
  }

  @override
  Future<String?> appProbeReason(String serviceKey) async =>
      await appProbe(serviceKey)
      ? null
      : (probeReason[serviceKey] ?? 'probe: initialize timed out');

  @override
  Future<bool> apiProbe(String serviceKey) async {
    apiProbeCalls.add(serviceKey);
    return reachable[serviceKey] ?? true;
  }

  @override
  Future<bool> appProbeLocal(String localAddr) async =>
      reachableLocal[localAddr] ?? true;

  @override
  Future<bool> apiProbeLocal(String localAddr) async =>
      reachableLocal[localAddr] ?? true;

  @override
  Stream<AppEvent> appEvents(String serviceKey) => _appEvents
      .putIfAbsent(serviceKey, StreamController<AppEvent>.broadcast)
      .stream;

  @override
  Stream<LogLine> logEvents() => _logEvents.stream;

  @override
  Stream<RetryProgress> metaRetryEvents() => _retryEvents.stream;
}
