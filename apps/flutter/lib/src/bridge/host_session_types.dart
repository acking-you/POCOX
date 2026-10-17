part of '../bridge_api.dart';

/// A process holding a session's rollout file open — a would-be force-takeover
/// target.
class Holder {
  /// Creates a holder.
  const Holder({required this.pid, required this.name});

  /// Operating-system process id.
  final int pid;

  /// Process image name (e.g. `codex.exe`).
  final String name;
}

/// One codex session discovered under the shared `CODEX_HOME`, annotated with
/// whether it is safe to resume.
class LocalSession {
  /// Creates a local session entry.
  const LocalSession({
    required this.threadId,
    this.cwd,
    required this.preview,
    this.name,
    this.status,
    this.source,
    this.parentThreadId,
    this.threadSource,
    required this.updatedAt,
    required this.turnState,
    required this.heldOpen,
    required this.safety,
    required this.allowsResume,
    required this.requiresTakeover,
  });

  /// Thread / conversation id.
  final String threadId;

  /// Working directory the session controls, when recorded.
  final String? cwd;

  /// Best-effort first-user-message preview.
  final String preview;

  /// User-set title, when the host's app-server listed one.
  final String? name;

  /// The host app-server's thread status (`notLoaded` / `idle` / `active` /
  /// `systemError`); null when no app-server answered.
  final String? status;

  /// A turn runs in the host's own app-server: resuming joins it.
  bool get runningOnHost => status == 'active';

  /// Originating client (`cli` / `vscode` / …), when recorded.
  final String? source;

  /// Explicit spawning parent and persisted classification.
  final String? parentThreadId;
  final String? threadSource;
  bool get isGuardian => threadSource == 'guardian_review';

  /// Last-modified time of the rollout, unix seconds.
  final int updatedAt;

  /// Most-recent-turn state (`empty`/`completed`/`aborted`/`incomplete`/
  /// `unknown`).
  final String turnState;

  /// Whether the rollout is currently held open by a live process.
  final bool heldOpen;

  /// Resume-safety tag (`resumable`/`resumableUnfinished`/`ownedRunning`/
  /// `ownedIdle`).
  final String safety;

  /// Whether the UI may offer a resume action: false while another process
  /// runs a turn (one the host's app-server runs is joined).
  final bool allowsResume;

  /// Whether resuming requires a force takeover (a live owner must be evicted
  /// first).
  final bool requiresTakeover;
}

/// One session's liveness detail, including the processes a force takeover
/// would terminate (POCOX's own app-server already excluded).
class SessionLiveness {
  /// Creates a liveness view.
  const SessionLiveness({
    required this.threadId,
    required this.turnState,
    required this.heldOpen,
    required this.safety,
    required this.allowsResume,
    required this.requiresTakeover,
    required this.holders,
  });

  /// Thread / conversation id.
  final String threadId;

  /// Most-recent-turn state tag.
  final String turnState;

  /// Whether the rollout is currently held open.
  final bool heldOpen;

  /// Resume-safety tag.
  final String safety;

  /// Whether the UI may offer a resume action.
  final bool allowsResume;

  /// Whether resuming requires a force takeover.
  final bool requiresTakeover;

  /// Processes a force takeover would attempt to terminate.
  final List<Holder> holders;
}

/// One full read-only transcript + ownership snapshot from the host's live
/// session follow stream.
class SessionFollowUpdate {
  /// Creates a live session snapshot.
  const SessionFollowUpdate({
    required this.liveness,
    required this.items,
    this.historyRevision,
  });

  /// Opaque revision when history is read through app-server pagination.
  final String? historyRevision;

  /// Current ownership and resume-safety state.
  final SessionLiveness liveness;

  /// Full materialised transcript at this rollout revision.
  final List<ThreadItem> items;
}

