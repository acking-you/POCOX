part of '../bridge_api_rust.dart';

mixin _RustThreads implements BridgeApi {
  @override
  Future<AgentIdentity> appAgentIdentity(String serviceKey) async {
    final identity = await frb.appAgentIdentity(serviceKey: serviceKey);
    return AgentIdentity(
      provider: identity.provider,
      profileId: identity.profileId,
      name: identity.name,
    );
  }

  @override
  Future<ThreadHistory?> appHistoryCached(
    String serviceKey,
    String threadId,
  ) async {
    final h = await frb.appHistoryCached(
      serviceKey: serviceKey,
      threadId: threadId,
    );
    return h == null ? null : _history(h);
  }

  @override
  Future<bool> appHistorySyncPrepare(String serviceKey) =>
      frb.appHistorySyncPrepare(serviceKey: serviceKey);

  @override
  Future<void> appHistoryPrefetch(String serviceKey, String threadId) =>
      frb.appHistoryPrefetch(serviceKey: serviceKey, threadId: threadId);

  @override
  Future<void> appHistoryFocus(String serviceKey, String? threadId) =>
      frb.appHistoryFocus(serviceKey: serviceKey, threadId: threadId);

  @override
  Future<HistoryCacheStatus> historyCacheStatus() async {
    final status = await frb.historyCacheStatus();
    return HistoryCacheStatus(
      limitMb: status.limitMb,
      usedBytes: status.usedBytes.toInt(),
    );
  }

  @override
  Future<void> historyCacheSetLimit(int limitMb) =>
      frb.historyCacheSetLimit(limitMb: limitMb);

  @override
  AppCapabilities appCapabilities(String serviceKey) {
    final c = frb.appCapabilities(serviceKey: serviceKey);
    return AppCapabilities(
      provider: c.provider,
      fast: c.fast,
      permissionPresets: c.permissionPresets,
      guardian: c.guardian,
      rateLimits: c.rateLimits,
      takeover: c.takeover,
      externalWriterMonitor: c.externalWriterMonitor,
      localSessions: c.localSessions,
      planMode: c.planMode,
      protocol: c.protocol,
      providerName: c.providerName,
      profileId: c.profileId,
      negotiated: c.negotiated,
      generation: c.generation.toInt(),
      voice: c.voice,
      dictation: c.dictation,
      imageInput: c.imageInput,
      steer: c.steer,
      rename: c.rename,
      compact: c.compact,
      gitDiff: c.gitDiff,
      modelCatalog: c.modelCatalog,
      sessionConfig: c.sessionConfig,
      permissionOptions: c.permissionOptions,
      nativeMetadata: c.nativeMetadata,
      sessionReopen: c.sessionReopen,
      sessionList: c.sessionList,
      historyScope: c.historyScope,
      runningInventory: c.runningInventory,
      authRequired: c.authRequired,
      commands: c.commands,
      draftOptions: c.draftOptions,
      questionMultiple: c.questionMultiple,
      permissionFeedback: c.permissionFeedback,
    );
  }

  @override
  Future<List<String>> appRunningThreads(String serviceKey) =>
      frb.appRunningThreads(serviceKey: serviceKey);

  @override
  SessionSettings? appSessionSettings(String serviceKey, String threadId) =>
      _sessionSettings(
        frb.appSessionSettings(serviceKey: serviceKey, threadId: threadId),
      );

  @override
  Future<SessionSettings?> appSessionSettingsRefresh(
    String serviceKey,
    String threadId,
  ) async => _sessionSettings(
    await frb.appSessionSettingsRefresh(
      serviceKey: serviceKey,
      threadId: threadId,
    ),
  );

  @override
  Future<SessionSettings?> appDraftSessionSettings(
    String serviceKey,
    String? directory,
  ) async => _sessionSettings(
    await frb.appDraftSessionSettings(
      serviceKey: serviceKey,
      directory: directory,
    ),
  );

  @override
  Future<void> appSetSessionConfig(
    String serviceKey,
    String threadId,
    String configId,
    String value,
  ) => frb.appSetSessionConfig(
    serviceKey: serviceKey,
    threadId: threadId,
    configId: configId,
    value: value,
  );

  @override
  Future<void> appSetSessionMode(
    String serviceKey,
    String threadId,
    String modeId,
  ) => frb.appSetSessionMode(
    serviceKey: serviceKey,
    threadId: threadId,
    modeId: modeId,
  );

  @override
  Future<ThreadMeta?> appThreadMetadata(
    String serviceKey,
    String threadId,
  ) async {
    final t = await frb.appThreadMetadata(
      serviceKey: serviceKey,
      threadId: threadId,
    );
    return _threadMeta(t);
  }

  @override
  Future<List<ThreadMeta>> appThreadList(String serviceKey) async {
    final list = await frb.appThreadList(serviceKey: serviceKey);
    return list.map(_threadMeta).toList();
  }

  @override
  Future<String> appRealtimeRequest(
    String serviceKey,
    String method,
    String paramsJson,
  ) => frb.appRealtimeRequest(
    serviceKey: serviceKey,
    method: method,
    paramsJson: paramsJson,
  );

  @override
  Future<List<ModelInfo>> appModelList(String serviceKey) async =>
      (await frb.appModelList(serviceKey: serviceKey)).map(_model).toList();

  @override
  Future<List<ModelInfo>> appModelListForProject(
    String serviceKey,
    String? directory,
  ) async => (await frb.appModelListForProject(
    serviceKey: serviceKey,
    directory: directory,
  )).map(_model).toList();

  @override
  Future<String> appThreadStart(
    String serviceKey, {
    String? model,
    String? cwd,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? serviceTier,
    String? sandbox,
  }) => frb.appThreadStart(
    serviceKey: serviceKey,
    model: model,
    cwd: cwd,
    approvalPolicy: approvalPolicy,
    approvalsReviewer: approvalsReviewer,
    serviceTier: serviceTier,
    sandbox: sandbox,
  );

  @override
  Future<void> appThreadResume(String serviceKey, String threadId) =>
      frb.appThreadResume(serviceKey: serviceKey, threadId: threadId);

  @override
  Future<ThreadHistory> appThreadRead(
    String serviceKey,
    String threadId, {
    bool includeTurnPages = true,
  }) async {
    final h = await frb.appThreadRead(
      serviceKey: serviceKey,
      threadId: threadId,
      includeTurnPages: includeTurnPages,
    );
    return _history(h);
  }

  @override
  Future<TurnItemsPage> appThreadTurnPage(
    String serviceKey,
    String threadId,
    String turnId, {
    bool loadMore = false,
  }) async => _turnPage(
    await frb.appThreadTurnPage(
      serviceKey: serviceKey,
      threadId: threadId,
      turnId: turnId,
      loadMore: loadMore,
      deltaOnly: true,
    ),
  );

  @override
  Future<OlderPage> appThreadOlderPage(
    String serviceKey,
    String threadId,
  ) async {
    final page = await frb.appThreadOlderPage(
      serviceKey: serviceKey,
      threadId: threadId,
    );
    return OlderPage(
      items: page.items.map(_item).toList(),
      hasOlder: page.hasOlder,
    );
  }

  @override
  ThreadRuntimeConfig? appThreadRuntimeConfig(
    String serviceKey,
    String threadId,
  ) {
    final c = frb.appThreadRuntimeConfig(
      serviceKey: serviceKey,
      threadId: threadId,
    );
    if (c == null) return null;
    return ThreadRuntimeConfig(
      model: c.model,
      modelProvider: c.modelProvider,
      reasoningEffort: c.reasoningEffort,
      approvalPolicy: c.approvalPolicy,
      approvalsReviewer: c.approvalsReviewer,
      serviceTier: c.serviceTier,
      sandboxMode: c.sandboxMode,
      collaborationMode: c.collaborationMode,
      confirmedByUpdate: c.confirmedByUpdate,
    );
  }

  @override
  Future<String> appRateLimits(String serviceKey) =>
      frb.appRateLimits(serviceKey: serviceKey);

  @override
  Future<String> appGitDiff(String serviceKey, String cwd) =>
      frb.appGitDiff(serviceKey: serviceKey, cwd: cwd);

  @override
  Future<void> appCompact(String serviceKey, String threadId) =>
      frb.appCompact(serviceKey: serviceKey, threadId: threadId);

  @override
  Future<String?> appThreadSummary(String serviceKey, String threadId) =>
      frb.appThreadSummary(serviceKey: serviceKey, threadId: threadId);

  @override
  Future<void> appSetThreadName(
    String serviceKey,
    String threadId,
    String name,
  ) => frb.appSetThreadName(
    serviceKey: serviceKey,
    threadId: threadId,
    name: name,
  );

  @override
  Future<void> appTurnStart(
    String serviceKey,
    String threadId,
    String text, {
    List<String> images = const [],
    String? model,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? serviceTier,
    String? sandbox,
    String? collaborationMode,
    String? reasoningEffort,
    String? clientId,
  }) => frb.appTurnStart(
    serviceKey: serviceKey,
    threadId: threadId,
    text: text,
    images: images,
    model: model,
    approvalPolicy: approvalPolicy,
    approvalsReviewer: approvalsReviewer,
    serviceTier: serviceTier,
    sandbox: sandbox,
    collaborationMode: collaborationMode,
    reasoningEffort: reasoningEffort,
    clientId: clientId,
  );

  @override
  Future<String> appTurnSteer(
    String serviceKey,
    String threadId,
    String? turnId,
    String text, {
    List<String> images = const [],
  }) => frb.appTurnSteer(
    serviceKey: serviceKey,
    threadId: threadId,
    turnId: turnId,
    text: text,
    images: images,
  );

  @override
  Future<TurnSupplement> appTurnSupplement(
    String serviceKey,
    String threadId,
    String? turnId,
    String text, {
    List<String> images = const [],
    String? clientId,
  }) async {
    final outcome = await frb.appTurnSupplement(
      serviceKey: serviceKey,
      threadId: threadId,
      turnId: turnId,
      text: text,
      images: images,
      clientId: clientId,
    );
    // Only the two known outcomes mean anything; another is an unknown
    // fate, never "nothing was consumed".
    return switch (outcome.outcome) {
      'injected' => TurnSupplement(injected: true, turnId: outcome.turnId),
      'promptRequired' => const TurnSupplement(injected: false),
      final other => throw StateError('unexpected supplement outcome: $other'),
    };
  }

  @override
  Future<void> appTurnInterrupt(
    String serviceKey,
    String threadId, {
    String? turnId,
  }) => frb.appTurnInterrupt(
    serviceKey: serviceKey,
    threadId: threadId,
    turnId: turnId,
  );

  @override
  Future<void> appRespondApproval(
    String serviceKey,
    String requestId,
    String decision,
  ) => frb.appRespondApproval(
    serviceKey: serviceKey,
    requestId: requestId,
    decision: decision,
  );

  @override
  Future<void> appRespondUserInput(
    String serviceKey,
    String requestId,
    String answersJson,
  ) => frb.appRespondUserInput(
    serviceKey: serviceKey,
    requestId: requestId,
    answersJson: answersJson,
  );
}

