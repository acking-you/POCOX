/// A page another device shared, opened in an in-app browser on phones. The
/// app stays in the foreground, which keeps the relay tunnel to the page
/// alive; console messages are kept so they can go to the agent.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/tools/send_to_agent.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
  late final WebViewController _controller;
  final List<String> _console = [];
  String? _pageTitle;
  String _current = '';
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _current = widget.url;
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
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onPageFinished: (url) async {
            final title = await _controller.getTitle();
            if (!mounted) return;
            setState(() {
              _current = url;
              _pageTitle = (title == null || title.trim().isEmpty)
                  ? null
                  : title.trim();
            });
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  Future<void> _menu(String choice) async {
    final l10n = AppLocalizations.of(context);
    switch (choice) {
      case 'external':
        await launchUrl(
          Uri.parse(_current),
          mode: LaunchMode.externalApplication,
        );
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
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(AppIcons.close),
          onPressed: () => context.pop(),
        ),
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
            onPressed: _controller.reload,
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
      body: SafeArea(top: false, child: WebViewWidget(controller: _controller)),
    );
  }
}
