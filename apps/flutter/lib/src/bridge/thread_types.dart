part of '../bridge_api.dart';

/// A live app-server event (one JSON-RPC notification), flattened for the UI.
class AppEvent {
  /// Creates an app event.
  const AppEvent({
    required this.kind,
    this.threadId,
    this.itemId,
    this.itemType,
    this.title,
    this.text,
    this.diff,
    this.images = const [],
    this.requestId,
    this.turnId,
    this.sender,
    this.textIsSnapshot = false,
    this.running,
    required this.raw,
  });

  /// JSON-RPC method, e.g. `turn/started`, `item/agentMessage/delta`,
  /// `turn/completed`.
  final String kind;

  /// Thread id the event belongs to, when present.
  final String? threadId;

  /// Item id the event refers to, when present.
  final String? itemId;

  /// Item type tag when this event carries an item (`agentMessage`,
  /// `commandExecution`, `webSearch`, `mcpToolCall`, `fileChange`,
  /// `reasoning`, …); `null` for turn-level events.
  final String? itemType;

  /// One-line summary for tool/activity items (command, query, tool name…).
  final String? title;

  /// Text payload (a streaming delta or an item's body/detail).
  final String? text;

  /// File changes parsed by the native projection.
  final DiffModel? diff;

  /// Image URLs attached to a `userMessage` item: `data:image/...` URLs
  /// render inline; a host-local path renders as a filename chip. Empty for
  /// every other event.
  final List<String> images;

  /// Token to answer a server approval request via [BridgeApi.appRespondApproval].
  final String? requestId;

  /// Full params JSON for fields not modelled above.
  final String raw;

  /// Metadata decoded by the native event projection.
  final String? turnId;
  final String? sender;
  final bool textIsSnapshot;
  final bool? running;
}

/// Which events of its conversation a live feed carries.
enum EventTopic {
  /// Everything.
  all,

  /// Turn starts, ends and thread status: what the session list shows.
  activity,

  /// Realtime voice signalling, plus turn starts a dictation must refuse.
  realtime,
}

/// A live event stream whose conversation can move in place.
abstract interface class AppEventFeed {
  /// The feed's events; listen once.
  Stream<AppEvent> get events;

  /// Narrow the running stream to [threadId] (null: every conversation)
  /// without resubscribing, so no event falls between two subscriptions.
  void follow(String? threadId);
}

/// A bounded log view queried from Rust, with native retention statistics.
class LogView {
  const LogView({required this.lines, required this.total, this.diskLost = 0});
  final List<LogLine> lines;
  final int total;
  final int diskLost;
}

/// One captured runtime log line for the in-app log viewer.
class LogLine {
  /// Creates a log line.
  const LogLine({
    required this.level,
    required this.target,
    required this.message,
    required this.timestampMs,
  });

  /// `TRACE` / `DEBUG` / `INFO` / `WARN` / `ERROR`.
  final String level;

  /// Event target (crate / module path).
  final String target;

  /// The rendered message plus any structured fields.
  final String message;

  /// Capture time, unix milliseconds.
  final int timestampMs;
}

/// One in-flight retry of a host meta request.
class RetryProgress {
  /// Creates a retry progress tick.
  const RetryProgress({required this.attempt, required this.maxAttempts});

  /// Attempts made so far (1-based).
  final int attempt;

  /// Total attempt budget before the request gives up.
  final int maxAttempts;
}

/// Summary metadata for one app-server thread.
class ThreadMeta {
  /// Creates thread metadata.
  const ThreadMeta({
    required this.id,
    required this.preview,
    required this.cwd,
    required this.updatedAt,
    this.name,
    this.threadSource,
    this.parentThreadId,
    this.originUrl,
  });

  /// Thread id.
  final String id;

  /// Preview (usually the first user message).
  final String preview;

  /// User-set title, or null when the conversation was never renamed.
  final String? name;

  /// Persisted app-owned classification, independent of the editable title.
  final String? threadSource;

  /// Explicit spawning parent, independent of project and session titles.
  final String? parentThreadId;

  bool get isGuardian => threadSource == 'guardian_review';

  /// True for conversations created through the live voice entry point.
  bool get isVoice => threadSource == 'pocox-voice';

  /// Working directory — the project this thread controls.
  final String cwd;

  /// The repository's remote, when the agent reports one: what ties a managed
  /// worktree to the checkout it came from.
  final String? originUrl;

  /// Unix seconds of last update.
  final int updatedAt;

  /// The name the user gave this conversation, if any — trimmed, and null
  /// rather than empty so callers can `??` straight through to the preview.
  String? get title {
    final n = name?.trim();
    return (n == null || n.isEmpty) ? null : n;
  }

