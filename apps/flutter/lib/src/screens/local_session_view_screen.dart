import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pocket_codex/src/automation_prompt.dart';
import 'package:pocket_codex/src/screens/app_session/automation_prompt_card.dart';
import 'package:go_router/go_router.dart';
import 'app_session/activity_cards.dart';
import 'app_session/approval_review.dart';
import 'app_session/approval_review_card.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_modes.dart';
import 'package:pocket_codex/src/attachment_refs.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/hosting/host_editor_page.dart';
import 'package:pocket_codex/src/native_hosts.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/ide_context.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/realtime_delegation.dart';
import 'package:pocket_codex/src/screens/local_sessions_screen.dart'
    show SessionSource, resumeLocalSession;
import 'package:pocket_codex/src/screens/app_session/generated_image_card.dart';
import 'package:pocket_codex/src/screens/app_session/model_feedback.dart';
import 'package:pocket_codex/src/screens/app_session/message_actions.dart';
import 'package:pocket_codex/src/screens/app_session/transcript_model.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/tools/builtin_tools.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/loading.dart';
import 'package:pocket_codex/src/widgets/markdown_view.dart';
import 'package:pocket_codex/src/widgets/message_images.dart';
import 'package:pocket_codex/src/widgets/realtime_handoff_card.dart';
import 'package:pocket_codex/src/widgets/session_file_links.dart';
import 'package:pocket_codex/src/widgets/utility_page.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import 'local_session_view/native_window.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';

part 'local_session_view/transcript_row.dart';
part 'local_session_view/native_follow.dart';

/// Read-only viewer for a local codex session's transcript, parsed straight from
/// the on-disk rollout (no app-server, no resume, no write) — so a session that
/// another codex client (the desktop app / CLI / VS Code) is actively driving
/// can still be read here.
///
/// While a live process owns the session it stays read-only. The viewer polls
/// liveness, so the moment that other client's turn finishes and the session
/// goes idle, it offers a confirmed force-resume to take it over. A free
/// (unowned) session offers a plain resume.
class LocalSessionViewScreen extends ConsumerStatefulWidget {
  /// Creates the viewer for [threadId].
  const LocalSessionViewScreen({
    super.key,
    required this.threadId,
    this.cwd,
    this.preview,
    this.serviceKey,
    this.provider = 'codex',
    this.guardian = false,
    this.parentThreadId,
  });

  /// The session/thread to view.
  final String threadId;

  /// Provider for local files only; remote sources never use this selection.
  final String provider;

  /// Working directory the session controls, carried to the live session on
  /// resume.
  final String? cwd;

  /// First-user-message preview, used as the screen title.
  final String? preview;

  /// The app-server key of the host that owns this session, when viewing a
  /// (possibly remote) host over its meta tunnel; null for the local machine.
  final String? serviceKey;
  final bool guardian;
  final String? parentThreadId;

  @override
  ConsumerState<LocalSessionViewScreen> createState() =>
      _LocalSessionViewState();
}