SessionSettings? _sessionSettings(frb.SessionSettingsDto? s) {
  if (s == null) return null;
  return SessionSettings(
    configOptions: [
      for (final o in s.configOptions)
        SessionConfigOption(
          id: o.id,
          name: o.name,
          category: o.category,
          description: o.description,
          currentValue: o.currentValue,
          values: [
            for (final v in o.values)
              SessionConfigValue(
                value: v.value,
                name: v.name,
                group: v.group,
                description: v.description,
              ),
          ],
        ),
    ],
    currentMode: s.currentMode,
    modes: [
      for (final m in s.modes)
        SessionMode(id: m.id, name: m.name, description: m.description),
    ],
    usageUsed: s.usageUsed?.toInt(),
    usageSize: s.usageSize?.toInt(),
    running: s.running,
    cancelRequested: s.cancelRequested,
  );
}

ModelInfo _model(frb.ModelInfoDto m) => ModelInfo(
  id: m.id,
  displayName: m.displayName,
  description: m.description,
  supportedReasoningEfforts: m.supportedReasoningEfforts,
  defaultReasoningEffort: m.defaultReasoningEffort,
  supportedServiceTiers: m.supportedServiceTiers,
  defaultServiceTier: m.defaultServiceTier,
  isDefault: m.isDefault,
);

