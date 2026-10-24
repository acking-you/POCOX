import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/tools/share_card.dart';
import 'package:pocox/src/tools/share_service_form.dart';
import 'package:pocox/src/tools/tools_actions.dart';
import 'package:pocox/src/tools/tools_providers.dart';

import 'fake_bridge_api.dart';
import 'support/ui_preview.dart';

const _key = 'pcx:studio:port:5555';
const _apiKey = 'pcx:studio:port:5556';
const _agent = ToolsOwner(kind: 'agent', label: 'Codex');
const _user = ToolsOwner(kind: 'user', label: 'You');

ToolsShare _video({bool? persistent = false, bool companion = false}) =>
    ToolsShare(
      id: 'video',
      title: 'Videos',
      path: '/static/?sort=name#latest',
      secure: true,
      owner: _agent,
      createdMs: 1,
      persistent: persistent,
      ports: [
        const ToolsPort(port: 5555, key: _key, status: 'online'),
        if (companion)
          const ToolsPort(port: 5556, key: _apiKey, status: 'online'),
      ],
    );

ToolsOverview _overview(
  ToolsShare share, {
  bool online = true,
  List<ToolsConnection> connections = const [],
}) => ToolsOverview(
  thisDevice: 'phone',
  connections: connections,
  devices: [
    ToolsDevice(
      name: 'studio',
      online: online,
      catalog: online,
      shares: [share],
    ),
  ],
);

Widget _app(
  FakeBridgeApi api,
  ToolsOverview overview,
  Widget child, {
  String locale = 'en',
  double scale = 1,
}) => ProviderScope(
  overrides: [
    bridgeApiProvider.overrideWithValue(api),
    toolsOverviewProvider.overrideWithValue(overview),
  ],
  child: MaterialApp(
    locale: Locale(locale),
    theme: lightTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => RepaintBoundary(
      key: previewKey,
      child: MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
    home: Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ),
    ),
  ),
);

class _DelayedApi extends FakeBridgeApi {
  final pending = Completer<ToolsConnection>();
  @override
  Future<ToolsConnection> toolsConnect(String service, {int? localPort}) {
    toolsConnected.add(service);
    return pending.future;
  }
}

class _ShareApi extends FakeBridgeApi {
  String? device, path, title;
  bool? secure;
  bool fail = true;
  @override
  Future<ToolsShared> toolsShareOn(
    String device,
    List<int> ports, {
    String? title,
    String? path,
    bool secure = false,
  }) async {
    this.device = device;
    this.path = path;
    this.title = title;
    this.secure = secure;
    if (fail) throw StateError('Service is not running');
    return super.toolsShareOn(
      device,
      ports,
      title: title,
      path: path,
      secure: secure,
    );
  }
}

