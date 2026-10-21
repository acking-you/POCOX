import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/tools/preview_browser.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// A web view the test drives: it records what the browser asks of it and
/// hands the test the navigation callbacks the platform would call.
class _FakeWebView extends WebViewPlatform {
  late _Controller controller;
  late _Delegate delegate;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller = _Controller(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => delegate = _Delegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _Widget(params);
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();

  final loads = <Uri>[];
  final channels = <String, void Function(JavaScriptMessage)>{};
  final scripts = <String>[];

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setOnConsoleMessage(
    void Function(JavaScriptConsoleMessage consoleMessage) onConsoleMessage,
  ) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async =>
      channels[params.name] = params.onMessageReceived;

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async =>
      loads.add(params.uri);

  @override
  Future<void> runJavaScript(String javaScript) async =>
      scripts.add(javaScript);
}

class _Delegate extends PlatformNavigationDelegate {
  _Delegate(super.params) : super.implementation();

  late PageEventCallback started;
  late PageEventCallback finished;
  late WebResourceErrorCallback failed;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback _) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async =>
      started = onPageStarted;

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async =>
      finished = onPageFinished;

  @override
  Future<void> setOnProgress(ProgressCallback _) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onError) async =>
      failed = onError;

  @override
  Future<void> setOnUrlChange(UrlChangeCallback _) async {}
}

class _Widget extends PlatformWebViewWidget {
  _Widget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: Key('fake-webview'));
}

const _page = 'https://localhost:8443/app';

Future<_FakeWebView> _open(WidgetTester t) async {
  final web = _FakeWebView();
  WebViewPlatform.instance = web;
  await t.pumpWidget(
    const ProviderScope(
      child: MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PreviewBrowserScreen(url: _page, title: 'Landing page'),
      ),
    ),
  );
  await t.pump();
  return web;
}

WebResourceError _error(
  int code, {
  bool mainFrame = true,
  String url = _page,
}) => WebResourceError(
  errorCode: code,
  description: 'platform words $code',
  isForMainFrame: mainFrame,
  url: url,
);

void main() {
  testWidgets('a page that does not load says why, retries and opens '
      'elsewhere; other errors leave it alone', (t) async {
    final launches = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async {
        if (call.method == 'launch') {
          launches.add((call.arguments as Map)['url'] as String);
        }
        return true;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        null,
      ),
    );
    final l10n = lookupAppLocalizations(const Locale('en'));
    final web = await _open(t);
    expect(web.controller.loads, [Uri.parse(_page)]);
    web.delegate.started(_page);

    // A failed image, and a navigation a newer one took over, are no
    // page failures.
    web.delegate.failed(
      _error(-1100, mainFrame: false, url: 'https://localhost:8443/logo.png'),
    );
    web.delegate.failed(_error(-999));
    await t.pump();
    expect(find.byKey(const Key('fake-webview')), findsOneWidget);
    expect(find.byKey(const Key('preview-failed')), findsNothing);

    // WKWebView refusing a self-signed certificate.
    web.delegate.failed(_error(-1202));
    await t.pump();
    expect(find.byKey(const Key('fake-webview')), findsNothing);
    expect(find.text(l10n.browserFailedCertificate), findsOneWidget);
    expect(
      find.byTooltip(l10n.browserReload),
      findsNothing,
      reason: 'Retry replaces it',
    );

    await t.tap(find.byKey(const Key('preview-open-external')));
    await t.pump();
    expect(launches, [_page]);

    await t.tap(find.byKey(const Key('preview-retry')));
    await t.pump();
    expect(web.controller.loads, [Uri.parse(_page), Uri.parse(_page)]);
    expect(find.text(l10n.browserRetrying), findsOneWidget);

    // The retry fails differently: the panel says so and can retry again.
    web.delegate.started(_page);
    web.delegate.failed(_error(-1004));
    await t.pump();
    expect(find.text(l10n.browserFailedNoAnswer), findsOneWidget);
    expect(find.text(l10n.browserRetrying), findsNothing);

    await t.tap(find.byKey(const Key('preview-retry')));
    await t.pump();
    web.delegate.started(_page);
    web.delegate.finished(_page);
    await t.pump();
    expect(find.byKey(const Key('preview-failed')), findsNothing);
    expect(find.byKey(const Key('fake-webview')), findsOneWidget);
    expect(find.byTooltip(l10n.browserReload), findsOneWidget);
  });

  testWidgets('the header follows the title the page reports', (t) async {
    final web = await _open(t);
    web.delegate.started(_page);
    web.delegate.finished(_page);
    await t.pump();
    expect(find.text('Landing page'), findsOneWidget);

    // The watch the browser ran in the page reports with its key.
    final key = RegExp(
      r"stringify\(\['([0-9a-f]{32})'",
    ).firstMatch(web.controller.scripts.single)!.group(1)!;
    final report = web.controller.channels['PocoxTitle']!;
    report(JavaScriptMessage(message: jsonEncode([key, 'Vite App'])));
    await t.pump();
    expect(find.text('Vite App'), findsOneWidget);

    // A frame inside the page has no key, so it cannot rename the page.
    report(JavaScriptMessage(message: jsonEncode(['0' * 32, 'Bank login'])));
    report(const JavaScriptMessage(message: 'Bank login'));
    await t.pump();
    expect(find.text('Bank login'), findsNothing);
    expect(find.text('Vite App'), findsOneWidget);

    // A page that fails is not named by the one before it.
    web.delegate.started('https://localhost:8443/next');
    web.delegate.failed(_error(-1004, url: 'https://localhost:8443/next'));
    await t.pump();
    expect(find.text('Vite App'), findsNothing);
    expect(find.text('Landing page'), findsOneWidget);
  });
}