  /// Copy with [name] replaced. Used to reflect a rename locally without
  /// waiting for the next `thread/list`.
  ThreadMeta withName(String? name) => ThreadMeta(
    id: id,
    preview: preview,
    name: name,
    threadSource: threadSource,
    parentThreadId: parentThreadId,
    cwd: cwd,
    originUrl: originUrl,
    updatedAt: updatedAt,
  );
}

/// A thread's recovered history plus whether a turn is still running, and the
/// metadata the status bar / git chip seed from on open.
class ThreadHistory {
  /// Creates a thread history.
  const ThreadHistory({
    required this.items,
    required this.running,
    this.activeTurnId,
    this.historyEpoch,
    this.branch,
    this.cwd,
    this.tokensUsed,
    this.contextWindow,
    this.collaborationMode,
    this.reasoningEffort,
    this.model,
    this.modelProvider,
    this.approvalPolicy,
    this.approvalsReviewer,
    this.serviceTier,
    this.sandboxMode,
    this.configConfirmed = false,
    this.hasOlder = false,
    this.turns = const [],
    this.firstTurnId,
    this.turnPages = const [],
  });

  /// Conversation items, oldest first.
  final List<ThreadItem> items;

  /// Whether the most recent turn is still in progress.
  final bool running;

  /// Identity from the same server snapshot that established [running].
  final String? activeTurnId;

  /// Source history generation; replacement invalidates retained windows.
  final String? historyEpoch;

  /// Current git branch of the thread's cwd, if it's a repo.
  final String? branch;

  /// The thread's resolved working directory (for git diff / status).
  final String? cwd;

  /// Tokens currently occupying the model context window.
  final int? tokensUsed;

  /// The model's context-window size in tokens.
  final int? contextWindow;

  /// The thread's sticky collaboration mode (`plan` / `default`), so the UI
  /// plan toggle reflects the server's real state instead of guessing.
  final String? collaborationMode;

  /// The thread's current reasoning effort (`low`/`medium`/`high`), so the UI
  /// can display the "thinking level" the thread runs with. Sourced from the
  /// thread/resume response (thread/read doesn't expose it).
  final String? reasoningEffort;

  /// The effective model id the thread runs with, per the server (from the
  /// start/resume response, kept fresh by `thread/settings/updated`). Null
  /// when the server never reported it (older servers).
  final String? model;

  /// Provider of the effective model (e.g. `openai`), when reported.
  final String? modelProvider;

  /// The effective approval policy (`untrusted`/`on-failure`/`on-request`/
  /// `never`/`granular`), when reported.
  final String? approvalPolicy;

  /// Effective reviewer (`user` or `auto_review`).
  final String? approvalsReviewer;

  /// Effective service tier.
  final String? serviceTier;

  /// The effective sandbox mode (`read-only`/`workspace-write`/
  /// `danger-full-access`/`external-sandbox`), when reported.
  final String? sandboxMode;

  /// Whether a live `thread/settings/updated` notification has confirmed this
  /// config (vs only a start/resume snapshot).
  final bool configConfirmed;

  /// Whether earlier items remain unread — [BridgeApi.appThreadOlderPage]
  /// fetches them. False for a thread whose history arrives whole.
  final bool hasOlder;

  /// One entry per turn in the WHOLE thread, oldest first, including turns
  /// whose items aren't loaded yet. The turn rail shows a conversation's shape,
  /// so it needs every turn even before their bodies are read.
  final List<TurnSummary> turns;

  /// Actual oldest turn, confirmed by exhausting the server's summary cursor.
  final String? firstTurnId;

  /// Cached windows fetched through timeline navigation.
  final List<TurnItemsPage> turnPages;
}

/// A bounded ascending window within one selected turn.
class TurnItemsPage {
  /// Creates a turn window.
  const TurnItemsPage({
    required this.turnId,
    required this.items,
    required this.hasMore,
  });

  /// Owning turn.
  final String turnId;

  /// Loaded prefix in chronological order.
  final List<ThreadItem> items;

  /// Whether the same turn has more items after this window.
  final bool hasMore;
}

/// A turn reduced to what the rail shows: the question, and how it was answered.
class TurnSummary {
  /// Creates a turn summary.
  const TurnSummary({
    required this.turnId,
    this.userText = '',
    this.assistantText = '',
    this.loaded = false,
  });

  /// Id of the turn, for fetching its items on demand.
  final String turnId;

  /// The user's message that opened the turn; empty when it had none.
  final String userText;

  /// The turn's final agent message; empty when it produced no prose.
  final String assistantText;

