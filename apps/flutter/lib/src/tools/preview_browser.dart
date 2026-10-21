/// A page another device shared, opened in an in-app browser on phones. The
/// app stays in the foreground, which keeps the relay tunnel to the page
/// alive; console messages are kept so they can go to the agent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/tools/send_to_agent.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/widgets/busy_label.dart';
import 'package:pocox/src/widgets/error_details.dart';
import 'package:pocox/src/widgets/links.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// [url] as the in-app browser opens it: an `http` or `https` address on this
/// device's loopback, where shares are connected, rebuilt from its parts so
/// what loads is what was checked. Null for anything else, which never loads.
Uri? loopbackPage(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasAuthority) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  final host = uri.host.toLowerCase();
  if (host != 'localhost' && host != '127.0.0.1' && host != '::1') return null;
  return Uri(
    scheme: uri.scheme,
    host: host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path.isEmpty ? '/' : uri.path,
    query: uri.hasQuery ? uri.query : null,
    fragment: uri.hasFragment ? uri.fragment : null,
  );
}

/// Why a page did not load, as the browser tells the user.
enum _Failure {
  /// This device does not trust the page's certificate (a self-signed one).
  certificate,

  /// Nothing answered: the connection was refused, dropped or timed out.
  noAnswer,

  /// The page's web content process ended.
  stopped,

  /// Anything else, which the platform's own words describe.
  other,
}

/// What a main-frame [error] means for the page; null for a load that was
/// interrupted rather than failed: a newer navigation took over, a policy
/// decision ended it, or a plug-in took it.
_Failure? _failureOf(WebResourceError error) {
  final byType = switch (error.errorType) {
    WebResourceErrorType.failedSslHandshake => _Failure.certificate,
    WebResourceErrorType.connect ||
    WebResourceErrorType.timeout ||
    WebResourceErrorType.io ||
    WebResourceErrorType.hostLookup => _Failure.noAnswer,
    WebResourceErrorType.webContentProcessTerminated => _Failure.stopped,
    _ => null,
  };
  if (byType != null) return byType;
  // WebKit types only its own errors; NSURLErrorDomain codes come bare.
  return switch (error.errorCode) {
    -999 || 102 || 204 => null,
    -1201 || -1202 || -1203 || -1204 => _Failure.certificate,
    -1001 || -1004 || -1005 || -1014 => _Failure.noAnswer,
    _ => _Failure.other,
  };
}

/// A page that did not load.
class _Failed {
  const _Failed(this.kind, this.url, this.reason, this.detail);

  final _Failure kind;

  /// The address that did not load, on the page's origin: what Retry loads
  /// and the system browser opens.
  final String url;

  /// The platform's own words for it, possibly empty.
  final String reason;

  /// [reason] with the platform's code: Error details, and the agent's note.
  final String detail;
}

/// The in-app browser.
class PreviewBrowserScreen extends ConsumerStatefulWidget {
  /// Opens [url]; [serviceKey] is the share it belongs to.
  const PreviewBrowserScreen({
    super.key,
    required this.url,
    this.title,
    this.serviceKey,
  });

  /// The local address of the shared page.
  final String url;

  /// What the share is called, until the page names itself.
  final String? title;

  /// The shared port's key.
  final String? serviceKey;

  @override
  ConsumerState<PreviewBrowserScreen> createState() =>
      _PreviewBrowserScreenState();
}

class _PreviewBrowserScreenState extends ConsumerState<PreviewBrowserScreen> {
  /// The JavaScript channel the title watch reports on.
  static const _titleChannel = 'PocoxTitle';

  /// What the title watch signs its reports with. Every frame on the page
  /// can post to [_titleChannel], but the key lives only in the watch this
  /// browser runs in the main frame, so a frame from another site cannot
  /// rename the page.
  final String _watchKey = _newWatchKey();

  static String _newWatchKey() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// Reports `document.title` on [_titleChannel] at once and whenever it
  /// changes, as single-page apps and scripts change it; installed once per
  /// document, and run again to report a document the back/forward cache
  /// brought back with its watch.
  /// The report carries the title itself: WebKit hands a title to the web
  /// view in a later task, so reading it back on a report, or when a load
  /// finishes, can find the previous one.
  String get _titleWatch =>
      '''
(() => {
  if (window.__pocoxTitleWatch) return window.__pocoxTitleWatch(true);
  let last;
  const report = (again) => {
    if (!again && document.title === last) return;
    last = document.title;
    $_titleChannel.postMessage(JSON.stringify(['$_watchKey', last]));
  };
  window.__pocoxTitleWatch = report;
  new MutationObserver(() => report(false)).observe(
    document.head || document.documentElement,
    {subtree: true, childList: true, characterData: true});
  report(true);
})();
''';

  /// The page's origin, which the browser keeps to; null when the address is
  /// not one it opens.
  late final Uri? _origin = loopbackPage(widget.url);
  WebViewController? _controller;
  final List<String> _console = [];
  String? _pageTitle;
  String _current = '';
  int _progress = 0;

