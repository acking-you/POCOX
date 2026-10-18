/// A page another device shared, opened in an in-app browser on phones. The
/// app stays in the foreground, which keeps the relay tunnel to the page
/// alive; console messages are kept so they can go to the agent.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/tools/send_to_agent.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:pocket_codex/src/widgets/links.dart';
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
  /// The page's origin, which the browser keeps to; null when the address is
  /// not one it opens.
  late final Uri? _origin = loopbackPage(widget.url);
  WebViewController? _controller;
  final List<String> _console = [];
  String? _pageTitle;
  String _current = '';
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    final origin = _origin;
    if (origin == null) return;
    _current = origin.toString();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setOnConsoleMessage((message) {
        if (message.level == JavaScriptLogLevel.error ||
            message.level == JavaScriptLogLevel.warning) {
          _console.add('[${message.level.name}] ${message.message}');
          if (_console.length > 40) _console.removeAt(0);
        }
      })
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _navigation,
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onUrlChange: (change) => _arrived(change.url),
          onPageFinished: (url) async {
            final title = await _controller?.getTitle();
            if (!mounted) return;
            _arrived(url);
            setState(
              () => _pageTitle = (title == null || title.trim().isEmpty)
                  ? null
                  : title.trim(),
            );
          },
        ),
      )
      ..loadRequest(origin);
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
        bottom: _progress > 0 && _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                  value: _progress / 100,
                  minHeight: 2,
                ),
              )
            : null,
      ),
      body: SafeArea(top: false, child: WebViewWidget(controller: controller)),
    );
  }
}