  /// Whether this turn's items are already in the transcript.
  final bool loaded;
}

/// One page of older items, and whether history continues before them.
class OlderPage {
  /// Creates an older page.
  const OlderPage({required this.items, required this.hasOlder});

  /// Older items, oldest first, to prepend to the transcript.
  final List<ThreadItem> items;

  /// Whether older items still remain.
  final bool hasOlder;
}

/// The server-reported runtime configuration of a thread — what its turns
/// actually run with. Every field is null when the server hasn't said (never
/// a guess), so the UI can distinguish "server default" from "unknown".
class ThreadRuntimeConfig {
  /// Creates a runtime config snapshot.
  const ThreadRuntimeConfig({
    this.model,
    this.modelProvider,
    this.reasoningEffort,
    this.approvalPolicy,
    this.approvalsReviewer,
    this.serviceTier,
    this.sandboxMode,
    this.collaborationMode,
    this.confirmedByUpdate = false,
  });

  /// Effective model id.
  final String? model;

  /// Provider of the effective model.
  final String? modelProvider;

  /// Effective reasoning effort.
  final String? reasoningEffort;

  /// Effective approval policy.
  final String? approvalPolicy;

  /// Effective reviewer (`user` or `auto_review`).
  final String? approvalsReviewer;

  /// Effective service tier.
  final String? serviceTier;

  /// Effective sandbox mode (kebab wire string).
  final String? sandboxMode;

  /// Effective collaboration mode (`plan`/`default`), when reported.
  final String? collaborationMode;

  /// True once a live `thread/settings/updated` confirmed this config.
  final bool confirmedByUpdate;
}

/// One model offered by the app-server.
class ModelInfo {
  /// Creates model info.
  const ModelInfo({
    required this.id,
    required this.displayName,
    required this.description,
    this.supportedReasoningEfforts = const [],
    this.defaultReasoningEffort,
    this.supportedServiceTiers = const [],
    this.defaultServiceTier,
    this.isDefault = false,
  });

  /// Model id (used as the `model` param).
  final String id;

  /// Human-readable name.
  final String displayName;

  /// Short description.
  final String description;

  /// Reasoning efforts this model accepts (`minimal`/`low`/`medium`/`high`/
  /// `xhigh`/…), so the effort picker offers only the levels this model supports.
  final List<String> supportedReasoningEfforts;

  /// The model's default reasoning effort, if any.
  final String? defaultReasoningEffort;

  /// Service tier ids advertised by the model catalog.
  final List<String> supportedServiceTiers;

  /// Catalog default service tier.
  final String? defaultServiceTier;

  /// Whether this is the server default model.
  final bool isDefault;

  /// Whether this model advertises the Fast service tier.
  bool get supportsFast => supportedServiceTiers.contains('priority');
}

/// One materialised conversation item from `thread/read`.
class ThreadItem {
  /// Creates a thread item.
  const ThreadItem({
    required this.id,
    required this.itemType,
    required this.title,
    required this.text,
    this.diff,
    this.images = const [],
    this.turnId = '',
    this.turnCompletedAt,
    this.turnDurationMs,
    this.questionsJson,
  });

  /// Structured asynchronous questions from an agent message, as JSON.
  final String? questionsJson;

  /// Item id.
  final String id;

  /// Item type tag (`userMessage` / `agentMessage` / `commandExecution` /
  /// `webSearch` / `mcpToolCall` / `fileChange` / `reasoning` / …).
  final String itemType;

  /// One-line summary for tool/activity items.
  final String title;

  /// Body / detail text.
  final String text;

  /// Numbered native file changes.
  final DiffModel? diff;

  /// Image URLs attached to a `userMessage`: `data:image/...` URLs render
  /// inline; a host-local path renders as a filename chip. Empty for every
  /// other item kind.
  final List<String> images;

  /// Id of the turn this item belongs to — the server's own boundary, since
  /// `thread/read` nests items under their turn. Empty when unknown (an item
  /// recovered from the live stream buffer, or read from a rollout file on
  /// disk, neither of which carries a turn envelope).
  final String turnId;

  /// Unix seconds when this item's turn completed; null while it still runs, or
  /// when the source carried no turn.
  final int? turnCompletedAt;

  /// This item's turn duration in milliseconds, when the server reported it.
  final int? turnDurationMs;
}

/// The whole engine surface the UI is allowed to touch. One real impl wraps
/// flutter_rust_bridge; a fake backs widget tests.
/// Controller-wide disposable disk-cache usage.
class HistoryCacheStatus {
  const HistoryCacheStatus({required this.limitMb, required this.usedBytes});
  final int limitMb;
  final int usedBytes;
}