  /// Why the page did not load, shown in its place until a load succeeds.
  _Failed? _failed;

  /// Whether the load under way failed: Android still finishes such a load,
  /// on an error page of its own.
  bool _loadFailed = false;

  /// Whether Retry's load is under way.
  bool _retrying = false;

  /// Whether setup finished; a Retry after a failed setup sets up again.
  bool _ready = false;
  bool _channelAdded = false;

  @override
  void initState() {
    super.initState();
    final origin = _origin;
    if (origin == null) return;
    _current = origin.toString();
    final controller = _controller = WebViewController();
    unawaited(_open(controller, origin));
  }

  /// Set the browser up, then load: the console capture and the title watch
  /// are in place before the first page starts rather than racing it.
  Future<void> _open(WebViewController controller, Uri origin) async {
    try {
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setOnConsoleMessage(_consoleMessage);
      // A channel can be added once; a setup run again keeps it.
      if (!_channelAdded) {
        await controller.addJavaScriptChannel(
          _titleChannel,
          onMessageReceived: _titleReport,
        );
        _channelAdded = true;
      }
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _navigation,
          onPageStarted: (_) => _loadFailed = false,
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onUrlChange: (change) => _arrived(change.url),
          onPageFinished: _finished,
          onWebResourceError: _loadError,
        ),
      );
      _ready = true;
      if (mounted) await controller.loadRequest(origin);
    } catch (error) {
      if (mounted) _fail(_Failed(_Failure.other, _current, '', '$error'));
    }
  }

  void _consoleMessage(JavaScriptConsoleMessage message) {
    if (message.level != JavaScriptLogLevel.error &&
        message.level != JavaScriptLogLevel.warning) {
      return;
    }
    _console.add('[${message.level.name}] ${message.message}');
    if (_console.length > 40) _console.removeAt(0);
  }

  bool _ownOrigin(Uri? uri) {
    final origin = _origin;
    return origin != null &&
        uri != null &&
        uri.scheme == origin.scheme &&
        uri.host.toLowerCase() == origin.host &&
        uri.port == origin.port;
  }

  /// The page stays on its own origin; another web address opens in the
  /// system browser, and anything else does not open.
  NavigationDecision _navigation(NavigationRequest request) {
    if (!request.isMainFrame) return NavigationDecision.navigate;
    final target = Uri.tryParse(request.url);
    if (_ownOrigin(target)) return NavigationDecision.navigate;
    if (mounted && (target?.scheme == 'http' || target?.scheme == 'https')) {
      unawaited(openWebUrl(context, request.url));
    }
    return NavigationDecision.prevent;
  }

  /// The page moved to [url]: kept only on its own origin, so what is copied,
  /// opened elsewhere or sent to the agent is always this device's loopback.
  void _arrived(String? url) {
    if (url == null || !mounted || !_ownOrigin(Uri.tryParse(url))) return;
    setState(() => _current = url);
  }

  /// A load finished, which clears a failure shown; Android also finishes a
  /// failed load, and that failure stands.
  void _finished(String url) {
    if (!mounted || _loadFailed) return;
    setState(() {
      _failed = null;
      _retrying = false;
    });
    _arrived(url);
    unawaited(_watchTitle());
  }

  /// A load failed. Only the main frame's failures replace the page: a
  /// subframe or subresource that fails leaves the rest of it to show.
  void _loadError(WebResourceError error) {
    if (!mounted || error.isForMainFrame != true) return;
    final kind = _failureOf(error);
    if (kind == null) {
      // Interrupted, not failed; a retry it ended no longer runs.
      if (_retrying) setState(() => _retrying = false);
      return;
    }
    _loadFailed = true;
    final failing = error.url;
    final url = failing != null && _ownOrigin(Uri.tryParse(failing))
        ? failing
        : _current;
    final type = error.errorType;
    final code = '${error.errorCode}${type == null ? '' : ' ${type.name}'}';
    final reason = error.description.trim();
    _fail(
      _Failed(kind, url, reason, reason.isEmpty ? code : '$reason ($code)'),
    );
  }

  void _fail(_Failed failed) {
    setState(() {
      _failed = failed;
      _retrying = false;
      _current = failed.url;
      // The page that failed is not the one the old title named.
      _pageTitle = null;
    });
  }

  /// Load the page that failed again; its failure stays until it loads.
  Future<void> _retry() async {
    final controller = _controller;
    final failed = _failed;
    if (controller == null || failed == null || _retrying) return;
    setState(() => _retrying = true);
    try {
      if (_ready) {
        await controller.loadRequest(Uri.parse(failed.url));
      } else {
        await _open(controller, Uri.parse(failed.url));
      }
    } catch (_) {
      if (mounted) setState(() => _retrying = false);
    }
  }

  /// Follow the page's title with the watch; a document that runs no script
  /// is named by the web view's title, read once.
  Future<void> _watchTitle() async {
    try {
      await _controller?.runJavaScript(_titleWatch);
    } catch (_) {
      try {
        _adoptTitle(await _controller?.getTitle());
      } catch (_) {
        // No title to read: the share's name stays.
      }
    }
  }

  /// A report from the title watch, which counts only with [_watchKey].
  void _titleReport(JavaScriptMessage message) {
    final Object? report;
    try {
      report = jsonDecode(message.message);
    } catch (_) {
      return;
    }
    if (report case [
      final String key,
      final String title,
    ] when key == _watchKey) {
      _adoptTitle(title);
    }
  }

  /// Adopt the page's own title; the share's name stands while it has none.
  void _adoptTitle(String? title) {
    if (!mounted || _failed != null) return;
    final name = title?.trim() ?? '';
    setState(() => _pageTitle = name.isEmpty ? null : name);
  }

  Future<void> _menu(String choice) async {
    final l10n = AppLocalizations.of(context);
    switch (choice) {
      case 'external':
        await openWebUrl(context, _current);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: _current));
        if (mounted) showToastOk(context, l10n.copied);
      case 'send':
        await sendPreviewToAgent(
          context,
          ref,
          serviceKey: widget.serviceKey,
          title: _pageTitle ?? widget.title ?? _current,
          url: _current,
          console: List.of(_console),
          failure: _failed?.detail,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final controller = _controller;
    final close = IconButton(
      icon: const Icon(AppIcons.close),
      onPressed: () => context.pop(),
    );
    if (controller == null) {
      return Scaffold(
        appBar: AppBar(leading: close),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                key: const Key('preview-not-local'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    AppIcons.link_off_outlined,
                    size: 32,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.browserNotLocal,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final failed = _failed;
    return Scaffold(
      appBar: AppBar(
        leading: close,
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _pageTitle ?? widget.title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            Text(
              _current,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          // A failed page has its own Retry.
          if (failed == null)
            IconButton(
              tooltip: l10n.browserReload,
              icon: const Icon(AppIcons.refresh),
              onPressed: controller.reload,
            ),
          PopupMenuButton<String>(
            icon: const Icon(AppIcons.more_horiz),
            onSelected: _menu,
            itemBuilder: (context) => [
              if (widget.serviceKey != null)
                PopupMenuItem(
                  value: 'send',
                  child: Text(l10n.browserSendToAgent),
                ),
              PopupMenuItem(
                value: 'external',
                child: Text(l10n.browserOpenExternal),
              ),
              PopupMenuItem(value: 'copy', child: Text(l10n.toolsCopyLink)),
            ],
          ),
        ],
        bottom: failed == null && _progress > 0 && _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress / 100,
                  minHeight: 2,
                ),
              )
            : null,
      ),
      body: SafeArea(
        top: false,
        // The web view stays mounted under a failure, so a retry that loads
        // shows in the same view rather than a new one.
        child: IndexedStack(
          index: failed == null ? 0 : 1,
          sizing: StackFit.expand,
          children: [
            WebViewWidget(controller: controller),
            if (failed != null)
              _FailurePanel(
                failed: failed,
                retrying: _retrying,
                onRetry: _retry,
                onOpen: () => openWebUrl(context, failed.url),
              )
            else
              const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}

/// A page that did not load: why, in words, Retry and the system browser
/// as ways on, and the platform's own words folded away.
class _FailurePanel extends StatelessWidget {
  const _FailurePanel({
    required this.failed,
    required this.retrying,
    required this.onRetry,
    required this.onOpen,
  });

  final _Failed failed;
  final bool retrying;
  final VoidCallback onRetry;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final (icon, cause) = switch (failed.kind) {
      _Failure.certificate => (
        AppIcons.gpp_bad_outlined,
        l10n.browserFailedCertificate,
      ),
      _Failure.noAnswer => (
        AppIcons.link_off_outlined,
        l10n.browserFailedNoAnswer,
      ),
      _Failure.stopped => (AppIcons.error_outline, l10n.browserFailedStopped),
      _Failure.other => (
        AppIcons.error_outline,
        failed.reason.isEmpty ? l10n.browserFailedOther : failed.reason,
      ),
    };
    return Center(
      key: const Key('preview-failed'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 28, color: muted),
              const SizedBox(height: 12),
              Text(
                l10n.browserFailed,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                cause,
                key: const Key('preview-failed-cause'),
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton(
                    key: const Key('preview-retry'),
                    // Its working colours while it retries, not greyed out.
                    style: retrying
                        ? FilledButton.styleFrom(
                            disabledBackgroundColor: scheme.primary,
                            disabledForegroundColor: scheme.onPrimary,
                          )
                        : null,
                    onPressed: retrying ? null : onRetry,
                    child: BusyLabel(
                      busy: retrying,
                      icon: AppIcons.refresh,
                      label: l10n.retry,
                      busyLabel: l10n.browserRetrying,
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const Key('preview-open-external'),
                    onPressed: onOpen,
                    icon: const Icon(AppIcons.open_in_new, size: 16),
                    label: Text(l10n.browserOpenExternal),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ErrorDetails(detail: failed.detail),
            ],
          ),
        ),
      ),
    );
  }
}