/// Outcome of a force-resume: which holders were killed / survived, and whether
/// the subsequent resume took.
class ForceResumeReport {
  /// Creates a force-resume report.
  const ForceResumeReport({
    required this.killed,
    required this.survived,
    required this.stillHeld,
    required this.resumed,
    this.resumeError,
  });

  /// Holders that were successfully terminated.
  final List<Holder> killed;

  /// Holders the kill could not reach.
  final List<Holder> survived;

  /// Whether the rollout is still held open after the attempt. A true value
  /// blocks the subsequent resume.
  final bool stillHeld;

  /// Whether the subsequent `thread/resume` succeeded.
  final bool resumed;

  /// The resume error message, when [resumed] is false.
  final String? resumeError;
}

/// Per-thread session config persisted on the host (model / reasoning effort /
/// permission mode / plan mode). Every field is nullable: null means "no stored
/// preference", so the UI falls back to its own default.
class ThreadConfig {
  /// Creates a thread config.
  const ThreadConfig({
    this.model,
    this.reasoningEffort,
    this.permissionMode,
    this.serviceTier,
    this.planMode,
  });

  /// Selected model id, when pinned for this thread.
  final String? model;

  /// Reasoning-effort tag (`minimal`/`low`/`medium`/`high`), when set.
  final String? reasoningEffort;

  /// Permission / approval mode tag, when set.
  final String? permissionMode;

  /// Requested service tier (`priority` or explicit `default`).
  final String? serviceTier;

  /// Whether plan mode is on for this thread, when set.
  final bool? planMode;

  /// Whether every field is unset (no stored preference at all).
  bool get isEmpty =>
      model == null &&
      reasoningEffort == null &&
      permissionMode == null &&
      serviceTier == null &&
      planMode == null;

  /// A copy with the given fields overridden.
  ThreadConfig copyWith({
    String? model,
    String? reasoningEffort,
    String? permissionMode,
    String? serviceTier,
    bool? planMode,
  }) => ThreadConfig(
    model: model ?? this.model,
    reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    permissionMode: permissionMode ?? this.permissionMode,
    serviceTier: serviceTier ?? this.serviceTier,
    planMode: planMode ?? this.planMode,
  );
}

/// A host's project-folder configuration: the roots the remote folder browser
/// is confined to, and the default project new conversations open in. Both are
/// host-side (shared to every device via the meta tunnel) so a phone starting a
/// new session sees the same folders the desktop offers.
class ProjectConfig {
  /// Creates a project config.
  const ProjectConfig({this.projectRoots = const [], this.defaultProject});

  /// Absolute host paths the user configured as project roots.
  final List<String> projectRoots;

  /// Absolute host path new conversations default their cwd to (null = the
  /// codex default). A configured root, or a folder within one.
  final String? defaultProject;

  /// Whether any project roots are configured (gates the tree browser).
  bool get hasRoots => projectRoots.isNotEmpty;
}

/// One browsable child directory of a host folder, from [BridgeApi.metaListDir].
class HostDirEntry {
  /// Creates a directory entry.
  const HostDirEntry({
    required this.name,
    required this.path,
    this.isGitRepo = false,
  });

  /// The directory's own name (final path component).
  final String name;

  /// Absolute host path — browse into it, or use it as a session's cwd.
  final String path;

  /// Whether the directory is a git repository (a project hint).
  final bool isGitRepo;
}

/// One file in a host directory, from [BridgeApi.metaListFiles].
class HostFileEntry {
  /// Creates a file entry.
  const HostFileEntry({
    required this.name,
    required this.path,
    required this.size,
    required this.mtime,
  });

  /// The file's own name (final path component).
  final String name;

  /// Absolute host path.
  final String path;

  /// Size in bytes.
  final int size;

  /// Last-modified time in unix seconds (0 when unavailable).
  final int mtime;
}

/// Bounded file bytes and the original file size.
class FilePreviewData {
  const FilePreviewData({required this.bytes, required this.totalSize});
  final Uint8List bytes;
  final int totalSize;
  bool get truncated => totalSize > bytes.length;
}
