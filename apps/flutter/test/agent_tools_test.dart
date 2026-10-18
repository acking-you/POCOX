import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/app_session/transcript_model.dart';
import 'package:pocket_codex/src/screens/app_session/transcript_rows.dart';
import 'package:pocket_codex/src/tools/preview_browser.dart';
import 'package:pocket_codex/src/tools/send_to_agent.dart';
import 'package:pocket_codex/src/tools/share_card.dart';
import 'package:pocket_codex/src/tools/share_ref.dart';
import 'package:pocket_codex/src/tools/tools_host.dart';
import 'package:pocket_codex/src/tools/tools_settings.dart';

import 'fake_bridge_api.dart';

/// The detail a Codex `pocox.connect` call carries once it shared.
String sharedCall({
  String service = 'pcx:studio:port:5173',
  bool secure = false,
}) => jsonEncode({
  'arguments': {
    'action': 'share',
    'ports': [5173],
  },
  'result': {
    'content': [
      {'type': 'text', 'text': 'Shared. pocox://open?service=$service&path=/'},
    ],
    'structuredContent': {
      'status': 'shared',
      'service': service,
      'open': 'pocox://open?service=$service&path=/',
      'share': {
        'id': 's1',
        'title': 'Landing page',
        'path': '/',
        if (secure) 'secure': true,
        'ports': [
          {'port': 5173, 'key': service, 'status': 'online'},
        ],
      },
    },
  },
});

const _owner = ToolsOwner(
  kind: 'agent',
  label: 'Codex · default',
  harness: 'codex',
  host: 'default',
  conversation: 'thread-1',
);

ToolsShare _landing() => ToolsShare(
  id: 's1',
  title: 'Landing page',
  path: '/',
  ports: const [
    ToolsPort(port: 5173, key: 'pcx:studio:port:5173', status: 'online'),
  ],
  owner: _owner,
  createdMs: 0,
  expiresMs: DateTime.now().millisecondsSinceEpoch + 3600000,
);

ToolsOverview remoteShare() => ToolsOverview(
  thisDevice: 'phone',
  devices: [
    ToolsDevice(
      name: 'studio',
      online: true,
      catalog: true,
      shares: [_landing()],
    ),
  ],
);

/// [device]'s catalog with [shares]; without a catalog (its stream dropped)
/// when [catalog] is false.
ToolsOverview _studio({
  List<ToolsShare> shares = const [],
  bool catalog = true,
}) => ToolsOverview(
  thisDevice: 'phone',
  devices: [
    ToolsDevice(
      name: 'studio',
      online: true,
      catalog: catalog,
      shares: catalog ? shares : const [],
    ),
  ],
);

ToolsConsent _consent(
  String id, {
  String title = 'Landing page',
  String? service,
}) => ToolsConsent(
  id: id,
  owner: _owner,
  title: title,
  ports: service == null ? const [5173] : const [],
  service: service,
  createdMs: 0,
  expiresMs: DateTime.now().millisecondsSinceEpoch + 600000,
);

Widget _host(FakeBridgeApi api, Widget child) => ProviderScope(
  overrides: [bridgeApiProvider.overrideWithValue(api)],
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, page) => ToolsHost(child: page!),
    home: Scaffold(body: child),
  ),
);

