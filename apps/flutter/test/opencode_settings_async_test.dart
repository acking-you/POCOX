// Native OpenCode reads session and draft settings from its host
// asynchronously: a slow read never holds the composer or the menus, an
// answer for a project, draft or connection the view has left is dropped,
// requests made while a read runs coalesce into one following read, and a
// newer choice is never overwritten by an older answer.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/opencode_chat.dart';

const _svc = openCodeService;
const _alpha = '/work/alpha';
const _beta = '/work/beta';
const _thread = 'oc-session';

SessionSettings _models(List<(String, String)> models, {String? current}) =>
    SessionSettings(
      configOptions: [
        SessionConfigOption(
          id: 'model',
          name: 'Model',
          category: 'model',
          currentValue: current ?? models.first.$1,
          values: [
            for (final (value, name) in models)
              SessionConfigValue(value: value, name: name),
          ],
        ),
      ],
    );

final _alphaModels = _models([
  ('alpha/one', 'Alpha One'),
  ('alpha/two', 'Alpha Two'),
]);
final _betaModels = _models([('beta/one', 'Beta One')]);

FakeBridgeApi _api() {
  final api = FakeBridgeApi();
  api.acpCapabilities[_svc] = negotiatedOpenCodeCapabilities();
  api.appThreads.addAll(const [
    ThreadMeta(id: 'a0', preview: 'a', cwd: _alpha, updatedAt: 2),
    ThreadMeta(id: 'b0', preview: 'b', cwd: _beta, updatedAt: 1),
  ]);
  api.draftSettings
    ..['$_svc|$_alpha'] = _alphaModels
    ..['$_svc|$_beta'] = _betaModels;
  return api;
}

Future<void> _mount(WidgetTester t, FakeBridgeApi api, {String? threadId}) =>
    mountChat(t, api, cwd: _alpha, threadId: threadId);

Future<void> _pick(WidgetTester t, String value) =>
    pickOption(t, 'model', value);

/// The model option shows [label].
Finder _shown(String label) => optionShows('model', label);