void main() {
  setUpAll(loadPreviewFonts);

  test(
    'local addresses preserve paths and reject remote or credentialed URLs',
    () {
      expect(parseShareAddress('5555').toString(), 'http://localhost:5555/');
      expect(
        parseShareAddress(
          'https://localhost:5555/static/a%20b?q=a%2Fb#latest',
        ).toString(),
        'https://localhost:5555/static/a%20b?q=a%2Fb#latest',
      );
      expect(parseShareAddress('http://[::1]:5555/static/')?.port, 5555);
      for (final value in [
        '0',
        '65536',
        '',
        'https://example.com',
        'http://192.168.0.1:80',
        'http://user:pass@localhost:5555/',
        'file:///videos',
      ]) {
        expect(parseShareAddress(value), isNull, reason: value);
      }
    },
  );

  test('only explicit persistence or old user ownership means saved', () {
    expect(_video().kept, isFalse);
    expect(_video(persistent: null).kept, isFalse);
    expect(_video(persistent: true).kept, isTrue);
  });

  testWidgets('no-expiry agent shares offer saving directly on dense cards', (
    t,
  ) async {
    final api = FakeBridgeApi();
    final video = _video();
    await t.pumpWidget(
      _app(
        api,
        _overview(video),
        ShareCard(share: shareRefOf(video), dense: true),
      ),
    );
    await t.tap(find.byKey(const Key('share-keep-$_key')));
    await t.pumpAndSettle();
    expect(api.toolsKept, [('studio', 'video')]);
    expect(find.text('Temporary · ends when the agent stops'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'repeated opens share one pending mapping and use the live URL',
    (t) async {
      final opened = <String>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'launch') {
          opened.add((call.arguments as Map)['url'] as String);
        }
        return true;
      });
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final api = _DelayedApi();
      final video = _video(persistent: true);
      await t.pumpWidget(
        _app(
          api,
          _overview(video),
          Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => openShare(
                context,
                ref,
                const ShareRef(service: _key, path: '/old'),
              ),
              child: const Text('Open link'),
            ),
          ),
        ),
      );
      await t.tap(find.text('Open link'));
      await t.tap(find.text('Open link'));
      expect(api.toolsConnected, [_key]);
      expect(opened, isEmpty);
      api.pending.complete(
        const ToolsConnection(
          service: _key,
          local: '127.0.0.1:61321',
          samePort: false,
          owner: _user,
        ),
      );
      await t.pumpAndSettle();
      expect(opened, ['https://localhost:61321/static/?sort=name#latest']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'a companion mapped to another port does not open a broken page',
    (t) async {
      final api = FakeBridgeApi();
      final video = _video(companion: true);
      await t.pumpWidget(
        _app(
          api,
          _overview(
            video,
            connections: const [
              ToolsConnection(
                service: _apiKey,
                local: '127.0.0.1:61322',
                samePort: false,
                owner: _user,
              ),
            ],
          ),
          ShareCard(share: shareRefOf(video)),
        ),
      );
      await t.tap(find.byKey(const Key('share-open-$_key')));
      await t.pumpAndSettle();
      expect(api.toolsConnected, [_key]);
      expect(find.textContaining('5556'), findsWidgets);
      expect(find.textContaining('Could not open'), findsOneWidget);
    },
  );

  testWidgets(
    'sharing targets the selected host and retains the URL after failure',
    (t) async {
      final api = _ShareApi();
      await t.pumpWidget(
        _app(
          api,
          ToolsOverview.empty,
          const ShareServiceForm(device: 'studio'),
        ),
      );
      await t.enterText(
        find.byKey(const Key('share-address')),
        'https://localhost:5555/static/?q=a%2Fb#last',
      );
      await t.enterText(find.byKey(const Key('share-title')), 'My videos');
      await t.tap(find.byKey(const Key('share-submit')));
      await t.pumpAndSettle();
      expect(api.device, 'studio');
      expect(api.path, '/static/?q=a%2Fb#last');
      expect(api.title, 'My videos');
      expect(api.secure, isTrue);
      expect(find.byKey(const Key('share-error')), findsOneWidget);
      expect(
        find.text('https://localhost:5555/static/?q=a%2Fb#last'),
        findsOneWidget,
      );
      expect(
        t.widget<FilledButton>(find.byKey(const Key('share-submit'))).onPressed,
        isNotNull,
      );
    },
  );

  for (final (locale, width, scale) in [
    ('en', 390.0, 1.0),
    ('zh', 320.0, 1.5),
    ('en', 900.0, 1.0),
  ]) {
    testWidgets('share form fits and saves on $locale $width at $scale', (
      t,
    ) async {
      t.view.physicalSize = Size(width, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final api = _ShareApi()..fail = false;
      await t.pumpWidget(
        _app(
          api,
          ToolsOverview.empty,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showShareServiceForm(context, 'studio'),
              child: const Text('Share'),
            ),
          ),
          locale: locale,
          scale: scale,
        ),
      );
      await t.tap(find.text('Share'));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const Key('share-address')),
        'http://localhost:5555/static/',
      );
      await t.enterText(
        find.byKey(const Key('share-title')),
        locale == 'zh' ? '视频库' : 'Video library',
      );
      await t.ensureVisible(find.byKey(const Key('share-submit')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await capturePreview(t, 'share-form-$locale-${width.toInt()}');
      await t.tap(find.byKey(const Key('share-submit')));
      await t.pumpAndSettle();
      expect(api.toolsSharedOn.single.$1, 'studio');
      expect(api.toolsSharedOn.single.$2, [5555]);
      expect(find.byType(ShareServiceForm), findsNothing);
    });

    testWidgets('saved and offline cards fit $locale $width at $scale', (
      t,
    ) async {
      t.view.physicalSize = Size(width, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final video = _video(persistent: true);
      await t.pumpWidget(
        _app(
          FakeBridgeApi(),
          _overview(video, online: false),
          ShareCard(share: shareRefOf(video), dense: true),
          locale: locale,
          scale: scale,
        ),
      );
      await t.pumpAndSettle();
      expect(
        t
            .widget<FilledButton>(find.byKey(const Key('share-open-$_key')))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const Key('share-keep-$_key')), findsNothing);
      expect(t.takeException(), isNull);
      await capturePreview(t, 'saved-service-$locale-${width.toInt()}');
    });
  }
}
