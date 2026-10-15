// A native OpenCode host replaced with another model configuration (Apply
// restarts it), with the capabilities the bridge reports (a model catalog
// together with session and draft options): after the controller
// reconnects, the draft's options offer the new host's catalog, a choice
// the new host no longer offers is neither shown nor applied, and a send
// goes to the replacement without it. The composer shows no Codex model
// menu and sends no model, effort or collaboration mode of its own. Text
// stays; nothing is sent by itself. A read answered by the previous
// connection after the reconnect changes nothing.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/opencode_chat.dart';

const _svc = openCodeService;
const _cwd = '/work';

SessionSettings _catalog(List<(String, String)> models) => SessionSettings(
  configOptions: [
    SessionConfigOption(
      id: 'model',
      name: 'Model',
      category: 'model',
      currentValue: '',
      values: [
        const SessionConfigValue(value: '', name: 'Inherited'),
        for (final (value, name) in models)
          SessionConfigValue(value: value, name: name),
      ],
    ),
  ],
);

const _mimo = ('opencode/mimo-free', 'MiMo Free');
const _other = ('opencode/other-free', 'Other Free');
const _claude = ('anthropic/claude-opus', 'Claude Opus');

/// A desktop draft on a connected OpenCode host whose catalog offers MiMo
/// and Other.
Future<FakeBridgeApi> _open(WidgetTester t) {
  final api = FakeBridgeApi()
    ..acpCapabilities[_svc] = negotiatedOpenCodeCapabilities()
    ..draftSettings['$_svc|$_cwd'] = _catalog(const [_mimo, _other]);
  return mountChat(t, api, cwd: _cwd);
}

Future<void> _pick(WidgetTester t, (String, String) model) =>
    pickOption(t, 'model', model.$1);

/// The model option shows [label].
Finder _shown(String label) => optionShows('model', label);

/// The host is replaced (Apply): its event stream ends, the new host offers
/// only [models], and the screen's bounded reconnect reaches it.
Future<void> _replaceHost(
  WidgetTester t,
  FakeBridgeApi api,
  List<(String, String)> models,
) async {
  api.draftSettings['$_svc|$_cwd'] = _catalog(models);
  api.pushEvent(
    _svc,
    const AppEvent(kind: 'acp/host/state', raw: '{"connected":false}'),
  );
  await frames(t);
}

void _nextGeneration(FakeBridgeApi api) => api.pushEvent(
  _svc,
  const AppEvent(
    kind: 'acp/host/state',
    raw: '{"generation":2,"connected":true}',
  ),
);

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('after the host is replaced the draft offers its catalog and a '
      'withdrawn choice is neither shown nor applied', (t) async {
    final api = await _open(t);
    expect(find.byKey(const Key('model-chip')), findsNothing);
    await _pick(t, _other);
    expect(_shown('Other Free'), findsOneWidget);
    await typeMessage(t, 'keep this');
    final connects = api.appConnectCount;

    await _replaceHost(t, api, const [_claude]);
    expect(api.appConnectCount, greaterThan(connects));
    expect(_shown('Other Free'), findsNothing);
    await t.tap(find.byKey(const Key('agent-config-model')));
    await t.pumpAndSettle();
    expect(optionChoice(_claude.$1), findsOneWidget);
    expect(optionChoice(_mimo.$1), findsNothing);
    expect(optionChoice(_other.$1), findsNothing);
    await t.tapAt(Offset.zero);
    await t.pumpAndSettle();
    expect(composerText(t), 'keep this');
    expect(api.threadStartCalls, isEmpty);
    expect(api.turnStartCount, 0);

    await t.tap(find.byKey(const Key('send-btn')));
    await frames(t);
    expect(api.threadStartCalls, [_svc]);
    expect(api.sessionConfigCalls, isEmpty);
    expect(api.turnStartCount, 1);
    expect(api.lastTurnText, 'keep this');
    expectNoModelMenuSettings(api);
  });

  testWidgets('a choice the replacement still offers stays and is applied', (
    t,
  ) async {
    final api = await _open(t);
    await _pick(t, _other);
    await _replaceHost(t, api, const [_mimo, _other, _claude]);
    expect(_shown('Other Free'), findsOneWidget);
    await typeMessage(t, 'hi');
    await t.tap(find.byKey(const Key('send-btn')));
    await frames(t);
    final thread = api.threadStartResults.single!;
    expect(api.sessionConfigCalls, [(thread, 'model', _other.$1)]);
    expect(api.lastTurnText, 'hi');
    expectNoModelMenuSettings(api);
  });

  testWidgets('a draft read answered by the previous connection after the '
      'reconnect changes nothing', (t) async {
    final api = await _open(t);
    // Another generation answers; its read still describes the previous
    // host and is held.
    final stale = Completer<void>();
    addTearDown(() {
      if (!stale.isCompleted) stale.complete();
    });
    api.draftSettingsGates[_cwd] = stale;
    _nextGeneration(api);
    await frames(t, 2);
    // The host is then replaced; the reconnect's own read answers first.
    api.draftSettingsGates.remove(_cwd);
    await _replaceHost(t, api, const [_claude]);
    expect(_shown('Inherited'), findsOneWidget);
    // The previous connection's answer arrives last.
    stale.complete();
    await frames(t);
    await t.tap(find.byKey(const Key('agent-config-model')));
    await t.pumpAndSettle();
    expect(optionChoice(_claude.$1), findsOneWidget);
    expect(optionChoice(_mimo.$1), findsNothing);
    await t.tapAt(Offset.zero);
    await t.pumpAndSettle();
    expect(api.turnStartCount, 0);
  });

  testWidgets('a send racing the reconnect\'s read applies only what the '
      'replacement offers', (t) async {
    final api = await _open(t);
    await _pick(t, _other);
    // The connection moved (another generation, offering only Claude) and
    // every read of it is still out when the user sends.
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    api.draftSettings['$_svc|$_cwd'] = _catalog(const [_claude]);
    api.draftSettingsGates[_cwd] = gate;
    _nextGeneration(api);
    await frames(t, 2);
    await typeMessage(t, 'hold on');
    await t.tap(find.byKey(const Key('send-btn')));
    await frames(t, 2);
    // The session exists; the choices wait for that project's defaults.
    expect(api.threadStartCalls, [_svc]);
    expect(api.turnStartCount, 0);
    gate.complete();
    await frames(t);
    expect(api.sessionConfigCalls, isEmpty);
    expect(api.turnStartCount, 1);
    expect(api.lastTurnText, 'hold on');
    expectNoModelMenuSettings(api);
  });
}
