// A native OpenCode host replaced with another model configuration (Apply
// restarts it): after the controller reconnects, the composer's model menu
// offers the new host's catalog, a model the new host no longer offers is no
// longer selected (here or as the default new conversations inherit), and a
// send goes to the replacement connection without it. Text and attachments
// stay; nothing is sent by itself. A model list answered by the previous
// connection after the reconnect changes nothing.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';

const _svc = 'pcx:local:opencode:opencode';

const _mimo = ModelInfo(
  id: 'opencode/mimo-free',
  displayName: 'MiMo Free',
  description: 'OpenCode Zen',
);
const _other = ModelInfo(
  id: 'opencode/other-free',
  displayName: 'Other Free',
  description: 'OpenCode Zen',
);
const _claude = ModelInfo(
  id: 'anthropic/claude-opus',
  displayName: 'Claude Opus',
  description: 'Anthropic',
);

Future<void> _frames(WidgetTester t, [int count = 12]) async {
  for (var i = 0; i < count; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// A desktop composer on a connected OpenCode host whose catalog offers
/// MiMo, picked earlier on this service (the inherited new-conversation
/// default).
Future<(FakeBridgeApi, ProviderContainer)> _open(WidgetTester t) async {
  t.view.physicalSize = const Size(1400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = FakeBridgeApi();
  api.acpCapabilities[_svc] = negotiatedOpenCodeCapabilities(
    modelCatalog: true,
  );
  api.modelLists[_svc] = const [_mimo, _other];
  await api.appConnect(_svc, 28080);
  final container = ProviderContainer(
    overrides: [bridgeApiProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  container.read(sessionDefaultsProvider(_svc).notifier).state =
      const SessionDefaults(model: _mimo);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppSessionScreen(serviceKey: _svc, cwd: '/work'),
      ),
    ),
  );
  await _frames(t);
  return (api, container);
}

Finder _chipText(String text) => find.descendant(
  of: find.byKey(const Key('model-chip')),
  matching: find.textContaining(text),
);

Finder _menuItem(ModelInfo m) => find.byKey(Key('model-menu-item-${m.id}'));

Future<void> _toggleMenu(WidgetTester t) async {
  await t.tap(find.byKey(const Key('model-chip')));
  await _frames(t, 4);
}

Future<void> _type(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const Key('composer-input')), text);
  await t.pump();
}

String _composer(WidgetTester t) => t
    .widget<TextField>(find.byKey(const Key('composer-input')))
    .controller!
    .text;

/// The host is replaced (Apply): its event stream ends, the new host offers
/// only [models], and the screen's bounded reconnect reaches it.
Future<void> _replaceHost(
  WidgetTester t,
  FakeBridgeApi api,
  List<ModelInfo> models,
) async {
  api.modelLists[_svc] = models;
  api.pushEvent(
    _svc,
    const AppEvent(kind: 'acp/host/state', raw: '{"connected":false}'),
  );
  await _frames(t);
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('after the host is replaced the menu shows its catalog and a '
      'withdrawn model is no longer selected or sent', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final (api, container) = await _open(t);
      expect(_chipText('MiMo Free'), findsOneWidget);
      await _type(t, 'keep this');
      final connects = api.appConnectCount;

      await _replaceHost(t, api, const [_claude]);
      expect(api.appConnectCount, greaterThan(connects));

      // The new host's catalog, without the previous selection.
      expect(_chipText('MiMo Free'), findsNothing);
      expect(_chipText('Default model'), findsOneWidget);
      await _toggleMenu(t);
      expect(_menuItem(_claude), findsOneWidget);
      expect(_menuItem(_mimo), findsNothing);
      expect(_menuItem(_other), findsNothing);
      await _toggleMenu(t);
      // New conversations no longer inherit it either.
      expect(container.read(sessionDefaultsProvider(_svc)).model, isNull);
      // The draft is untouched and nothing was sent by itself.
      expect(_composer(t), 'keep this');
      expect(api.threadStartCalls, isEmpty);
      expect(api.turnStartCount, 0);

      await t.tap(find.byKey(const Key('send-btn')));
      await _frames(t);
      expect(api.threadStartCalls, [_svc]);
      expect(api.lastModel, isNull);
      expect(api.turnStartCount, 1);
      expect(api.lastTurnModel, isNull);
      expect(api.lastTurnText, 'keep this');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a model the replacement still offers stays selected and is '
      'sent', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final (api, container) = await _open(t);
      await _replaceHost(t, api, const [_mimo, _claude]);
      expect(_chipText('MiMo Free'), findsOneWidget);
      expect(container.read(sessionDefaultsProvider(_svc)).model, _mimo);
      await _type(t, 'hi');
      await t.tap(find.byKey(const Key('send-btn')));
      await _frames(t);
      expect(api.lastModel, _mimo.id);
      expect(api.lastTurnModel, _mimo.id);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a model list answered by the previous connection after the '
      'reconnect changes nothing', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final (api, _) = await _open(t);
      // Another generation answers: the screen asks for its catalog, but
      // this answer still comes from the previous host and is held.
      final stale = Completer<void>();
      api.modelListGate = stale;
      api.pushEvent(
        _svc,
        const AppEvent(
          kind: 'acp/host/state',
          raw: '{"generation":2,"connected":true}',
        ),
      );
      await _frames(t, 2);
      final asked = api.modelListServices.length;
      // The host is then replaced; the reconnect's own read answers first.
      api.modelListGate = null;
      await _replaceHost(t, api, const [_claude]);
      expect(api.modelListServices.length, greaterThan(asked));
      expect(_chipText('MiMo Free'), findsNothing);
      // The previous connection's answer arrives last.
      stale.complete();
      await _frames(t);
      // The menu shows the list it holds (any further read is held): the
      // replacement's, untouched by the late answer.
      final held = Completer<void>();
      addTearDown(held.complete);
      api.modelListGate = held;
      await _toggleMenu(t);
      expect(_menuItem(_claude), findsOneWidget);
      expect(_menuItem(_mimo), findsNothing);
      await _toggleMenu(t);
      expect(_chipText('MiMo Free'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a send racing the reconnect\'s catalog read returns a '
      'withdrawn model\'s message to its draft', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final (api, _) = await _open(t);
      // The connection moved (another generation) and its catalog read is
      // still out when the user sends.
      final gate = Completer<void>();
      api.modelListGate = gate;
      api.modelLists[_svc] = const [_claude];
      api.pushEvent(
        _svc,
        const AppEvent(
          kind: 'acp/host/state',
          raw: '{"generation":2,"connected":true}',
        ),
      );
      await _frames(t, 2);
      expect(_chipText('MiMo Free'), findsOneWidget);
      await _type(t, 'hold on');
      await t.tap(find.byKey(const Key('send-btn')));
      await _frames(t, 2);
      gate.complete();
      await _frames(t);
      expect(api.threadStartCalls, isEmpty);
      expect(api.turnStartCount, 0);
      expect(_composer(t), 'hold on');
      expect(
        find.textContaining('no longer offers the selected model'),
        findsWidgets,
      );
      expect(_chipText('MiMo Free'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