void main() {
  test('an agent\'s share stands alone at its tool call', () {
    final call = TranscriptItem(
      id: 'call',
      type: 'mcpToolCall',
      title: 'pocox.connect',
      text: sharedCall(),
      turnId: 't',
    );
    expect(call.share?.service, 'pcx:studio:port:5173');
    expect(call.share?.title, 'Landing page');
    // A live call often has its final text before it finishes.
    final live = TranscriptItem(
      id: 'live',
      type: 'mcpToolCall',
      title: 'pocox.connect',
      text: sharedCall(),
      turnId: 't',
      streaming: true,
    );
    expect(live.share, isNull);
    live.streaming = false;
    expect(live.share?.service, 'pcx:studio:port:5173');
    final other = TranscriptItem(
      id: 'other',
      type: 'mcpToolCall',
      title: 'pocox.services',
      text: '{"result": {}}',
      turnId: 't',
    );
    expect(other.share, isNull);
    final copied = parseOpenLink(
      'pocox://open?service=pcx:studio:port:8443&path=/&scheme=https',
    );
    expect(copied?.scheme, 'https', reason: 'a copied https link stays https');
    final tls = TranscriptItem(
      id: 'tls',
      type: 'mcpToolCall',
      title: 'pocox.connect',
      text: sharedCall(secure: true),
      turnId: 't',
    );
    expect(tls.share?.scheme, 'https');
    // The phone may open it on another port; the agent gets the share's own.
    expect(
      sharedPageUrl('http://localhost:61234/a?b=1#c', 'pcx:studio:port:5173'),
      'http://localhost:5173/a?b=1#c',
    );
    final rows = buildTranscriptRows([
      TranscriptItem(
        id: 'u',
        type: 'userMessage',
        text: 'show me',
        turnId: 't',
      ),
      other,
      call,
    ]);
    expect(rows.last, same(call), reason: 'the card is not folded into work');
  });

  testWidgets('opening another device\'s share connects it here first', (
    t,
  ) async {
    final api = FakeBridgeApi()..toolsOverviewValue = remoteShare();
    await t.pumpWidget(
      _host(
        api,
        const ShareCard(
          share: ShareRef(
            service: 'pcx:studio:port:5173',
            title: 'Landing page',
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.text('Landing page'), findsOneWidget);
    expect(find.textContaining('Codex · default'), findsOneWidget);
    await t.tap(find.byKey(const Key('share-open-pcx:studio:port:5173')));
    await t.pump();
    expect(api.toolsConnected, ['pcx:studio:port:5173']);
  });

  testWidgets('a card acts only on the share it names, not a later one', (
    t,
  ) async {
    final api = FakeBridgeApi()..toolsOverviewValue = remoteShare();
    const menu = Key('share-menu-pcx:studio:port:5173');
    for (final (id, actions) in [('s1', true), ('an-earlier-share', false)]) {
      await t.pumpWidget(
        _host(
          api,
          ShareCard(
            key: ValueKey(id),
            share: ShareRef(service: 'pcx:studio:port:5173', shareId: id),
          ),
        ),
      );
      await t.pump();
      expect(find.byKey(menu), actions ? findsOneWidget : findsNothing);
    }
  });

  testWidgets('opening a share an agent here connected takes its tunnel over', (
    t,
  ) async {
    final api = FakeBridgeApi()
      ..toolsOverviewValue = ToolsOverview(
        thisDevice: 'phone',
        devices: remoteShare().devices,
        connections: const [
          ToolsConnection(
            service: 'pcx:studio:port:5173',
            local: '127.0.0.1:5173',
            samePort: true,
            owner: _owner,
          ),
        ],
      );
    await t.pumpWidget(
      _host(
        api,
        const ShareCard(share: ShareRef(service: 'pcx:studio:port:5173')),
      ),
    );
    await t.pump();
    await t.tap(find.byKey(const Key('share-open-pcx:studio:port:5173')));
    await t.pump();
    // The agent's would end with the agent while the page is open.
    expect(api.toolsConnected, ['pcx:studio:port:5173']);
  });

  testWidgets('every pending request is asked about, on any device, until '
      'answered here', (t) async {
    // Pending before the app opened, on another device.
    final api = FakeBridgeApi()
      ..toolsOverviewValue = ToolsOverview(
        thisDevice: 'phone',
        devices: [
          ToolsDevice(
            name: 'studio',
            online: true,
            catalog: true,
            consents: [_consent('c1')],
          ),
        ],
      );
    await t.pumpWidget(_host(api, const SizedBox()));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('consent-c1')), findsOneWidget);
    // One of this device's own agents asks to connect another device's API.
    final both = ToolsOverview(
      thisDevice: 'phone',
      devices: [
        ToolsDevice(
          name: 'phone',
          online: true,
          catalog: true,
          consents: [
            _consent('c2', title: 'main', service: 'pcx:studio:api:main'),
          ],
        ),
        ToolsDevice(
          name: 'studio',
          online: true,
          catalog: true,
          consents: [_consent('c1')],
        ),
      ],
    );
    api.pushToolsUpdate(ToolsUpdate(overview: both));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('consent-c2')), findsOneWidget);
    await t.tap(find.byKey(const Key('consent-conversation-c1')));
    await t.pump();
    expect(api.toolsAnswers, [('studio', 'c1', 'allow_conversation')]);
    // A late overview still lists the answered request: it stays answered.
    api.pushToolsUpdate(ToolsUpdate(overview: both));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('consent-c1')), findsNothing);
    expect(find.byKey(const Key('consent-c2')), findsOneWidget);
  });

  testWidgets('a phone connects a new share at once and lets it go when the '
      'share ends; a desktop waits for Open', (t) async {
    const key = 'pcx:studio:port:5173';
    Future<FakeBridgeApi> arrive() async {
      final api = FakeBridgeApi()..toolsOverviewValue = _studio();
      await t.pumpWidget(_host(api, const SizedBox()));
      await t.pump();
      api.pushToolsUpdate(
        ToolsUpdate(
          overview: _studio(shares: [_landing()]),
          added: const [ToolsRef(device: 'studio', id: 's1')],
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      return api;
    }

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final desktop = await arrive();
      expect(find.byKey(const Key('share-notice-s1')), findsOneWidget);
      expect(desktop.toolsConnected, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    await t.pumpWidget(const SizedBox());

    final phone = await arrive();
    expect(phone.toolsConnected, [key]);
    // Its device's stream dropping says nothing about the share.
    phone.pushToolsUpdate(ToolsUpdate(overview: _studio(catalog: false)));
    await t.pump();
    expect(phone.toolsDisconnected, isEmpty);
    // Its device listing it no more does.
    phone.pushToolsUpdate(ToolsUpdate(overview: _studio()));
    await t.pump();
    expect(phone.toolsDisconnected, [key]);
    await t.pump(const Duration(seconds: 13));
  });

  testWidgets('the agent tools switch is a setting of this computer, kept '
      'current when it changes elsewhere', (t) async {
    final api = FakeBridgeApi();
    await t.pumpWidget(
      _host(api, const SingleChildScrollView(child: AgentToolsSettings())),
    );
    await t.pump();
    expect(find.text('http://127.0.0.1:17863/mcp'), findsOneWidget);
    // `pocox tools disable` in a terminal: the next update says so.
    api.toolsStatusValue = const AgentToolsStatus(
      supported: true,
      hosting: true,
      enabled: false,
      askBeforeSharing: true,
    );
    api.pushToolsUpdate(const ToolsUpdate(overview: ToolsOverview.empty));
    await t.pump();
    await t.pump();
    expect(find.text('Not serving'), findsOneWidget);
    await t.tap(find.byKey(const Key('tools-switch')));
    await t.pump();
    expect(api.toolsStatusValue.enabled, isTrue);
    expect(find.text('http://127.0.0.1:17863/mcp'), findsOneWidget);
  });

  testWidgets('the in-app browser opens only this device\'s loopback', (
    t,
  ) async {
    for (final url in [
      'http://localhost:5173/app?x=1',
      'https://127.0.0.1:8443/',
      'http://[::1]:3000',
    ]) {
      expect(loopbackPage(url), isNotNull, reason: url);
    }
    for (final url in [
      'https://example.com/',
      'http://localhost.example.com/',
      'http://example.com@evil.test/',
      'javascript:alert(1)',
      'file:///etc/hosts',
      'about:blank',
    ]) {
      expect(loopbackPage(url), isNull, reason: url);
    }
    expect(
      loopbackPage('http://user@localhost:5173/\\evil.test').toString(),
      'http://localhost:5173//evil.test',
      reason: 'what loads is what was checked',
    );
    await t.pumpWidget(
      _host(
        FakeBridgeApi(),
        const PreviewBrowserScreen(url: 'https://example.com/login'),
      ),
    );
    await t.pump();
    expect(find.byKey(const Key('preview-not-local')), findsOneWidget);
  });
}
