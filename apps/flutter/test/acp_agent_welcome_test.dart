// A new ACP conversation without a setup step: the view opens the agent's
// session by itself once it has a project, shows where that stands (opening,
// ready, failed) in one welcome card and one composer segment, and every
// completion belongs to the draft, connection and host generation it was
// started for. Also: a first run with no projects can still choose a folder.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/screen_harness.dart';

const _acp = 'pcx:dev:acp:claude';

final _caps = negotiatedAcpCapabilities(
  providerName: 'Claude',
  profileId: 'claude',
);

const _settings = SessionSettings(
  configOptions: [
    SessionConfigOption(
      id: 'model',
      name: 'Model',
      category: 'model',
      currentValue: 'sonnet',
      values: [
        SessionConfigValue(value: 'sonnet', name: 'Sonnet'),
        SessionConfigValue(value: 'opus', name: 'Opus'),
      ],
    ),
    SessionConfigOption(
      id: 'mode',
      name: 'Mode',
      category: 'mode',
      currentValue: 'default',
      values: [
        SessionConfigValue(value: 'default', name: 'Default'),
        SessionConfigValue(value: 'plan', name: 'Plan'),
      ],
    ),
  ],
);

FakeBridgeApi _api() => FakeBridgeApi()
  ..acpCapabilities[_acp] = _caps
  ..newSessionSettings = _settings;

/// Bounded frames: an opening animates for as long as it runs.
Future<void> _frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _open(
  WidgetTester t,
  FakeBridgeApi api, {
  String? cwd,
  Size size = const Size(1400, 900),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await api.appConnect(_acp, 28080);
  await t.pumpWidget(
    host(
      AppSessionScreen(serviceKey: _acp, cwd: cwd),
      api,
      locale: const Locale('en'),
    ),
  );
  await _frames(t);
}

Future<void> _type(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const Key('composer-input')), text);
  await t.pump();
}

