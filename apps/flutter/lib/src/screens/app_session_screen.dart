import 'package:pocket_codex/src/widgets/session_file_links.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart' show openFiles;
import 'package:flutter/foundation.dart'
    show listEquals, setEquals, defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderSliver, ScrollDirection;
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_modes.dart';
import 'package:pocket_codex/src/attachment_refs.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/session_tree.dart';
import 'package:pocket_codex/src/widgets/running_sheen.dart';
import 'package:pocket_codex/src/widgets/session_tree_row.dart';
import 'package:pocket_codex/src/context_status.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/git_diff.dart';
import 'package:pocket_codex/src/hosting/host_editor_page.dart';
import 'package:pocket_codex/src/ide_context.dart';
import 'package:pocket_codex/src/image_attachments.dart';
import 'package:pocket_codex/src/project_index.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/log_manager.dart';
import 'package:pocket_codex/src/voice/dictation.dart';
import 'package:pocket_codex/src/voice/dictation_widgets.dart';
import 'package:pocket_codex/src/voice/voice_controller.dart';
import 'package:pocket_codex/src/voice/voice_widgets.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/screens/app_session/agent_permission_card.dart';
import 'package:pocket_codex/src/screens/app_session/agent_session_options.dart';
import 'package:pocket_codex/src/screens/app_session/agent_welcome.dart';
import 'package:pocket_codex/src/screens/app_session/attachment_gate.dart';
import 'package:pocket_codex/src/screens/app_session/async_questions.dart';
import 'package:pocket_codex/src/screens/app_session/activity_cards.dart';
import 'package:pocket_codex/src/screens/app_session/command_palette.dart';
import 'package:pocket_codex/src/screens/app_session/composer_cards.dart';
import 'package:pocket_codex/src/screens/app_session/expanded_composer.dart';
import 'package:pocket_codex/src/screens/app_session/message_editor.dart';
import 'package:pocket_codex/src/screens/app_session/model_feedback.dart';
import 'package:pocket_codex/src/screens/app_session/option_picker.dart';
import 'package:pocket_codex/src/screens/app_session/session_access_panel.dart';
import 'package:pocket_codex/src/screens/app_session/transcript_model.dart';
import 'package:pocket_codex/src/screens/app_session/user_input_card.dart';
import 'package:pocket_codex/src/screens/app_session/generated_image_card.dart';
import 'package:pocket_codex/src/screens/app_session/history_merge.dart';
import 'package:pocket_codex/src/screens/app_session/history_rows.dart';
import 'package:pocket_codex/src/screens/app_session/transcript_view.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/widgets/glass.dart';
import 'package:pocket_codex/src/widgets/floating_status.dart';
import 'package:pocket_codex/src/widgets/height_reporter.dart';
import 'package:pocket_codex/src/text_measure.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/animated_label.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/adaptive_sheet.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:pocket_codex/src/widgets/brand_logo.dart';
import 'package:pocket_codex/src/widgets/centered_scroll.dart';
import 'package:pocket_codex/src/review/review_panel.dart';
import 'package:pocket_codex/src/review/session_changes.dart';
import 'package:pocket_codex/src/widgets/draggable_navigation.dart';
import 'package:pocket_codex/src/widgets/history_arrival.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';
import 'package:pocket_codex/src/widgets/host_switcher.dart';
import 'package:pocket_codex/src/widgets/jump_to_latest_button.dart';
import 'package:pocket_codex/src/widgets/layered_navigation.dart';
import 'package:pocket_codex/src/widgets/file_browser_panel.dart';
import 'package:pocket_codex/src/widgets/folder_tree_picker.dart';
import 'package:pocket_codex/src/widgets/links.dart';
import 'package:pocket_codex/src/widgets/loading.dart';
import 'package:pocket_codex/src/widgets/message_images.dart';
import 'package:pocket_codex/src/widgets/middle_click_scroll.dart';
import 'package:pocket_codex/src/widgets/project_menu.dart';
import 'package:pocket_codex/src/widgets/project_section_header.dart';
import 'package:pocket_codex/src/widgets/status_dots.dart';
import 'package:pocket_codex/src/widgets/takeover_dialog.dart';
import 'package:pocket_codex/src/widgets/theme_toggle.dart';
import 'package:pocket_codex/src/widgets/turn_minimap.dart';
import 'package:pocket_codex/src/widgets/turn_navigation_handle.dart';
import 'package:pocket_codex/src/widgets/turn_outline.dart';
import 'package:pocket_codex/src/screens/app_session/approval_review.dart';
import 'package:pocket_codex/src/widgets/window_title_bar.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/tools/builtin_tools.dart';
import 'package:pocket_codex/src/widgets/app_dialog.dart';
import 'package:pocket_codex/src/widgets/change_counts.dart';

