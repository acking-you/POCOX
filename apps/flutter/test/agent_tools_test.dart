import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/app_session/transcript_model.dart';
import 'package:pocket_codex/src/screens/app_session/transcript_rows.dart';
import 'package:pocket_codex/src/tools/share_card.dart';
import 'package:pocket_codex/src/tools/share_ref.dart';
import 'package:pocket_codex/src/tools/tools_host.dart';
import 'package:pocket_codex/src/tools/tools_settings.dart';

import 'fake_bridge_api.dart';

/// The detail a Codex `pocox.connect` call carries once it shared.
String sharedCall({String service = 'pcx:studio:port:5173'}) => jsonEncode({
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

ToolsOverview remoteShare() => ToolsOverview(
  thisDevice: 'phone',
  devices: [
    ToolsDevice(
      name: 'studio',
      online: true,
      catalog: true,
      shares: [
        ToolsShare(
          id: 's1',
          title: 'Landing page',
          path: '/',
          ports: const [
            ToolsPort(
              port: 5173,
              key: 'pcx:studio:port:5173',
              status: 'online',
            ),
          ],
          owner: _owner,
          createdMs: 0,
          expiresMs: DateTime.now().millisecondsSinceEpoch + 3600000,
        ),
      ],
    ),
  ],
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
    final other = TranscriptItem(
      id: 'other',
      type: 'mcpToolCall',
      title: 'pocox.services',
      text: '{"result": {}}',
      turnId: 't',
    );
    expect(other.share, isNull);
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

  testWidgets('an agent\'s request to share is answered from any page', (
    t,
  ) async {
    final api = FakeBridgeApi();
    await t.pumpWidget(_host(api, const SizedBox()));
    await t.pump();
    final overview = ToolsOverview(
      thisDevice: 'phone',
      devices: [
        ToolsDevice(
          name: 'studio',
          online: true,
          catalog: true,
          consents: [
            ToolsConsent(
              id: 'c1',
              owner: _owner,
              title: 'Landing page',
              ports: const [5173],
              createdMs: 0,
              expiresMs: DateTime.now().millisecondsSinceEpoch + 600000,
            ),
          ],
        ),
      ],
    );
    api.pushToolsUpdate(
      ToolsUpdate(
        overview: overview,
        consentsAdded: const [ToolsRef(device: 'studio', id: 'c1')],
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Codex · default wants to share'), findsOneWidget);
    await t.tap(find.byKey(const Key('consent-conversation-c1')));
    await t.pump();
    expect(api.toolsAnswers, [('studio', 'c1', 'allow_conversation')]);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('consent-c1')), findsNothing);
  });

  testWidgets('the agent tools switch is a setting of this computer', (
    t,
  ) async {
    final api = FakeBridgeApi();
    await t.pumpWidget(
      _host(api, const SingleChildScrollView(child: AgentToolsSettings())),
    );
    await t.pump();
    expect(find.text('http://127.0.0.1:17863/mcp'), findsOneWidget);
    await t.tap(find.byKey(const Key('tools-switch')));
    await t.pump();
    expect(api.toolsStatusValue.enabled, isFalse);
    expect(find.text('Not serving'), findsOneWidget);
  });
}