Future<void> _pickProject(WidgetTester t, String path) async {
  await t.tap(find.byKey(const Key('project-switcher-btn')));
  await _frames(t);
  final item = find.byKey(Key('project-menu-item-$path'));
  expect(item, findsOneWidget);
  await t.tap(item);
  await _frames(t);
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets(
    'ACP error actions remain reachable at narrow large text',
    (t) async {
      t.view.physicalSize = const Size(390, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      t.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      final api = _api()
        ..appThreadResumeError = AnyhowException(
          'the agent rejected the request: Internal error',
        );
      api.serveHosts.add(
        const AppServeStatus(
          name: 'claude',
          device: 'dev',
          alive: true,
          appListenAddr: '127.0.0.1:18200',
          appServiceKey: _acp,
          appRegistered: true,
          metaListenAddr: '127.0.0.1:18201',
          metaServiceKey: 'pcx:dev:meta:claude',
          metaRegistered: true,
          codexBinary: '/opt/bin/claude-agent-acp',
          protocol: 'acp',
          provider: 'acp',
        ),
      );
      await api.appConnect(_acp, 28080);
      await t.pumpWidget(
        host(
          const AppSessionScreen(serviceKey: _acp, threadId: 'existing'),
          api,
          locale: const Locale('en'),
        ),
      );
      await _frames(t);
      expect(find.byKey(const Key('session-error-agent-hint')), findsOneWidget);
      expect(
        find.byKey(const Key('session-error-host-settings')).hitTestable(),
        findsOneWidget,
      );
      expect(find.text('Retry').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('a project is enough: the welcome goes from opening to ready '
      'with the agent-reported model, and no native-only control appears', (
    t,
  ) async {
    final api = _api();
    final gate = Completer<void>();
    api.threadStartGate = gate;
    await _open(t, api, cwd: '/work/alpha');
    expect(find.byKey(const Key('agent-welcome')), findsOneWidget);
    expect(find.text('Start with Claude'), findsOneWidget);
    expect(find.byKey(const Key('agent-welcome-opening')), findsOneWidget);
    expect(find.byKey(const Key('agent-session-opening')), findsOneWidget);
    expect(api.threadStartCalls, [_acp], reason: 'one opening, no click');
    // Rebuilds while it opens never start another.
    await _type(t, 'typing meanwhile');
    await _frames(t);
    expect(api.threadStartCalls, hasLength(1));
    gate.complete();
    await _frames(t);
    expect(find.text('Ready · Sonnet'), findsOneWidget);
    expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
    expect(find.byKey(const Key('agent-config-mode')), findsOneWidget);
    expect(find.byKey(const Key('agent-session-opening')), findsNothing);
    expect(find.text('typing meanwhile'), findsOneWidget);
    expect(api.turnStartCount, 0, reason: 'nothing is sent by itself');
    // Codex-only controls stay absent on ACP.
    expect(find.byKey(const Key('fast-mode-btn')), findsNothing);
    expect(find.byKey(const Key('voice-start')), findsNothing);
    expect(find.byKey(const Key('model-chip')), findsNothing);
    // The unused session is the draft's, not a conversation in the list.
    expect(
      find.byKey(Key('conv-tile-${api.appThreads.first.id}')),
      findsNothing,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('a send while the session opens waits for it and uses it', (
    t,
  ) async {
    final api = _api();
    final gate = Completer<void>();
    api.threadStartGate = gate;
    await _open(t, api, cwd: '/work/alpha');
    await _type(t, 'early');
    await t.tap(find.byKey(const Key('send-btn')));
    await t.pump();
    expect(api.threadStartCalls, hasLength(1));
    expect(api.turnStartCount, 0);
    gate.complete();
    await _frames(t);
    expect(api.threadStartCalls, hasLength(1), reason: 'never a second');
    expect(api.turnStartCount, 1);
    expect(api.lastTurnText, 'early');
    expect(api.lastTurnThread, api.appThreads.first.id);
  });

  testWidgets('an opening that outlives a project switch stays with its own '
      'draft; the other project opens its own, and coming back reuses it', (
    t,
  ) async {
    final api = _api();
    // Earlier sessions in two projects, so the project menu offers both.
    api.appThreads.addAll(const [
      ThreadMeta(id: 'a0', preview: 'a', cwd: '/work/alpha', updatedAt: 2),
      ThreadMeta(id: 'b0', preview: 'b', cwd: '/work/beta', updatedAt: 1),
    ]);
    final gate = Completer<void>();
    api.threadStartGate = gate;
    await _open(t, api, cwd: '/work/alpha');
    await _type(t, 'alpha draft');
    await _pickProject(t, '/work/beta');
    // Beta's draft is not blocked by alpha's busy opening.
    expect(api.threadStartCalls, hasLength(2));
    expect(api.lastCwd, '/work/beta');
    expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
    expect(find.text('alpha draft'), findsNothing);
    gate.complete();
    await _frames(t);
    // Alpha's late answer changes nothing in beta's view.
    expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
    expect(api.turnStartCount, 0);
    await _pickProject(t, '/work/alpha');
    expect(api.threadStartCalls, hasLength(2), reason: 'alpha keeps its own');
    expect(find.text('alpha draft'), findsOneWidget);
    expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
    await t.tap(find.byKey(const Key('send-btn')));
    await _frames(t);
    expect(api.threadStartCalls, hasLength(2));
    expect(api.lastTurnText, 'alpha draft');
    final alpha = api.appThreads.firstWhere(
      (m) => m.cwd == '/work/alpha' && m.id != 'a0',
    );
    expect(api.lastTurnThread, alpha.id);
  });

  testWidgets('a failed opening says why, is not retried by itself, and '
      'opens again on Retry', (t) async {
    final api = _api()
      ..threadStartError = StateError(
        'the agent rejected the request: Internal error',
      );
    await _open(t, api, cwd: '/work/alpha');
    expect(find.byKey(const Key('agent-welcome-failed')), findsOneWidget);
    expect(find.textContaining('Internal error'), findsOneWidget);
    expect(find.byKey(const Key('agent-session-retry')), findsOneWidget);
    // A host this device does not run offers no host settings.
    expect(find.byKey(const Key('agent-welcome-host-settings')), findsNothing);
    for (var i = 0; i < 3; i++) {
      await _frames(t);
    }
    expect(api.threadStartCalls, hasLength(1), reason: 'no retry loop');
    await t.tap(find.byKey(const Key('agent-welcome-retry')));
    await _frames(t);
    expect(api.threadStartCalls, hasLength(2));
    expect(find.byKey(const Key('agent-welcome-failed')), findsNothing);
    expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
  });

  testWidgets('after a failed opening the first send opens the session once', (
    t,
  ) async {
    final api = _api()..threadStartError = StateError('agent unavailable');
    await _open(t, api, cwd: '/work/alpha');
    expect(api.threadStartCalls, hasLength(1));
    await _type(t, 'hello');
    await t.tap(find.byKey(const Key('send-btn')));
    await _frames(t);
    expect(api.threadStartCalls, hasLength(2));
    expect(api.turnStartCount, 1);
    expect(api.lastTurnText, 'hello');
  });

  testWidgets('an opening that finishes after the screen is gone adopts '
      'nothing and throws nothing', (t) async {
    final api = _api();
    final gate = Completer<void>();
    api.threadStartGate = gate;
    await _open(t, api, cwd: '/work/alpha');
    await t.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(t.takeException(), isNull);
    expect(api.turnStartCount, 0);
  });

  testWidgets('first run: no projects and no project folders, yet a typed '
      'host path starts the conversation there', (t) async {
    final api = _api();
    await _open(t, api);
    expect(api.threadStartCalls, isEmpty, reason: 'no project, no session');
    final choose = find.byKey(const Key('agent-welcome-choose-folder'));
    expect(choose, findsOneWidget);
    await t.tap(choose);
    await t.pumpAndSettle();
    // No configured roots is not a dead end.
    expect(find.byKey(const Key('folder-picker-no-roots')), findsOneWidget);
    await t.tap(find.byKey(const Key('folder-type-start')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('folder-path-field')), 'relative');
    await t.testTextInput.receiveAction(TextInputAction.go);
    await t.pumpAndSettle();
    expect(find.textContaining('full path'), findsOneWidget);
    await t.enterText(find.byKey(const Key('folder-path-field')), '/srv/new');
    await t.testTextInput.receiveAction(TextInputAction.go);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('folder-outside-note')), findsOneWidget);
    await t.tap(find.byKey(const Key('folder-use-btn')));
    await t.pumpAndSettle();
    expect(
      t.widget<Text>(find.byKey(const Key('new-session-cwd'))).data,
      '/srv/new',
    );
    expect(api.threadStartCalls, [_acp]);
    expect(api.lastCwd, '/srv/new');
  });

  testWidgets('the welcome and composer fit narrow phones at large text', (
    t,
  ) async {
    for (final width in [320.0, 390.0]) {
      final api = _api();
      api.appThreads.add(
        const ThreadMeta(
          id: 'a0',
          preview: 'a',
          cwd: '/a/very/long/path/to/a/project/with/a/long/name',
          updatedAt: 1,
        ),
      );
      t.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await _open(t, api, cwd: '/work/alpha', size: Size(width, 800));
      expect(find.byKey(const Key('agent-welcome')), findsOneWidget);
      expect(t.takeException(), isNull, reason: 'no overflow at $width');
    }
  });
}