part 'app_session/composer_drafts.dart';
part 'app_session/session_access.dart';
part 'app_session/session_agent_prepare.dart';
part 'app_session/session_attachments.dart';
part 'app_session/session_builtin_tools.dart';
part 'app_session/session_capabilities.dart';
part 'app_session/session_composer.dart';
part 'app_session/session_composer_toolbar.dart';
part 'app_session/session_configuration.dart';
part 'app_session/session_draft_options.dart';
part 'app_session/session_conversations.dart';
part 'app_session/session_events.dart';
part 'app_session/session_external_writer.dart';
part 'app_session/session_history.dart';
part 'app_session/session_keyboard.dart';
part 'app_session/session_layout.dart';
part 'app_session/session_loading.dart';
part 'app_session/session_model_controls.dart';
part 'app_session/session_model_picker.dart';
part 'app_session/session_native_settings.dart';
part 'app_session/session_navigation.dart';
part 'app_session/session_projects.dart';
part 'app_session/session_queue.dart';
part 'app_session/session_quota.dart';
part 'app_session/session_recovery.dart';
part 'app_session/session_review.dart';
part 'app_session/session_send.dart';
part 'app_session/session_setup.dart';
part 'app_session/session_status.dart';
part 'app_session/session_supplement.dart';
part 'app_session/session_title.dart';
part 'app_session/session_transcript.dart';
part 'app_session/session_voice.dart';
part 'app_session/session_types.dart';
part 'app_session/transcript_list.dart';

/// Local port for the app-server ws tunnel (shared with the service screen).
/// `0` is a sentinel: the bridge assigns a free OS port *per service* so several
/// app services can be connected at once. A fixed shared port would let only the
/// first service bind; the rest would hit the probe-bind failure. See
/// [BridgeApi.appConnect].
const appLocalPort = 0;

// Cold-open loads that retry on their own schedule when the first attempt loses
// the race against the connection. See `_retryOpenLoad`.
const String _kThreadsLoad = 'threads';
const String _kCwdSeed = 'cwd';
const String _kModelsLoad = 'models';

/// Attempts each cold-open load gets before giving up (1/2/4/8/16s apart).
/// Reaches ~31s of coverage, which is what a desktop auto-host restore needs:
/// the host is a child process this app spawns, and it took ~30s to become
/// ready in the field.
const int _kOpenLoadMaxRetries = 5;

/// A live conversation with a remote codex app-server thread.
///
/// New conversations let the user pick model / permission mode / remote project
/// path (the composer chips); these apply at `thread/start`. The streamed reply
/// renders live; failures and dropped connections surface an actionable banner,
/// and command-approval prompts are answered inline.
class AppSessionScreen extends ConsumerStatefulWidget {
  /// Creates a session for [serviceKey]; [threadId] null starts a new thread,
  /// optionally seeded with [cwd] (a project chosen on the service screen).
  const AppSessionScreen({
    super.key,
    required this.serviceKey,
    this.threadId,
    this.cwd,
    this.home = false,
    this.services = const [],
    this.onSwitchService,
    this.hostSwitch,
    this.onDismissHostSwitch,
  });

  /// Full `pcx:<device>:app:<name>` key of the connected service.
  final String serviceKey;

  /// Existing thread to resume, or null to start a new one on first message.
  final String? threadId;

  /// Remote working directory to seed a new conversation with.
  final String? cwd;

  /// True when this screen IS the app's home (embedded by [HomeScreen]): the
  /// sessions pane lists every conversation (not just the current project's),
  /// gains a service switcher + management shortcuts, and there is no "back"
  /// destination. False for the classic pushed route (`/app/:key/session`),
  /// which keeps its project-scoped pane and back button.
  final bool home;

  /// Connectable app services for the home-mode service switcher (label +
  /// key). Ignored unless [home].
  final List<ServiceEntry> services;

  /// Called when the user picks another service in the home-mode switcher.
  final void Function(String serviceKey)? onSwitchService;

  /// A host switch the home is running or that just failed. Shown in the
  /// switcher row and as a strip above the conversation. Ignored unless
  /// [home].
  final HostSwitch? hostSwitch;

  /// Close a failed switch's notice.
  final VoidCallback? onDismissHostSwitch;

  @override
  ConsumerState<AppSessionScreen> createState() => _AppSessionState();

  /// Clears the process-wide per-thread plan/effort memory. Test-only: these
  /// static caches intentionally survive screen teardown/rebuild in the running
  /// app (so a reopened thread keeps its mode before the persisted config
  /// lands), but must be reset between widget tests to avoid cross-test leakage.
  @visibleForTesting
  static void debugResetThreadMemory() {
    _AppSessionState._planByThread.clear();
    _AppSessionState._effortByThread.clear();
    _AppSessionState._catalogByService.clear();
    _releasedHereThreads.clear();
  }

  /// The clipboard image read behind Ctrl/Cmd+V. A test seam: the plugin's
  /// platform channel cannot run headless.
  @visibleForTesting
  static Future<Uint8List?> Function() debugClipboardImage = () =>
      Pasteboard.image;

  /// The clipboard file-path read behind Ctrl/Cmd+V (see
  /// [debugClipboardImage]).
  @visibleForTesting
  static Future<List<String>> Function() debugClipboardFiles = Pasteboard.files;
}