void _hostState(FakeBridgeApi api) => api.pushEvent(
  _svc,
  const AppEvent(
    kind: 'acp/host/state',
    raw: '{"generation":1,"connected":true}',
  ),
);

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('a stalled draft read leaves the composer usable; its late '
      'answer after a project switch is not shown', (t) async {
    final api = _api();
    final held = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    api.draftSettingsGates[_alpha] = held;
    await _mount(t, api);
    // Nothing of A is offered yet; typing works meanwhile.
    expect(find.byKey(const Key('agent-config-model')), findsNothing);
    await typeMessage(t, 'typing while it loads');
    expect(composerText(t), 'typing while it loads');

    await pickProject(t, _beta);
    expect(_shown('Beta One'), findsOneWidget);
    // A's answer arrives after the view moved to B.
    held.complete();
    await frames(t);
    expect(_shown('Beta One'), findsOneWidget);
    expect(_shown('Alpha One'), findsNothing);

    // Back in A its own options are read and shown; its text is kept.
    await pickProject(t, _alpha);
    expect(_shown('Alpha One'), findsOneWidget);
    expect(composerText(t), 'typing while it loads');
    expect(api.threadStartCalls, isEmpty);
    expect(api.turnStartCount, 0);
  });

  testWidgets('a send while the draft read stalls sends the message without '
      'choices', (t) async {
    final api = _api();
    final held = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    api.draftSettingsGates[_alpha] = held;
    await _mount(t, api);
    await typeMessage(t, 'hello');
    await tapSend(t);
    expect(api.threadStartCalls, [_svc]);
    expect(api.lastCwd, _alpha);
    expect(api.sessionConfigCalls, isEmpty);
    expect(api.lastTurnText, 'hello');
    // The late draft answer changes nothing for the created session.
    held.complete();
    await frames(t);
    expect(api.sessionConfigCalls, isEmpty);
    expect(api.turnStartCount, 1);
  });

  testWidgets('a choice made while the same draft is read again is kept and '
      'applied', (t) async {
    final api = _api();
    await _mount(t, api);
    expect(_shown('Alpha One'), findsOneWidget);
    final held = Completer<void>();
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    api.draftSettingsGates[_alpha] = held;
    final reads = api.draftSettingsProjects.length;
    // The same host answers again (no new generation): one more read.
    _hostState(api);
    _hostState(api);
    await frames(t);
    expect(api.draftSettingsProjects.length, reads + 1, reason: 'coalesced');
    // What is shown stays usable while it runs.
    await _pick(t, 'alpha/two');
    expect(_shown('Alpha Two'), findsOneWidget);
    held.complete();
    await frames(t);
    // The coalesced request reads once more; the choice stays on top.
    expect(api.draftSettingsProjects.length, reads + 2);
    expect(_shown('Alpha Two'), findsOneWidget);
    expect(api.sessionConfigCalls, isEmpty);

    await typeMessage(t, 'go');
    await tapSend(t);
    final thread = api.threadStartResults.single!;
    expect(api.sessionConfigCalls, [(thread, 'model', 'alpha/two')]);
    expect(api.lastTurnText, 'go');
  });

  testWidgets('an older session read answered after a newer choice is not '
      'shown', (t) async {
    final api = _api()
      ..sessionOpenResults.add(openCodeWritable(_thread))
      ..readResult = const ThreadHistory(
        running: false,
        cwd: _alpha,
        items: [],
      );
    api.sessionSettings['$_svc|$_thread'] = _alphaModels;
    api.onSessionConfig = (id, value, current) => _models(const [
      ('alpha/one', 'Alpha One'),
      ('alpha/two', 'Alpha Two'),
    ], current: value);
    await _mount(t, api, threadId: _thread);
    expect(_shown('Alpha One'), findsOneWidget);

    final held = Completer<void>();
    api.sessionSettingsRefreshGate = held;
    final reads = api.sessionSettingsRefreshCalls.length;
    // A refresh starts; it answers what the host had before the choice.
    api.pushEvent(
      _svc,
      const AppEvent(kind: 'acp/session/updated', threadId: _thread, raw: '{}'),
    );
    await frames(t);
    expect(api.sessionSettingsRefreshCalls.length, reads + 1);
    expect(_shown('Alpha One'), findsOneWidget, reason: 'kept meanwhile');

    await _pick(t, 'alpha/two');
    expect(api.sessionConfigCalls, [(_thread, 'model', 'alpha/two')]);
    // The older answer arrives after the choice; one more read follows.
    api.sessionSettingsRefreshGate = null;
    held.complete();
    await frames(t);
    expect(api.sessionSettingsRefreshCalls.length, reads + 2);
    expect(_shown('Alpha Two'), findsOneWidget);
    expect(_shown('Alpha One'), findsNothing);
  });

  testWidgets('an answer arriving after the view is gone changes nothing', (
    t,
  ) async {
    final api = _api();
    final held = Completer<void>();
    api.draftSettingsGates[_alpha] = held;
    await _mount(t, api);
    await t.pumpWidget(const SizedBox.shrink());
    held.complete();
    await frames(t);
    expect(t.takeException(), isNull);
    expect(api.threadStartCalls, isEmpty);
    expect(api.turnStartCount, 0);
  });

  testWidgets('a failed read of the same draft keeps its options and choice', (
    t,
  ) async {
    final api = _api();
    await _mount(t, api);
    await _pick(t, 'alpha/two');
    final failing = Completer<void>();
    api.draftSettingsGates[_alpha] = failing;
    final reads = api.draftSettingsProjects.length;
    _hostState(api);
    await frames(t, 2);
    expect(api.draftSettingsProjects.length, reads + 1);
    failing.completeError(StateError('gateway unavailable'));
    await frames(t);
    expect(t.takeException(), isNull);
    // What was shown stays, with the choice, and stays usable.
    expect(_shown('Alpha Two'), findsOneWidget);
    await t.tap(find.byKey(const Key('agent-config-model')));
    await t.pumpAndSettle();
    expect(optionChoice('alpha/one'), findsOneWidget);
    await t.tapAt(Offset.zero);
    await t.pumpAndSettle();

    api.draftSettingsGates.remove(_alpha);
    await typeMessage(t, 'still mine');
    await tapSend(t);
    final thread = api.threadStartResults.single!;
    expect(api.sessionConfigCalls, [(thread, 'model', 'alpha/two')]);
    expect(api.lastTurnText, 'still mine');
  });

  testWidgets('a failed read for another project shows nothing of the '
      'previous one', (t) async {
    final api = _api();
    await _mount(t, api);
    expect(_shown('Alpha One'), findsOneWidget);
    final failing = Completer<void>();
    api.draftSettingsGates[_beta] = failing;
    await pickProject(t, _beta);
    failing.completeError(StateError('gateway unavailable'));
    await frames(t);
    expect(t.takeException(), isNull);
    expect(find.byKey(const Key('agent-config-model')), findsNothing);
    expect(_shown('Alpha One'), findsNothing);
    expect(api.threadStartCalls, isEmpty);
    expect(api.turnStartCount, 0);
  });

  testWidgets('a failed refresh of a session keeps its options', (t) async {
    final api = _api()
      ..sessionOpenResults.add(openCodeWritable(_thread))
      ..readResult = const ThreadHistory(
        running: false,
        cwd: _alpha,
        items: [],
      );
    api.sessionSettings['$_svc|$_thread'] = _models(const [
      ('alpha/one', 'Alpha One'),
      ('alpha/two', 'Alpha Two'),
    ], current: 'alpha/two');
    await _mount(t, api, threadId: _thread);
    expect(_shown('Alpha Two'), findsOneWidget);
    final failing = Completer<void>();
    api.sessionSettingsRefreshGate = failing;
    api.pushEvent(
      _svc,
      const AppEvent(kind: 'acp/session/updated', threadId: _thread, raw: '{}'),
    );
    await frames(t, 2);
    api.sessionSettingsRefreshGate = null;
    failing.completeError(StateError('gateway unavailable'));
    await frames(t);
    expect(t.takeException(), isNull);
    expect(_shown('Alpha Two'), findsOneWidget);
    await t.tap(find.byKey(const Key('agent-config-model')));
    await t.pumpAndSettle();
    expect(optionChoice('alpha/one'), findsOneWidget);
  });
}