class _LocalSessionViewState extends ConsumerState<LocalSessionViewScreen>
    with WidgetsBindingObserver {
  /// How often to re-read the rollout + re-probe liveness while viewing, so a
  /// session another client is driving updates live and flips to resumable the
  /// moment its turn finishes. Native sources follow the bridge's stream
  /// instead, which also pushes live changes.
  static const _pollInterval = Duration(seconds: 3);

  List<ThreadItem> _items = const [];
  SessionLiveness? _live;
  void _update(VoidCallback change) => setState(change);

  bool _loading = true;
  String? _error;
  Timer? _poll;
  StreamSubscription<NativeSessionRevision>? _follow;
  NativeSessionRevision? _pendingRevision;
  final _scroll = ScrollController();
  late HostImageLoader _imageLoader;
  int _loadEpoch = 0;
  bool _reading = false;
  final _native = NativeHistoryWindow();
  bool _loadingOlder = false;
  bool _resuming = false;
  bool _foreground = true;

  // Resolved (base64-decoded) attachments cached by item id: rows rebuild on
  // every 3s poll, and re-decoding each image every tick would churn CPU and
  // memory. Completion can replace a reference without changing its count.
  final Map<String, ({List<String> urls, List<ResolvedImage> images})>
  _imageCache = {};

  @override
  void didUpdateWidget(LocalSessionViewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Ids are line indexes (`t0`, `t1`, …) — they collide ACROSS threads, so a
    // reused State showing a different thread must drop the previous thread's
    // cache or its images would render under the new thread's ids.
    if (oldWidget.threadId != widget.threadId ||
        oldWidget.serviceKey != widget.serviceKey ||
        oldWidget.provider != widget.provider) {
      _native.clear();
      _loadingOlder = false;
      _imageCache.clear();
      _items = const [];
      _live = null;
      _setImageLoader();
      _load(initial: true);
      _stopPoll();
      _startPoll();
    }
  }

  List<ResolvedImage> _imagesFor(ThreadItem item) {
    if (item.images.isEmpty) return const [];
    final cached = _imageCache[item.id];
    if (cached != null && listEquals(cached.urls, item.images)) {
      return cached.images;
    }
    final resolved = resolveImageUrls(item.images);
    _imageCache[item.id] = (urls: List.of(item.images), images: resolved);
    return resolved;
  }

  /// Where this viewer reads from (local machine vs the host's meta tunnel).
  SessionSource get _source => widget.serviceKey == null
      ? SessionSource.local(provider: widget.provider)
      : SessionSource.remote(widget.serviceKey!);

  void _setImageLoader() {
    final service = widget.serviceKey;
    final thread = widget.threadId;
    final api = ref.read(bridgeApiProvider);
    _imageLoader = _source.isNative
        ? (_) async => null
        : service == null
        ? readLocalImage
        : (path) async {
            Uint8List bytes;
            try {
              bytes = await api.metaReadThreadImage(service, thread, path);
            } catch (_) {
              try {
                bytes = await api.metaReadFile(service, path);
              } catch (_) {
                return null;
              }
            }
            return bytes.isEmpty || bytes.length > kMaxInlineImageBytes
                ? null
                : bytes;
          };
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _setImageLoader();
    _load(initial: true);
    _startPoll();
  }

  void _startPoll() {
    if (_source.isNative) {
      _startNativeFollow();
    } else {
      _poll = Timer.periodic(_pollInterval, (_) => _load());
    }
  }

  void _stopPoll() {
    _poll?.cancel();
    _poll = null;
    unawaited(_follow?.cancel());
    _follow = null;
    _pendingRevision = null;
  }

  /// Whether this viewer is the visible route.
  bool get _onTop => ModalRoute.of(context)?.isCurrent ?? true;

  /// Whether the reader is at (or near) the transcript's end.
  bool get _atBottom =>
      !_scroll.hasClients ||
      _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40;

  /// Keep the end in view once the next frame laid it out, while [current].
  void _followTail(bool Function() current) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (current() && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPoll();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Also runs when another route covers this one or leaves it.
    _syncNativeFollow();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncNativeFollow();
    if (_foreground && _source.isNative) _load();
  }

  Future<void> _load({bool initial = false}) async {
    if (_source.isNative) {
      if (!initial && (!_foreground || !_onTop)) return;
      return _loadNative(initial: initial);
    }
    if (_reading && !initial) return;
    _reading = true;
    final epoch = ++_loadEpoch;
    final source = _source;
    final thread = widget.threadId;
    bool current() => mounted && epoch == _loadEpoch;
    if (initial) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final bridge = ref.read(bridgeApiProvider);
    try {
      // Liveness first (a tiny probe). The full transcript — which now embeds
      // every attachment's base64 data URL — is re-fetched on a poll tick ONLY
      // while a live writer holds the rollout (it can change) or on the tick
      // right after it lets go (to pick up the final append). An idle
      // session's rollout is immutable, and re-shipping megabytes of images
      // over the relay every 3s for an unchanged transcript would burn a
      // phone's metered data for nothing.
      final live = await source.liveness(bridge, thread);
      if (!current()) return;
      final wasHeld = _live?.heldOpen ?? false;
      final fetchTranscript =
          initial || _items.isEmpty || live.heldOpen || wasHeld;
      final items = fetchTranscript
          ? await source.transcript(bridge, thread)
          : _items;
      if (!current()) return;
      // Auto-follow the tail if the reader is already near the bottom, so a
      // session being driven elsewhere streams in like a live conversation.
      final atBottom = _atBottom;
      setState(() {
        _items = items;
        _live = live;
        _loading = false;
        _error = null;
      });
      if (fetchTranscript && atBottom) _followTail(current);
    } catch (e) {
      if (!current()) return;
      // A transient poll failure shouldn't blow away a transcript already shown.
      setState(() {
        _loading = false;
        if (initial || _items.isEmpty) _error = friendlyError(e);
      });
    } finally {
      if (epoch == _loadEpoch) _reading = false;
    }
  }

  Future<void> _resume() async {
    final live = _live;
    if (_resuming ||
        _source.isNative ||
        widget.guardian ||
        live == null ||
        !live.allowsResume) {
      return;
    }
    // Pause polling while the takeover runs so a mid-flight re-probe can't race
    // the eviction; resumeLocalSession navigates away on success.
    _poll?.cancel();
    final epoch = _loadEpoch;
    _resuming = true;
    try {
      await resumeLocalSession(
        context,
        ref,
        threadId: widget.threadId,
        cwd: widget.cwd,
        requiresTakeover: live.requiresTakeover,
        holders: live.holders,
        source: _source,
        isCurrent: () => mounted && epoch == _loadEpoch,
      );
    } finally {
      _resuming = false;
    }
    // Only re-arm the poll when this viewer is still the visible route. On a
    // successful resume it pushed the live conversation on top of us, and
    // polling a backgrounded screen every 3s is wasted work.
    if (mounted && _onTop) _startPoll();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // A file-only first message's preview is the raw attached-files wire
    // block — show the placeholder rather than header markup in the app bar.
    final cleaned = widget.preview == null
        ? ''
        : previewWithoutFileRefs(
            widget.preview!.trim(),
            l10n.fileOnlyMessage,
          ).trim();
    final title = cleaned.isEmpty ? widget.threadId : cleaned;
    return SessionFileLinks(
      api: ref.read(bridgeApiProvider),
      serviceKey: widget.serviceKey,
      threadId: widget.threadId,
      cwd: widget.cwd,
      child: UtilityPage(
        route: '/sessions',
        title: title,
        parent: UtilityParent(
          title: l10n.localSessionsTitle,
          route: Uri(
            path: '/sessions',
            queryParameters: {
              if (widget.serviceKey != null) 'svc': widget.serviceKey!,
              if (widget.serviceKey == null) 'provider': widget.provider,
            },
          ).toString(),
        ),
        actions: [
          if (widget.parentThreadId case final parent?)
            IconButton(
              tooltip: l10n.parentSession,
              icon: const Icon(AppIcons.subdirectory_arrow_left),
              onPressed: () => context.push(
                Uri(
                  path: '/sessions/view',
                  queryParameters: {
                    'tid': parent,
                    if (widget.serviceKey == null) 'provider': widget.provider,
                    if (widget.serviceKey != null) 'svc': widget.serviceKey!,
                    if (widget.cwd != null) 'cwd': widget.cwd!,
                  },
                ).toString(),
              ),
            ),
          IconButton(
            key: const Key('local-view-refresh'),
            icon: const Icon(AppIcons.refresh),
            tooltip: l10n.refreshStatus,
            onPressed: _loading ? null : () => _load(initial: true),
          ),
        ],
        body: Column(
          children: [
            _banner(l10n),
            if (_source.isNative) _nativeControls(l10n),
            Expanded(child: _body(l10n)),
          ],
        ),
        bottomNavigationBar: _actionBar(l10n),
      ),
    );
  }

  /// A status strip shown when a live process owns the session.
  Widget _banner(AppLocalizations l10n) {
    final live = _live;
    if (live == null || !live.heldOpen) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final running =
        live.safety == 'ownedRunning' || live.safety == 'nativeOwnedRunning';
    // Held by the host's own app-server: resuming joins it, so the only news
    // is a running turn.
    final joined =
        !_source.isNative && live.allowsResume && !live.requiresTakeover;
    if (joined && !running) return const SizedBox.shrink();
    final color = joined
        ? scheme.primary
        : running
        ? scheme.error
        : cautionColor(scheme);
    final text = joined
        ? l10n.running
        : running
        ? '${l10n.sessionRunningElsewhere} · ${l10n.sessionReadOnly}'
        : l10n.sessionInUseElsewhere;
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            joined
                ? AppIcons.sync_rounded
                : running
                ? AppIcons.lock_clock
                : AppIcons.lock_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _body(AppLocalizations l10n) {
    if (_loading) {
      return const ListLoadingSkeleton(key: ValueKey('view-loading'));
    }
    if (_error != null && (!_source.isNative || _items.isEmpty)) {
      return Center(
        key: const ValueKey('view-error'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => _load(initial: true),
                child: Text(l10n.retry),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        key: const ValueKey('view-empty'),
        child: Text(l10n.sessionTranscriptEmpty),
      );
    }
    // SuperListView (super_sliver_list) replaces ListView.builder for a stable
    // scrollbar: it reconciles per-item height estimates against real heights
    // as rows scroll through, instead of a single running-average estimate that
    // makes the thumb jump given the wide row-height variance here — the same
    // fix the live conversation view uses. Content is centred and capped at
    // ~820px so a wide desktop window doesn't stretch bubbles/markdown
    // edge-to-edge. Stable per-row keys let the sliver track measured heights
    // across the 3s transcript refreshes.
    return SelectionArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final side = (constraints.maxWidth - 820) / 2;
          final pad = side < 12 ? 12.0 : side;
          return SuperListView.builder(
            key: const ValueKey('view-transcript'),
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(pad, 12, pad, 12),
            itemCount: _items.length,
            itemBuilder: (context, i) => _TranscriptRow(
              key: ValueKey(_items[i].id),
              item: _items[i],
              images: _imagesFor(_items[i]),
              hostImageLoader: _imageLoader,
              imageCacheScope: (
                widget.serviceKey,
                widget.provider,
                _native.sourceId,
                widget.threadId,
              ),
            ),
          );
        },
      ),
    );
  }

  /// Bottom action: a read-only note while the session is actively running, or a
  /// resume / force-takeover button once it is free / idle.
  Widget _actionBar(AppLocalizations l10n) {
    if (_source.isNative && !widget.guardian && widget.serviceKey == null) {
      return _nativeContinue(l10n);
    }
    final live = _live;
    if (live == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: !_source.isNative && live.allowsResume && !widget.guardian
            ? FilledButton.icon(
                key: const Key('view-resume'),
                onPressed: _resume,
                icon: Icon(
                  live.requiresTakeover
                      ? AppIcons.bolt
                      : AppIcons.play_circle_outline,
                ),
                label: Text(
                  live.requiresTakeover
                      ? l10n.forceTakeover
                      : l10n.resumeSession,
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    AppIcons.lock_clock,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _source.isNative
                          ? l10n.nativeHistoryReadOnly
                          : l10n.readOnlyViewing,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  /// A provider-native session continues only through a host that serves
  /// it: open it there (its access is resolved on arrival), or host the
  /// provider on this device. Never a fork or a copy.
  Widget _nativeContinue(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final provider = widget.provider;
    final name = nativeProviderName(provider);
    final host = nativeContinueHost(
      ref.watch(localServeListProvider).valueOrNull ?? const [],
      provider,
      preferred: ref.watch(uiPrefsProvider).valueOrNull?.lastServiceKey,
    );
    final canHost =
        isDesktop && ref.read(bridgeApiProvider).acpHostingSupported();
    final Widget body;
    if (host != null) {
      body = FilledButton.icon(
        key: const Key('view-continue-native'),
        onPressed: () => context.pushReplacement(
          conversationRoute(
            host.appServiceKey,
            widget.threadId,
            cwd: widget.cwd,
          ),
        ),
        icon: const Icon(AppIcons.play_circle_outline),
        label: Text(l10n.nativeContinueOn(host.name)),
      );
    } else if (canHost) {
      body = OutlinedButton.icon(
        key: const Key('view-host-native'),
        onPressed: () => showHostingEditor(
          context,
          initialChoice: provider == 'opencode'
              ? 'opencode'
              : 'preset:$provider',
        ),
        icon: const Icon(AppIcons.dns_outlined),
        label: Text(l10n.nativeHostToContinue(name)),
      );
    } else {
      body = Text(
        l10n.nativeContinueElsewhere(name),
        key: const Key('view-native-elsewhere'),
        textAlign: TextAlign.center,
        style: TextStyle(color: scheme.onSurfaceVariant),
      );
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        // A bottom bar gets the page's whole height: size to the action,
        // never over the transcript.
        child: Center(heightFactor: 1, child: body),
      ),
    );
  }
}
