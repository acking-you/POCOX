part of '../../fake_bridge_api.dart';

mixin _FakeThreads on _FakeBridgeState {
  @override
  Future<ThreadMeta?> appThreadMetadata(
    String serviceKey,
    String threadId,
  ) async {
    threadMetadataCalls.add(serviceKey);
    // Mirrors the real bridge: native thread metadata exists only for the
    // Codex app-server and is refused for every other protocol.
    if (sessionProtocolOf(serviceKey) != SessionProtocol.codexAppServer) {
      throw StateError('thread metadata is not available for this service');
    }
    for (final thread in appThreads) {
      if (thread.id == threadId) return thread;
    }
    return null;
  }

  @override
  Future<List<ThreadMeta>> appThreadList(String serviceKey) async {
    if (threadListGate != null) await threadListGate;
    if (disconnectOnThreadList) {
      _appConnected.remove(serviceKey);
      throw StateError(
        'request `thread/list` timed out; app-server connection closed',
      );
    }
    if (failNextThreadList) {
      failNextThreadList = false;
      throw StateError('Trying to work with closed connection');
    }
    return List.unmodifiable(appThreads);
  }

  @override
  Future<String> appRateLimits(String serviceKey) async => rateLimitsJson;

  @override
  Future<String> appGitDiff(String serviceKey, String threadId) async {
    // Answers with the tree as it was when asked, however late it arrives.
    final text = gitDiffText;
    final gate = gitDiffGate;
    if (gate != null) await gate.future;
    return text;
  }

  @override
  Future<void> appCompact(String serviceKey, String threadId) async =>
      compacted = true;

  @override
  Future<void> appSetThreadName(
    String serviceKey,
    String threadId,
    String name,
  ) async {
    // Capture both switches before the await: they describe THIS call, and a
    // second call may arrive (and reset them) while this one is parked.
    final failThis = failSetThreadName || failNextSetThreadName;
    failNextSetThreadName = false;
    final gate = renameGate;
    if (gate != null) {
      renameGate = null;
      await gate.future;
    }
    if (failThis) throw Exception('rename refused');
    setNames[threadId] = name;
    final i = appThreads.indexWhere((t) => t.id == threadId);
    if (i >= 0) {
      appThreads[i] = appThreads[i].withName(name.isEmpty ? null : name);
    }
  }

  @override
  Future<String?> appThreadSummary(String serviceKey, String threadId) async {
    summaryCalls.add(threadId);
    final gate = summaryGate;
    if (gate != null) await gate.future;
    return summaries[threadId];
  }

  @override
  Future<List<ModelInfo>> appModelListForProject(
    String serviceKey,
    String? directory,
  ) async {
    modelListProjects.add(directory);
    final listed = projectModelLists['$serviceKey|${directory ?? ''}'];
    await projectModelListGates[directory]?.future;
    return listed ?? await appModelList(serviceKey);
  }

  @override
  Future<List<ModelInfo>> appModelList(String serviceKey) async {
    modelListServices.add(serviceKey);
    // Read when asked, like the bridge's connection catalog: an answer held
    // by the gate still reports the list of the host it was asked of.
    final listed = modelLists[serviceKey];
    final gate = modelListGate;
    await gate?.future;
    if (listed != null) return listed;
    return emptyModelList
        ? const []
        : const [
            ModelInfo(
              id: 'gpt-5.5',
              displayName: 'GPT-5.5',
              description: 'default',
              supportedReasoningEfforts: ['low', 'medium', 'high', 'xhigh'],
              defaultReasoningEffort: 'medium',
            ),
            ModelInfo(
              id: 'gpt-5',
              displayName: 'GPT-5',
              description: '',
              supportedReasoningEfforts: ['minimal', 'low', 'medium', 'high'],
              defaultReasoningEffort: 'medium',
            ),
          ];
  }

  @override
  Future<String> appThreadStart(
    String serviceKey, {
    String? model,
    String? cwd,
    String? approvalPolicy,
    String? approvalsReviewer,
    String? serviceTier,
    String? sandbox,
  }) async {
    lastModel = model;
    lastCwd = cwd;
    lastApproval = approvalPolicy;
    lastApprovalsReviewer = approvalsReviewer;
    lastServiceTier = serviceTier;
    lastSandbox = sandbox;
    threadStartCalls.add(serviceKey);
    final resultIndex = threadStartResults.length;
    threadStartResults.add(null);
    final gate = threadStartGate;
    if (gate != null) {
      threadStartGate = null;
      await gate.future;
    }
    final error = threadStartError;
    if (error != null) {
      threadStartError = null;
      throw error;
    }
    final id = 'thread-${_threadSeq++}';
    threadStartResults[resultIndex] = id;
    final seeded = newSessionSettings;
    if (seeded != null) sessionSettings['$serviceKey|$id'] = seeded;
    appThreads.insert(
      0,
      // A host with a default project creates a folder-less session there.
      ThreadMeta(
        id: id,
        preview: '',
        cwd: cwd ?? threadStartDefaultCwd ?? '',
        updatedAt: 0,
      ),
    );
    return id;
  }

  @override
  Future<String> appRealtimeRequest(
    String serviceKey,
    String method,
    String paramsJson,
  ) async => '{}';

  @override
  Future<void> appThreadResume(String serviceKey, String threadId) async {
    if (appThreadResumeError != null) throw appThreadResumeError!;
    lastResumed = threadId;
    final pending = pendingResumes[threadId];
    if (pending != null && pending.isNotEmpty) await pending.removeAt(0);
  }

  @override
  Future<ThreadHistory> appThreadRead(
    String serviceKey,
    String threadId, {
    bool includeTurnPages = true,
  }) async {
    threadReads.add(threadId);
    threadReadIncludesPages.add(includeTurnPages);
    final pending = pendingReads[threadId];
    if (pending != null && pending.isNotEmpty) return await pending.removeAt(0);
    return readResult;
  }

  @override
  Future<OlderPage> appThreadOlderPage(
    String serviceKey,
    String threadId,
  ) async {
    olderPageCalls++;
    if (pendingOlderPages[threadId] case final response?) return response;
    if (olderPages.isEmpty) {
      return const OlderPage(items: [], hasOlder: false);
    }
    final items = olderPages.removeLast();
    return OlderPage(items: items, hasOlder: olderPages.isNotEmpty);
  }

  @override
  Future<TurnItemsPage> appThreadTurnPage(
    String serviceKey,
    String threadId,
    String turnId, {
    bool loadMore = false,
  }) async {
    final pages = turnPages[turnId];
    if (pages != null && pages.isNotEmpty) {
      turnItemCalls.add(turnId);
      return pages.removeAt(0);
    }
    return TurnItemsPage(
      turnId: turnId,
      items: await _turnItems(turnId),
      hasMore: false,
    );
  }

  Future<List<ThreadItem>> _turnItems(String turnId) async {
    turnItemCalls.add(turnId);
    if (pendingTurnItems[turnId] case final response?) return response;
    return turnItems[turnId] ?? const [];
  }

  @override
  ThreadRuntimeConfig? appThreadRuntimeConfig(
    String serviceKey,
    String threadId,
  ) => runtimeConfig;

  /// Echoes a streamed agent reply so widget tests can assert rendering.
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
  }) async {
    turnStartCount++;
    turnStartCalls.add((serviceKey, threadId, text, images));
    final refusal = turnStartError;
    if (refusal != null) {
      turnStartError = null;
      throw refusal;
    }
    lastTurnThread = threadId;
    lastTurnModel = model;
    lastTurnText = text;
    lastTurnImages = images;
    lastApproval = approvalPolicy;
    lastApprovalsReviewer = approvalsReviewer;
    lastServiceTier = serviceTier;
    lastSandbox = sandbox;
    lastCollaborationMode = collaborationMode;
    lastReasoningEffort = reasoningEffort;
    final lost = turnStartLostAnswer;
    if (lost != null) {
      turnStartLostAnswer = null;
      throw lost;
    }
    if (turnStartGate != null) await turnStartGate!.future;
    final c = _appEvents[serviceKey];
    if (c == null) return;
    if (!announceTurnStart) return;
    c.add(AppEvent(kind: 'turn/started', threadId: threadId, raw: '{}'));
    // Leave the turn running with no output when the test wants to drive the
    // reply/completion itself (Esc state-machine + queue tests).
    if (!autoCompleteTurn) return;
    c.add(
      AppEvent(
        kind: 'item/agentMessage/delta',
        threadId: threadId,
        itemId: 'a1',
        itemType: 'agentMessage',
        text: 'echo: $text',
        raw: '{}',
      ),
    );
    c.add(AppEvent(kind: 'turn/completed', threadId: threadId, raw: '{}'));
  }

  @override
  Future<String> appTurnSteer(
    String serviceKey,
    String threadId,
    String? turnId,
    String text, {
    List<String> images = const [],
  }) async {
    if (steerError != null) throw StateError(steerError!);
    lastSteerText = text;
    lastSteerImages = images;
    lastSteerTurnId = turnId;
    if (steerGate != null) await steerGate!.future;
    return turnId ?? resolvedSteerTurnId;
  }

  @override
  Future<TurnSupplement> appTurnSupplement(
    String serviceKey,
    String threadId,
    String? turnId,
    String text, {
    List<String> images = const [],
  }) async {
    supplementCalls.add((threadId, turnId, text, images));
    final gate = supplementGate;
    if (gate != null) {
      supplementGate = null;
      await gate.future;
    }
    final error = supplementError;
    if (error != null) {
      supplementError = null;
      throw error;
    }
    if (!isAcpKey(serviceKey)) {
      // Native Codex: the bridge's supplement is `turn/steer` (the
      // `SessionEngine::turn_supplement` default), with its failures, its
      // accepted turn and never "no turn running".
      final turn = await appTurnSteer(
        serviceKey,
        threadId,
        turnId,
        text,
        images: images,
      );
      return TurnSupplement(injected: true, turnId: turn);
    }
    return supplementInjects
        ? TurnSupplement(injected: true, turnId: turnId ?? resolvedSteerTurnId)
        : const TurnSupplement(injected: false);
  }

  @override
  Future<void> appTurnInterrupt(
    String serviceKey,
    String threadId, {
    String? turnId,
  }) async {
    interrupted = true;
    lastInterruptTurnId = turnId;
  }

  @override
  Future<void> appRespondApproval(
    String serviceKey,
    String requestId,
    String decision,
  ) async {
    lastApprovalRequestId = requestId;
    lastApprovalDecision = decision;
  }

  @override
  Future<void> appRespondUserInput(
    String serviceKey,
    String requestId,
    String answersJson,
  ) async => lastUserInputAnswers = answersJson;

  @override
  Future<List<LocalSession>> appLocalSessions() async {
    localSessionCalls++;
    if (localSessionError != null) throw localSessionError!;
    return localSessions;
  }

  @override
  Future<SessionLiveness> appSessionLiveness(String threadId) async =>
      liveness[threadId] ??
      SessionLiveness(
        threadId: threadId,
        turnState: 'completed',
        heldOpen: false,
        safety: 'resumable',
        allowsResume: true,
        requiresTakeover: false,
        holders: const [],
      );
}
