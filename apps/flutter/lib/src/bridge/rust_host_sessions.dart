part of '../bridge_api_rust.dart';

mixin _RustHostSessions implements BridgeApi {
  @override
  Future<SessionAccess> appSessionOpen(
    String serviceKey,
    String threadId,
  ) async => _access(
    await frb.appSessionOpen(serviceKey: serviceKey, threadId: threadId),
  );

  @override
  Future<SessionAccess> appSessionAccess(
    String serviceKey,
    String threadId,
  ) async => _access(
    await frb.appSessionAccess(serviceKey: serviceKey, threadId: threadId),
  );

  @override
  Future<SessionAccess> appSessionRelease(
    String serviceKey,
    SessionAccess snapshot,
  ) async => _access(
    await frb.appSessionRelease(
      serviceKey: serviceKey,
      snapshot: _accessDto(snapshot),
    ),
  );

  @override
  Future<List<AgentCommand>> appCommandListForProject(
    String serviceKey,
    String? directory,
  ) async => [
    for (final c in await frb.appCommandListForProject(
      serviceKey: serviceKey,
      directory: directory,
    ))
      _command(c),
  ];

  @override
  Future<NativeSessionList> appNativeSessions(
    String provider, {
    String? cursor,
    String? sourceId,
  }) async {
    final v = await frb.appNativeSessions(
      provider: provider,
      cursor: cursor,
      sourceId: sourceId,
    );
    return NativeSessionList(
      sourceId: v.sourceId,
      location: v.location,
      sessions: v.sessions.map(_localSession).toList(),
      nextCursor: v.nextCursor,
    );
  }

  @override
  Future<NativeSessionPage> appNativeSessionPage(
    String provider,
    String threadId, {
    String? before,
    String? sourceId,
  }) async {
    final v = await frb.appNativeSessionPage(
      provider: provider,
      threadId: threadId,
      before: before,
      sourceId: sourceId,
    );
    return NativeSessionPage(
      sourceId: v.sourceId,
      generation: v.generation,
      revision: v.revision,
      items: v.items.map(_item).toList(),
      nextBefore: v.nextBefore,
      truncated: v.truncated,
    );
  }

  @override
  Future<NativeSessionRevision> appNativeSessionRevision(
    String provider,
    String threadId, {
    String? sourceId,
  }) async {
    final v = await frb.appNativeSessionRevision(
      provider: provider,
      threadId: threadId,
      sourceId: sourceId,
    );
    return NativeSessionRevision(
      sourceId: v.sourceId,
      generation: v.generation,
      revision: v.revision,
      liveness: _liveness(v.liveness),
    );
  }

  // --- Local session takeover ---

  @override
  Future<List<LocalSession>> appLocalSessions() async {
    final list = await frb.appLocalSessions();
    return list.map(_localSession).toList();
  }

  @override
  Future<SessionLiveness> appSessionLiveness(String threadId) async {
    final v = await frb.appSessionLiveness(threadId: threadId);
    return _liveness(v);
  }

  @override
  Future<ForceResumeReport> appForceResume(
    String serviceKey,
    String threadId,
  ) async {
    final r = await frb.appForceResume(
      serviceKey: serviceKey,
      threadId: threadId,
    );
    return _resumeReport(r);
  }

  @override
  Future<List<ThreadItem>> appLocalSessionTranscript(String threadId) async {
    final items = await frb.appLocalSessionTranscript(threadId: threadId);
    return items.map(_item).toList();
  }

  // --- Remote (meta service) sessions + per-thread config ---

  @override
  Future<List<LocalSession>> metaSessions(
    String serviceKey, {
    bool runningOnly = false,
  }) async {
    final list = await frb.metaSessions(
      serviceKey: serviceKey,
      runningOnly: runningOnly,
    );
    return list.map(_localSession).toList();
  }

  @override
  Future<SessionLiveness> metaSessionLiveness(
    String serviceKey,
    String threadId,
  ) async {
    final v = await frb.metaSessionLiveness(
      serviceKey: serviceKey,
      threadId: threadId,
    );
    return _liveness(v);
  }

  @override
  Stream<SessionFollowUpdate> metaSessionEvents(
    String serviceKey,
    String threadId,
  ) => frb
      .metaSessionEvents(serviceKey: serviceKey, threadId: threadId)
      .map(
        (update) => SessionFollowUpdate(
          historyRevision: update.historyRevision,
          liveness: _liveness(update.liveness),
          items: update.items
              .map(
                (item) => ThreadItem(
                  id: item.id,
                  itemType: item.itemType,
                  title: item.title,
                  text: item.text,
                  images: item.images,
                  turnId: item.turnId,
                  turnCompletedAt: item.turnCompletedAt?.toInt(),
                  turnDurationMs: item.turnDurationMs?.toInt(),
                ),
              )
              .toList(),
        ),
      );

  @override
  Future<List<ThreadItem>> metaSessionTranscript(
    String serviceKey,
    String threadId,
  ) async {
    final items = await frb.metaSessionTranscript(
      serviceKey: serviceKey,
      threadId: threadId,
    );
    return items.map(_item).toList();
  }

  @override
  Future<ForceResumeReport> metaForceResume(
    String serviceKey,
    String threadId,
  ) async {
    final r = await frb.metaForceResume(
      serviceKey: serviceKey,
      threadId: threadId,
    );
    return _resumeReport(r);
  }

  @override
  String metaUploadContext() => frb.metaUploadContext();

  @override
  Future<String> metaUploadFileScoped(
    String serviceKey,
    String fileName,
    Uint8List bytes,
    String context,
  ) => frb.metaUploadFileScoped(
    serviceKey: serviceKey,
    fileName: fileName,
    bytes: bytes,
    context: context,
  );

  @override
  Future<ThreadConfig> metaThreadConfigGet(
    String serviceKey,
    String threadId,
  ) async {
    final c = await frb.metaThreadConfigGet(
      serviceKey: serviceKey,
      threadId: threadId,
    );
    return _threadConfig(c);
  }

  @override
  Future<ThreadConfig> metaThreadConfigSet(
    String serviceKey,
    String threadId,
    ThreadConfig config,
  ) async {
    final c = await frb.metaThreadConfigSet(
      serviceKey: serviceKey,
      threadId: threadId,
      config: frb.ThreadConfigDto(
        model: config.model,
        reasoningEffort: config.reasoningEffort,
        permissionMode: config.permissionMode,
        serviceTier: config.serviceTier,
        planMode: config.planMode,
      ),
    );
    return _threadConfig(c);
  }

  @override
  Future<ProjectConfig> metaProjectConfig(String serviceKey) async =>
      _projectConfig(await frb.metaProjectConfig(serviceKey: serviceKey));

  @override
  Future<List<HostDirEntry>> metaListDir(String serviceKey, String path) async {
    final entries = await frb.metaListDir(serviceKey: serviceKey, path: path);
    return entries
        .map(
          (e) =>
              HostDirEntry(name: e.name, path: e.path, isGitRepo: e.isGitRepo),
        )
        .toList(growable: false);
  }

  @override
  Future<List<HostFileEntry>> metaListFiles(
    String serviceKey,
    String path,
  ) async {
    final files = await frb.metaListFiles(serviceKey: serviceKey, path: path);
    return files
        .map(
          (e) => HostFileEntry(
            name: e.name,
            path: e.path,
            size: e.size.toInt(),
            mtime: e.mtime.toInt(),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<Uint8List> metaReadFile(String serviceKey, String path) =>
      frb.metaReadFile(serviceKey: serviceKey, path: path);

  @override
  Future<bool> metaHostIsLocal(String serviceKey) =>
      frb.metaHostIsLocal(serviceKey: serviceKey);

  @override
  Future<FilePreviewData> metaFilePreview(
    String serviceKey,
    String? threadId,
    String href,
  ) async {
    final result = await frb.metaFilePreview(
      serviceKey: serviceKey,
      threadId: threadId,
      href: href,
    );
    return FilePreviewData(
      bytes: result.bytes,
      totalSize: result.totalSize.toInt(),
    );
  }

  @override
  Future<void> metaFileDownload(
    String serviceKey,
    String? threadId,
    String href,
    String destination,
  ) => frb.metaFileDownload(
    serviceKey: serviceKey,
    threadId: threadId,
    href: href,
    destination: destination,
  );

  @override
  Future<Uint8List> metaReadThreadImage(
    String serviceKey,
    String threadId,
    String path,
  ) => frb.metaReadThreadImage(
    serviceKey: serviceKey,
    threadId: threadId,
    path: path,
  );

  @override
  Future<String> metaWriteFile(
    String serviceKey,
    String dir,
    String fileName,
    Uint8List bytes,
  ) => frb.metaWriteFile(
    serviceKey: serviceKey,
    dir: dir,
    fileName: fileName,
    bytes: bytes,
  );
}

AgentCommand _command(frb.AgentCommandDto c) => AgentCommand(
  name: c.name,
  description: c.description,
  source: c.source,
  hints: c.hints,
);

ThreadConfig _threadConfig(frb.ThreadConfigDto c) => ThreadConfig(
  model: c.model,
  reasoningEffort: c.reasoningEffort,
  permissionMode: c.permissionMode,
  serviceTier: c.serviceTier,
  planMode: c.planMode,
);

ProjectConfig _projectConfig(frb.ProjectConfigDto c) => ProjectConfig(
  projectRoots: c.projectRoots,
  defaultProject: c.defaultProject,
);

LocalSession _localSession(frb.LocalSessionDto s) => LocalSession(
  threadId: s.threadId,
  cwd: s.cwd,
  preview: s.preview,
  name: s.name,
  status: s.status,
  source: s.source,
  parentThreadId: s.parentThreadId,
  threadSource: s.threadSource,
  updatedAt: s.updatedAt.toInt(),
  turnState: s.turnState,
  heldOpen: s.heldOpen,
  safety: s.safety,
  allowsResume: s.allowsResume,
  requiresTakeover: s.requiresTakeover,
);

SessionLiveness _liveness(frb.SessionLivenessDto v) => SessionLiveness(
  threadId: v.threadId,
  turnState: v.turnState,
  heldOpen: v.heldOpen,
  safety: v.safety,
  allowsResume: v.allowsResume,
  requiresTakeover: v.requiresTakeover,
  holders: v.holders.map(_holder).toList(),
);

Holder _holder(frb.HolderDto h) => Holder(pid: h.pid.toInt(), name: h.name);

ForceResumeReport _resumeReport(frb.ForceResumeReportDto r) =>
    ForceResumeReport(
      killed: r.killed.map(_holder).toList(),
      survived: r.survived.map(_holder).toList(),
      stillHeld: r.stillHeld,
      resumed: r.resumed,
      resumeError: r.resumeError,
    );

SessionAccess _access(frb.SessionAccessDto v) => SessionAccess(
  sessionId: v.sessionId,
  hostId: v.hostId,
  generation: v.generation.toInt(),
  sourceGeneration: v.sourceGeneration,
  provider: v.provider,
  mode: v.mode,
  writer: v.writer,
  turn: v.turn,
  exclusion: v.exclusion,
  reason: v.reason,
  detail: v.detail,
  holder: v.holder == null
      ? null
      : AccessHolder(
          client: v.holder!.client,
          pid: v.holder!.pid,
          startedAt: v.holder!.startedAt?.toInt(),
          hostName: v.holder!.hostName,
          serviceKey: v.holder!.serviceKey,
        ),
  canRelease: v.canRelease,
  recheck: v.recheck,
);

frb.SessionAccessDto _accessDto(SessionAccess v) => frb.SessionAccessDto(
  sessionId: v.sessionId,
  hostId: v.hostId,
  generation: BigInt.from(v.generation),
  sourceGeneration: v.sourceGeneration,
  provider: v.provider,
  mode: v.mode,
  writer: v.writer,
  turn: v.turn,
  exclusion: v.exclusion,
  reason: v.reason,
  detail: v.detail,
  holder: v.holder == null
      ? null
      : frb.AccessHolderDto(
          client: v.holder!.client,
          pid: v.holder!.pid,
          startedAt: v.holder!.startedAt == null
              ? null
              : PlatformInt64Util.from(v.holder!.startedAt!),
          hostName: v.holder!.hostName,
          serviceKey: v.holder!.serviceKey,
        ),
  canRelease: v.canRelease,
  recheck: v.recheck,
);