class _AppSessionState extends ConsumerState<AppSessionScreen>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  // Keeps the agent's options (an open menu, a change in flight) while the
  // composer moves them between the toolbar and a line of their own.
  final _agentOptionsKey = GlobalKey();
  int? _newDraftFocusAfterDrawer;
  int _projectSelectionGeneration = 0;
  final _expandedInputFocus = FocusNode();
  late final _ComposerDrafts _drafts;
  late _ComposerDraft _draft;

  /// The [_ComposerDraft.outside] revision this view last showed.
  int _outsideSeen = 0;
  bool _editorOpen = false;
  final _scroll = CenteredScrollController();
  // The transcript's two lists around its centre row (transcript_list.dart).
  late final _list = _TranscriptGeometry(_scroll);

  /// The transcript's visible row range, republished on scroll.
  ///
  /// A notifier rather than screen state on purpose: the turn minimap highlights
  /// whichever turns are on screen, which changes every scroll frame. Holding
  /// that in `setState` would rebuild the whole transcript — 10k lines of widget
  /// tree — to move a 2 px tick, so only the ticks listen.
  final _visibleRows = ValueNotifier<(int, int)?>(null);
  // Ordered timeline + an id→index map for upserting streamed/updated items.
  final List<TranscriptItem> _items = [];
  final Map<String, int> _itemIndex = {};
  int _localSeq = 0; // ids for local markers (stops, turn durations)
  final Map<String, AsyncQuestionPrompt> _asyncQuestions = {};

  final List<AppEvent> _approvals = []; // pending command-approval prompts

  // What the connection behind [widget.serviceKey] supports. Controls are
  // gated on these flags, never on the provider's name. Codex is
  // fixed per key; an ACP connection's flags come from the host's current
  // negotiation, so they are re-read until negotiated and after every host
  // state change or reconnect (see [_invalidateCaps]).
  AppCapabilities? _capsCache;
  String? _capsKey;
  // Moves whenever cached capabilities are dropped; agent option changes
  // are bound to it (see [_AgentTarget]).
  int _capsEpoch = 0;

  /// The host connection this view's requests went to. It moves when that
  /// connection may have been lost or replaced — the event stream closed,
  /// the agent host was lost or replaced, or it reported a new generation —
  /// and not when a reload merely re-reads capabilities ([_capsEpoch]). An
  /// answer to a request of an older connection never applies its history,
  /// settles an admission, adopts a send's outcome or drains the queue.
  int _linkEpoch = 0;

  /// The [_linkEpoch] of the last history read that was applied as the
  /// host's answer. A reconnect is ready only once this equals the current
  /// link: a read the link outran applied nothing.
  int? _historyAppliedLink;

  /// The ACP agent's state for the open session (options, modes, usage).
  SessionSettings? _agentSettings;
  final _nativeSettings = _NativeSettingsReads();

  /// What the shown draft's own options were last read for (see
  /// `_scheduleDraftOptionsCheck`).
  Object? _draftOptionsKey;

  StreamSubscription<AppEvent>? _sub;
  int _subscriptionEpoch = 0;

  String? _threadId;
  late final VoiceController _voice;

  /// The composer microphone: a background realtime session, paused until a
  /// take attaches the microphone, whose transcript lands at the cursor.
  late final DictationLine _dictation;
  DictationTake _dictationTake = DictationTake.idle;

  /// Where the current take writes: the draft it belongs to, and the span
  /// of the field its words occupy so far. Deltas extend the span; a
  /// discard removes exactly it. Null outside a take.
  ({Object draft, int start, int end})? _dictationSpan;

  /// The selection the current take replaces, removed when its first words
  /// arrive. Null when there is none, or once it has been replaced.
  ({int start, int end})? _dictationReplaces;

  /// The text the current take's words replaced, restored if it is
  /// discarded. Empty when they replaced nothing.
  String _dictationReplaced = '';

  bool _voiceWasBusy = false;

  bool _voiceStarting = false;
  int _voiceIntentGeneration = 0;
  String? _cwd;
  // The host's automatic default folder for [key]: shown for a new
  // conversation with no chosen folder, never stored in [_cwd].
  ({String key, String path})? _hostDefault;
  // Numbers the host-default reads; only the latest one is noted.
  int _hostDefaultRead = 0;
  // A conversation this view created in the host's automatic default
  // folder: its real folder is taken from the host's list once listed.
  ({String key, String thread})? _automaticThread;
  ModelInfo? _model;
  // True while the user holds a model pick that hasn't been sent yet, so a
  // server-confirmed model (thread/settings/updated) doesn't clobber it.
  bool _modelPickPending = false;
  PermissionMode _mode = PermissionMode.autoReview;
  String? _serviceTier;
  bool _serviceTierPickPending = false;
  bool _modePickPending = false;
  bool _supplement = false;
  Object? _sendRequest;
  Object? _supplementRequest;
  bool _plan = false; // plan mode: the agent plans before implementing
  // Whether the thread is currently in plan mode server-side. Collaboration
  // mode is sticky on the thread, so we must send "default" to leave it — this
  // tracks when that's needed (i.e. the last turn ran in plan mode).
  bool _planActive = false;
  // Per-thread plan-mode memory, so switching/resuming a conversation restores
  // its true mode (thread/read doesn't expose collaborationMode, and the model's
  // last item often isn't a `plan` — the old heuristic left plan mode stuck on).
  // STATIC so it survives this screen being torn down + rebuilt (e.g. going back
  // to the session list and reopening a thread creates a fresh State). Without
  // this, reopening a just-planned thread before its async per-thread config
  // PUT lands leaves _planActive with no source → the implement bar vanishes.
  // The persisted meta config remains the cross-restart source of truth.
  static final Map<String, bool> _planByThread = {};
  // True when the user tapped the plan chip since the last send, so the next
  // turn explicitly carries the chosen mode (lets a stuck thread be turned off).
  bool _planToggledByUser = false;
  bool _implementDismissed = false; // user dismissed the implement prompt

  // Reasoning effort ("thinking level"). _effort is a *pending* user pick not yet
  // sent (null = no pending pick); _effortActive is the effort the thread is
  // currently running with (server truth, seeded from thread/resume, updated
  // after a send). The chip + the value sent each turn use the EFFECTIVE effort
  // `_effort ?? _effortActive`, so plan/permission turns re-assert it rather than
  // wiping it (effort is sticky server-side, and the server ignores the
  // top-level effort field when a collaborationMode is also sent). Effort can be
  // raised/lowered but not "un-set" — there is no model-default reset on the wire.
  // _effortByThread restores _effortActive when switching threads in place.
  // STATIC for the same reason as _planByThread: survive screen teardown/rebuild
  // so a reopened thread keeps its effort even before the persisted config lands.
  ReasoningEffort? _effort;
  ReasoningEffort? _effortActive;
  static final Map<String, ReasoningEffort?> _effortByThread = {};

  // The SERVER-reported runtime config: what this thread's turns actually run
  // with, per the server itself. Seeded from the thread/start・thread/resume
  // response (via thread/read + the bridge cache) and kept fresh by live
  // `thread/settings/updated` notifications. This is ground truth — distinct
  // from the pills above, which are what the user *selected* — and drives the
  // status-bar model indicator so a switch is verifiable, not assumed.
  ThreadRuntimeConfig? _runtime;
  // When _runtime last changed (for the provenance line in the details sheet).
  DateTime? _runtimeAt;

  // Per-turn model stamp: what the CURRENT turn runs with. Captured at
  // turn/started from the freshest server truth — a settings update arrives
  // just before turn/started when a switch happened — falling back to what
  // this app actually sent (turn params override thread defaults, so on older
  // servers that never notify, the sent value IS the effective one).
  // `_turnStampConfirmed` records which source won; `_turnRerouted` flips when
  // the server reports it substituted the model mid-turn (model/rerouted).
  // Embedded into the turn's duration footnote at turn end.
  String? _turnStampModel;
  String? _turnStampEffort;
  bool _turnStampConfirmed = false;
  bool _turnRerouted = false;
  // What the last send put on the wire, the stamp's fallback for servers
  // that never notify settings (turn params override thread defaults, so the
  // sent values ARE the effective ones there).
  String? _sentModel;
  String? _sentEffort;

  // Context-window occupancy + account quota for the status gauge. _ctx seeds
  // from thread/read and updates on thread/tokenUsage/updated; _rate is fetched
  // lazily when the quota popover opens and refreshed on rateLimits events.
  ContextStatus? _ctx;
  RateLimits? _rate;

  /// Bumped whenever [_rate] changes. An open detail panel lives in its own
  /// route, so a parent setState can't reach it — this can.
  final ValueNotifier<int> _quotaRev = ValueNotifier<int>(0);

  // Git: current branch (seeded from thread/read) + the working-tree-vs-main
  // diff, refreshed after edits (turn/diff/updated, turn/completed, compacted).
  String? _branch;
  DiffModel? _diff;
  int _gitRead = 0; // the latest diff read; only its answer is kept

  // A user-initiated diff fetch that the review is waiting on. Fetching a diff
  // on a large repo over the relay takes long enough to need both a spinner and
  // a way out, so the badge becomes a cancel control while this is set.
  //
  // Cancellation is cooperative: the bridge call can't be aborted, so the token
  // is what the completion checks against — a superseded or cancelled fetch
  // still returns, and is then discarded instead of opening the review.
  int _diffFetch = 0;
  bool _diffLoading = false;

  // Desktop layout: left = this project's sessions, right = the review
  // sidebar. Both collapsible AND drag-resizable; the chat stays centered
  // regardless. _threads backs the left pane.
  // The sidebar's open state and width start from the saved preference and
  // are written back when the user changes them (see [_setLeftOpen] and the
  // splitter's drag end), so a restart reopens the window as it was left.
  bool _leftOpen = true;
  bool _reviewOpen = false; // the review sidebar (or page) is showing
  double _leftWidth = 280;
  bool _paneDragging = false;
  bool _sidebarClosing = false;
  bool _layoutRestored = false;
  double? _composerHeight;
  // Live height while the resize edge is dragged. Only the input box listens,
  // so a drag re-lays out the composer instead of rebuilding the screen on
  // every pointer move — which is what made the edge lag the cursor.
  final ValueNotifier<double?> _composerDragHeight = ValueNotifier(null);
  int _settingsRevision = 0;
  double _reviewWidth = 760; // width of the review sidebar
  ReviewTarget? _reviewTarget; // where the review last opened

  /// Anchors the desktop turn-settings popover to the composer's model chip.
  final MenuController _modelMenu = MenuController();

  /// Anchors the environment-info popover to the app-bar button.
  final MenuController _envMenu = MenuController();
  List<ThreadMeta> _threads = const [];

  /// Whether the host has listed its conversations at least once: until then
  /// the sessions pane is loading, not empty.
  bool _threadsListed = false;
  final Map<String, ThreadMeta> _discoveredThreads = {};

  /// Sessions the host reported deleted (`thread/deleted`), by
  /// [_threadKey]: never listed or opened again by this view.
  final Set<String> _deletedThreads = {};

  /// Cold-open loads still waiting to succeed → attempts spent so far, plus
  /// each one's pending timer. A key present means "not settled yet"; the
  /// loader removes its key on success. See [_retryOpenLoad].
  final Map<String, int> _openLoadRetries = {};
  final Map<String, Timer> _openLoadTimers = {};

  /// Debounce for the post-turn thread re-list. See [_scheduleThreadsRefresh].
  Timer? _threadsRefreshTimer;

  /// Distinct project roots across every conversation on this service (not
  /// just the current project's), for the project switcher. See [_loadThreads].
  List<String> _allProjects = const [];
  // Which project each listed folder belongs to (a Codex worktree joins the
  // repository it came from). Rebuilt with every listing.
  ProjectIndex _projects = ProjectIndex.empty;
  // Live filter text for the conversations pane search box.
  String _convQuery = '';
  // The search box, so ⌘K / Ctrl+K can reach it from anywhere.
  final FocusNode _convSearchFocus = FocusNode();
  // The conversation list's scroll, so "locate" can bring the open row back.
  final ScrollController _convScroll = ScrollController();
  final ListController _convListCtl = ListController();
  // Conversations in the order the sidebar last listed them, for Ctrl+Tab.
  List<ThreadMeta> _visibleConversationOrder = const [];

  // Top-bar title rename: true while the title is a text field (click to
  // enter, Enter/blur to commit, Esc to cancel).
  bool _editingTitle = false;
  final TextEditingController _titleCtrl = TextEditingController();
  final FocusNode _titleFocus = FocusNode();

  /// Monotonic id for rename requests, so a failure can tell whether it is
  /// still the newest attempt. Committing re-opens the field immediately, so a
  /// user can start a second rename while the first is still in flight; rolling
  /// back unconditionally would then restore a title the user has already
  /// replaced — and leave the UI disagreeing with the server for good, since
  /// the second request's success path has nothing left to re-apply.
  int _renameSeq = 0;

  /// Project groups the user has collapsed in the sidebar, keyed by cwd, plus
  /// the ones they expanded past the first [_projectPeek] rows. Both are
  /// view state only — deliberately not persisted, so a restart reads as the
  /// same tidy default.
  final Set<String> _collapsedProjects = {};
  final Set<String> _expandedProjects = {};

  /// How many conversations a project group shows before "show more".
  static const int _projectPeek = 5;

  /// True while the sidebar groups conversations by WHEN they happened (with a
  /// one-line gist each) instead of by which project they belong to. View state
  /// only — a restart returns to the project tree, which is the default because
  /// it answers "where am I working".
  bool _activityView = false;

  bool _streaming = false;
  int _turnStateRevision = 0;
  // Only retain rows changed while the current history snapshot is in flight.
  Map<String, TranscriptItem>? _historyLiveItems;
  Set<String>? _historyPartialItems;
  // Current running turn's id, captured from turn/started — required to
  // interrupt it (turn/interrupt rejects a threadId without a turnId).
  String? _turnId;
  // Set when the user taps stop; the next turn end renders a "stopped" marker
  // in the transcript so the interruption is visible.
  bool _pendingInterrupt = false;
  // Live elapsed-time clock for the running turn: started on turn/started,
  // ticked once a second, then frozen and recorded as a per-turn footnote on
  // turn end. Local-only (not persisted), like the "stopped" marker.
  DateTime? _turnStartedAt;
  Timer? _elapsedTicker;
  // The running turn's clock, in a notifier: its tick repaints the labels
  // showing it, not the whole conversation.
  final _elapsed = ValueNotifier<int>(0);
  // True while a thread's history is being (re)loaded, so the chat shows a
  // smooth skeleton instead of flashing empty when switching sessions.
  bool _loading = false;
  // A thread held by another app-server stays inside this chat surface. Its
  // rollout follows one host-meta stream until it becomes resumable.
  bool _externalWriterMode = false;
  bool _guardianReadOnly = false;
  String? _parentThreadId;
  final Set<String> _expandedSessionParents = {};
  // Manual folds also override automatic reveals for search or selection.
  final Set<String> _collapsedSessionParents = {};
  SessionLiveness? _externalWriterLiveness;
  StreamSubscription<SessionFollowUpdate>? _externalWriterSub;
  Timer? _externalWriterReconnect;
  Timer? _externalHistoryTimer;
  String? _externalHistoryRevision;
  bool _externalHistoryLoading = false;
  bool _externalHistoryDirty = false;
  bool _externalWriterLegacy = false;
  int _externalWriterEpoch = 0;
  bool _takingOver = false;
  // The `/` command list: keyboard selection, and the text it was closed at.
  int _paletteIndex = 0;
  String? _paletteDismissed;
  // Where this view stands with a host-access session (ACP, OpenCode), as
  // the host decided it; re-checked while following.
  SessionAccess? _access;
  Timer? _accessTimer;
  DateTime? _followSince;
  bool _accessChecking = false;
  // Check now was pressed while an earlier check was still out.
  bool _accessCheckAsked = false;
  // The latest write-access read; older answers apply nothing.
  int _accessReadSeq = 0;

  /// The local operation (a send, a supplement, an answer) holding the
  /// composer's send lock. Each releases only its own hold, so a superseded
  /// operation finishing late never unlocks a newer one; leaving the
  /// conversation drops whatever holds it.
  Object? _localSendOwner;
  // The conversation whose option change is being saved, and that save.
  ({_AgentTarget target, Object save})? _configSaving;

  /// Moves with every composer operation that takes the send lock, and
  /// never moves back: an operation is the latest only while nothing began
  /// after it — even when that newer one has already finished and released
  /// the lock (a free lock proves nothing about what came since).
  int _composerOp = 0;

  /// A notice of an operation whose outcome is unknown (a supplement answer
  /// that arrived after its connection moved), kept for its draft and
  /// conversation so a reload or reconnect clearing the banner offers it
  /// again. Dropped when dismissed or when a newer operation begins.
  ({_ComposerDraft draft, String threadId, int op, String text})? _heldNotice;

  /// A turn was just admitted and its `turn/started` has not arrived yet:
  /// the session is busy although nothing streams, so the queue waits and a
  /// new message queues behind it. Cleared by that turn's events, by
  /// leaving the conversation, or — when nothing arrived within
  /// [_turnStartGrace] — by the host's own account of the session (see
  /// [_reconcileAwaitedStart]); elapsed time alone never releases it. The
  /// token identifies the admission, so a reconciliation of an older one
  /// can never release a newer one.
  _AwaitedStart? _awaitedStart;
  Timer? _turnStartTimer;
  static const _turnStartGrace = Duration(seconds: 20);

  /// Turns this view saw end, newest last (bounded): a terminal event of one
  /// of them arriving again while the next turn is awaited is not that
  /// turn's end, and their late item events add no rows.
  final List<String> _endedTurns = [];
  bool _atBottom = true; // is the list scrolled to the latest message?

  /// The height of what floats over the transcript's foot — the composer
  /// and the cards above it — which the transcript reserves as end padding
  /// so its last message rests above them.
  double _composerOverlay = 0;

  /// The composer block's own height, inside [_composerOverlay].
  double _composerBlock = 0;
  // Every turn of the open thread, oldest first — including turns whose items
  // aren't loaded. The rail shows the conversation's shape, so it reads this
  // rather than the loaded rows. Empty for a thread that arrived whole, whose
  // rows already cover every turn.
  List<TurnSummary> _turnSummaries = const [];
  // Whether older items remain on the server for the open thread.
  bool _hasOlder = false;
  bool _historyError = false;
  final Set<String> _fetchedTurns = {};
  final Map<String, TurnItemsPage> _turnWindows = {};
  final Set<String> _sequentialHistoryIds = {};
  String? _firstTurnId;
  final Map<Key, GlobalKey> _rowAnchors = {};
  List<Object>? _cachedRows;
  TurnWork? _lastWork;
  List<(TranscriptItem, String, String)> _rowSources = const [];
  (String?, bool)? _historyTarget;
  TurnMinimapItem? _navigatingTurn;
  bool _navigationLoading = false;
  List<Object>? _minimapRows;
  List<TurnSummary>? _minimapTurns;
  String? _minimapLastText;
  List<TurnMinimapItem> _minimapEntries = const [];
  // The older page (or single turn's items) in flight, so a scroll frame
  // can't queue the same fetch twice.
  Future<void>? _historyLoad;
  bool get _loadingOlder => _historyLoad != null;
  int _historyGeneration = 0;
  int _turnNavigation = 0;
  int _scrollIntent = 0;
  bool _historyFromTop = false;
  Key? _historyArrivalRow;
  int _historyArrivalRevision = 0;
  Locale? _minimapLocale;
  String? _error;
  VoidCallback? _retry; // action for the error banner's retry button
  int _threadLoadGeneration = 0;
  bool _connectionLost = false;
  String? _historyEpoch;
  bool _historySyncing = false;
  bool _showingCachedHistory = false;
  // True while an automatic reconnect is in progress (drives the status bar's
  // "reconnecting" state). Auto-reconnect is attempted on stream close, on a
  // periodic health check, and after a send fails on a dropped connection.
  bool _reconnecting = false;
  // Running for 3 s after an automatic reconnect began (its debounce); a
  // timer, so the window follows the app's clock rather than a stopwatch.
  Timer? _reconnectCooldown;
  int _reconnectEpoch = 0;
  bool _foreground = true;
  bool _restoringSettings = false;
  Timer? _healthTimer;
  // The last message sent here (its text, images and client id), so a
  // one-tap retry after a dropped send re-sends it into the same copy.
  _Resend? _lastSent;
  // True while a file is being dragged over the chat (desktop) — shows the
  // "drop to attach" overlay.
  bool _dragging = false;
  // Whether the running turn has produced ANY output yet (reasoning, a tool
  // call, or reply text). Distinguishes "sent, nothing back" — where Esc undoes
  // the send and restores the text — from "output started", where Esc simply
  // interrupts. Reset on each turn/started; set on the first agent-side item.
  bool _outputStarted = false;
  // Snapshot the whole draft so undo can restore attachments as well as text.
  ({String text, List<_Attachment> attachments, List<String> tools})?
  _undoableDraft;
  // Set when an interrupt is really an Esc "undo": the turn's end must NOT add a
  // "stopped" marker (the send is being taken back, not shown as stopped).
  bool _suppressStopMarker = false;

  @override
  void initState() {
    super.initState();
    final layout = ref.read(uiPrefsProvider).valueOrNull;
    if (layout != null) {
      _layoutRestored = true;
      _leftOpen = layout.sidebarOpen ?? true;
      _leftWidth = layout.sidebarWidth ?? _leftWidth;
    }
    _voice = VoiceController(
      api: ref.read(bridgeApiProvider),
      serviceKey: widget.serviceKey,
      createTransport: ref.read(voiceTransportFactoryProvider),
    );
    _dictation =
        DictationLine(
            api: ref.read(bridgeApiProvider),
            serviceKey: widget.serviceKey,
            createTransport: ref.read(dictationTransportFactoryProvider),
            // On iOS and Android an open media link takes the device's audio
            // from other apps, so the line exists only while a take runs.
            keepOpen: switch (defaultTargetPlatform) {
              TargetPlatform.iOS || TargetPlatform.android => false,
              _ => true,
            },
          )
          ..onDelta = _onDictationDelta
          ..onTakeEnded = _onDictationEnded
          ..addListener(_onDictationChanged);
    // A call starting takes the microphone; the dictation line steps aside
    // so the two never fight over it, and comes back once the call ends.
    _voice.addListener(_onVoiceForDictation);
    _threadId = widget.threadId;
    _cwd = widget.cwd;
    _drafts = ref.read(_composerDraftsProvider(widget.serviceKey));
    _draft = _drafts.forThread(_threadId, cwd: _cwd);
    _input.value = _draft.value.copyWith(composing: TextRange.empty);
    _input.addListener(_saveDraft);
    // Remember where the user is chatting so the next cold start (and the
    // chat-first home) lands right back here. Deferred: provider writes are
    // not allowed while the tree is building. A thread-less mount (fresh
    // conversation) records nothing — the previous "last conversation" stays
    // the restore target until this one actually exists (first send).
    final initialThread = _threadId;
    Future.microtask(() {
      if (!mounted) return;
      final prefs = ref.read(uiPrefsProvider.notifier)
        ..setLastService(widget.serviceKey);
      if (initialThread != null) {
        prefs.setLastThread(widget.serviceKey, initialThread);
      }
    });
    // A brand-new conversation inherits the user's last-chosen model / mode /
    // plan / effort instead of resetting to hard defaults.
    if (_threadId == null) _seedDefaults();
    // ...and defaults its working folder to the host's configured default
    // project when the caller didn't seed one (async; won't override a picked
    // cwd — see the guard in _seedDefaultCwd).
    if (_threadId == null && (_cwd == null || _cwd!.trim().isEmpty)) {
      _seedDefaultCwd();
    }
    _scroll.addListener(_onScroll);
    // Focusing the composer raises the soft keyboard, which shrinks the
    // transcript viewport from the bottom — whatever the user was reading
    // slides up behind the keyboard. Re-pin to the latest message once the
    // inset has settled so the tail of the conversation stays in view.
    _inputFocus.addListener(_onComposerFocus);
    WidgetsBinding.instance.addObserver(this); // keyboard-inset metrics
    // Desktop: intercept Ctrl/Cmd+V so a clipboard image/file also attaches
    // (text paste still works — the handler never consumes the event).
    if (_isDesktop) HardwareKeyboard.instance.addHandler(_onHardwareKey);
    _subscribe();
    unawaited(_ensureModels());
    ref.listenManual(runningSessionInventoryProvider(widget.serviceKey), (
      _,
      next,
    ) {
      final sessions = next.valueOrNull?.sessions;
      if (!mounted || sessions == null || sessions.isEmpty) return;
      // Without external-writer discovery the inventory is only running ids
      // (no preview/cwd): the thread list already names every root session.
      if (!_caps.externalWriterMonitor) return;
      final found = [
        for (final session in sessions)
          if (!_isDeleted(session.threadId))
            ThreadMeta(
              id: session.threadId,
              preview: session.preview,
              name: session.name,
              threadSource: session.threadSource,
              parentThreadId: session.parentThreadId,
              cwd: session.cwd ?? '',
              updatedAt: session.updatedAt,
            ),
      ];
      // Each poll answers again; only news is worth rebuilding the screen.
      bool known(ThreadMeta meta) => switch (_discoveredThreads[meta.id]) {
        final had? =>
          had.preview == meta.preview &&
              had.name == meta.name &&
              had.threadSource == meta.threadSource &&
              had.parentThreadId == meta.parentThreadId &&
              had.cwd == meta.cwd &&
              had.updatedAt == meta.updatedAt,
        null => false,
      };
      if (found.every(known)) return;
      setState(() {
        for (final meta in found) {
          _discoveredThreads[meta.id] = meta;
        }
      });
    }, fireImmediately: true);
    if (_threadId != null) _resumeAndLoad();
    _loadThreads();
    // Periodically verify the connection is alive and auto-reconnect if not, so
    // a session left in the background recovers before the user notices (the
    // engine reports a dead socket via appIsConnected; the keepalive ping
    // surfaces it promptly).
    _healthTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!mounted || !_foreground || _reconnecting) return;
      if (_connectionLost ||
          !ref.read(bridgeApiProvider).appIsConnected(widget.serviceKey)) {
        _onStreamClosed();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) return;
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _reconnectCooldown?.cancel();
      _reconnectCooldown = null;
      if (_connectionLost ||
          !ref.read(bridgeApiProvider).appIsConnected(widget.serviceKey)) {
        unawaited(_autoReconnect());
      }
    } else {
      ++_reconnectEpoch;
      if (_reconnecting) {
        setState(() {
          _reconnecting = false;
          _connectionLost = true;
        });
      }
    }
    // A phone backgrounding the app loses the microphone anyway, so the call
    // ends. A desktop window that loses focus, is covered or is minimised is
    // still the user's live call — they switched to their editor to keep
    // talking — so only the process going away ends it there.
    final ends = isDesktop
        ? state == AppLifecycleState.detached
        : state == AppLifecycleState.paused ||
              state == AppLifecycleState.hidden ||
              state == AppLifecycleState.detached;
    if (ends) {
      ++_voiceIntentGeneration;
      unawaited(_voice.stop());
      // Same rule for the dictation line: a phone in the background has no
      // microphone, and a held session would only idle against the quota.
      unawaited(_dictation.close());
    }
  }

  @override
  void activate() {
    super.activate();
    unawaited(
      ref
          .read(bridgeApiProvider)
          .appHistoryFocus(widget.serviceKey, _threadId)
          .catchError((_) {}),
    );
  }

  @override
  void deactivate() {
    unawaited(
      ref
          .read(bridgeApiProvider)
          .appHistoryFocus(widget.serviceKey, null)
          .catchError((_) {}),
    );
    // Stop claiming this link is down once nobody is watching it: the flag is an
    // OBSERVATION by an open conversation, and leaving it set would keep the
    // service red on the strength of a screen that no longer exists.
    //
    // Here rather than in `dispose`: Riverpod forbids touching `ref` once the
    // element is disposed. The change itself waits for the frame to end, as
    // the tree is still being built while it deactivates.
    final observed = ref.read(observedDisconnectedProvider.notifier);
    final key = widget.serviceKey;
    scheduleMicrotask(() {
      if (observed.mounted && observed.state.contains(key)) {
        observed.state = {...observed.state}..remove(key);
      }
    });
    super.deactivate();
  }

  @override
  void dispose() {
    ++_reconnectEpoch;
    _voice
      ..removeListener(_onVoiceForDictation)
      ..dispose();
    _dictation
      ..removeListener(_onDictationChanged)
      ..onDelta = null
      ..onTakeEnded = null
      ..dispose();
    _healthTimer?.cancel();
    _reconnectCooldown?.cancel();
    _externalHistoryTimer?.cancel();
    _accessTimer?.cancel();
    _externalWriterReconnect?.cancel();
    final externalWriterSub = _externalWriterSub;
    if (externalWriterSub != null) unawaited(externalWriterSub.cancel());
    for (final t in _openLoadTimers.values) {
      t.cancel();
    }
    _threadsRefreshTimer?.cancel();
    _elapsedTicker?.cancel();
    _turnStartTimer?.cancel();
    _sub?.cancel();
    _input.removeListener(_saveDraft);
    _input.dispose();
    _expandedInputFocus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _inputFocus.removeListener(_onComposerFocus);
    _inputFocus.dispose();
    _convSearchFocus.dispose();
    _composerDragHeight.dispose();
    _convScroll.dispose();
    _convListCtl.dispose();
    if (_isDesktop) HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _list.dispose();
    _visibleRows.dispose();
    _elapsed.dispose();
    _quotaRev.dispose();
    _titleCtrl.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  /// The keyboard inset animates in over several frames, and each frame shrinks
  /// the transcript viewport a little more, so re-pin on every metrics change,
  /// for as long as the composer holds focus.
  @override
  void didChangeMetrics() => _repinForKeyboard();

  /// A post-frame check for the shown draft's agent session is pending (see
  /// [_scheduleAgentSessionCheck]).
  bool _agentCheckScheduled = false;

  /// Max width of the centred conversation column. The transcript computes its
  /// own side padding from this; the turn rail lives in what's left over, so both
  /// have to agree on the number.
  static const double _kColumnWidth = 820;

  @override
  Widget build(BuildContext context) => SessionFileLinks(
    api: ref.read(bridgeApiProvider),
    serviceKey: widget.serviceKey,
    threadId: _threadId,
    cwd: _cwd,
    child: SessionFeatureScope(
      guardianReviews: _caps.guardian,
      onReviewChange: _openChangeInReview,
      child: _buildSession(context),
    ),
  );

  /// Narrowest composer card that keeps the dictation microphone inline;
  /// below it the `+` menu carries it.
  static const _dictationInlineWidth = 440.0;

  // Cached model list (carries each model's supportedReasoningEfforts), fetched
  // lazily and shared by the model + effort pickers. It belongs to the host
  // connection and project it was read for ([_modelsKey]); a reconnect or
  // another project reads it again.
  List<ModelInfo> _models = const [];
  Future<List<ModelInfo>>? _modelsLoading;
  Object? _modelsKey;
  Object? _modelsLoadingKey;

  /// Moves whenever a fresh model list differs from the one last seen for
  /// this service (a host replaced with another configuration).
  int _catalogChanges = 0;

  /// The model ids last read per service. STATIC: a catalog change is told
  /// apart from a first read even by a screen created after the change.
  static final Map<String, Set<String>> _catalogByService = {};

  void _updateState(VoidCallback change) => setState(change);
}