ThreadHistory _history(frb.ThreadHistoryDto h) => ThreadHistory(
  items: h.items.map(_item).toList(),
  running: h.running,
  activeTurnId: h.activeTurnId,
  historyEpoch: h.historyEpoch,
  branch: h.branch,
  cwd: h.cwd,
  tokensUsed: h.tokensUsed?.toInt(),
  contextWindow: h.contextWindow?.toInt(),
  collaborationMode: h.collaborationMode,
  reasoningEffort: h.reasoningEffort,
  model: h.model,
  modelProvider: h.modelProvider,
  approvalPolicy: h.approvalPolicy,
  approvalsReviewer: h.approvalsReviewer,
  serviceTier: h.serviceTier,
  sandboxMode: h.sandboxMode,
  configConfirmed: h.configConfirmed,
  hasOlder: h.hasOlder,
  firstTurnId: h.firstTurnId,
  turnPages: h.turnPages.map(_turnPage).toList(),
  turns: h.turns
      .map(
        (t) => TurnSummary(
          turnId: t.turnId,
          userText: t.userText,
          assistantText: t.assistantText,
          loaded: t.loaded,
        ),
      )
      .toList(),
);

ThreadItem _item(frb.ThreadItemDto i) => ThreadItem(
  id: i.id,
  itemType: i.itemType,
  title: i.title,
  text: i.text,
  images: i.images,
  turnId: i.turnId,
  turnCompletedAt: i.turnCompletedAt?.toInt(),
  turnDurationMs: i.turnDurationMs?.toInt(),
  questionsJson: i.questionsJson,
);

TurnItemsPage _turnPage(frb.TurnItemsPageDto page) => TurnItemsPage(
  turnId: page.turnId,
  items: page.items.map(_item).toList(),
  hasMore: page.hasMore,
);

ThreadMeta _threadMeta(frb.ThreadMetaDto t) => ThreadMeta(
  id: t.id,
  preview: t.preview,
  name: t.name,
  threadSource: t.threadSource,
  parentThreadId: t.parentThreadId,
  cwd: t.cwd,
  originUrl: t.originUrl,
  updatedAt: t.updatedAt.toInt(),
);
