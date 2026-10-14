// Native OpenCode with exactly the capabilities the bridge reports: a model
// catalog together with session and draft options. The composer shows the
// session's own model, agent and variant options (never the Codex model
// menu with effort and Plan), on a draft and on an existing session, also
// when their reads are slow; choices go out as session options, the model
// first, before the first message; and the turn carries no model, effort or
// collaboration mode of its own.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/screen_harness.dart';

const _svc = 'pcx:local:opencode:opencode';
const _cwd = '/work/alpha';
const _thread = 'oc-session';
const _beta = '/work/beta';

/// OpenCode's option set as the bridge builds it: model (inherited first),
/// agent, and variants grouped by model. A session ([session]) offers only
/// its model's variants.
SessionSettings _options({
  String model = '',
  String agent = '',
  String variant = '',
  bool session = false,
  String mimo = 'PR109 Alpha MiMo',
}) => SessionSettings(
  configOptions: [
    SessionConfigOption(
      id: 'model',
      name: 'Model',
      category: 'model',
      currentValue: model,
      values: [
        const SessionConfigValue(value: '', name: 'Inherited'),
        SessionConfigValue(value: 'zen/mimo', name: mimo),
        const SessionConfigValue(value: 'zen/pickle', name: 'Big Pickle'),
      ],
    ),
    SessionConfigOption(
      id: 'agent',
      name: 'Agent',
      category: 'mode',
      currentValue: agent,
      values: const [
        SessionConfigValue(value: '', name: 'Default agent'),
        SessionConfigValue(value: 'build', name: 'build'),
        SessionConfigValue(value: 'plan', name: 'plan'),
      ],
    ),
    SessionConfigOption(
      id: 'variant',
      name: 'Variant',
      category: 'thought_level',
      currentValue: variant,
      values: [
        if (!session || model == 'zen/mimo') ...const [
          SessionConfigValue(value: '', name: 'Default', group: 'zen/mimo'),
          SessionConfigValue(value: 'high', name: 'high', group: 'zen/mimo'),
        ],
        if (!session || model == 'zen/pickle') ...const [
          SessionConfigValue(value: '', name: 'Default', group: 'zen/pickle'),
          SessionConfigValue(value: 'fast', name: 'fast', group: 'zen/pickle'),
        ],
      ],
    ),
  ],
);

Future<void> _frames(WidgetTester t, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<FakeBridgeApi> _mount(
  WidgetTester t,
  FakeBridgeApi api, {
  String? threadId,
}) async {
  t.view.physicalSize = const Size(1400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  api.acpCapabilities[_svc] = negotiatedOpenCodeCapabilities();
  await api.appConnect(_svc, 28080);
  await t.pumpWidget(
    host(
      AppSessionScreen(serviceKey: _svc, cwd: _cwd, threadId: threadId),
      api,
      locale: const Locale('en'),
    ),
  );
  await _frames(t);
  return api;
}

Finder _choice(String value) {
  final listed = find.byKey(Key('agent-option-value-$value'));
  return listed.evaluate().isNotEmpty
      ? listed
      : find.byWidgetPredicate(
          (w) => w is CheckedPopupMenuItem<String> && w.value == value,
        );
}

Future<void> _pick(WidgetTester t, String option, String value) async {
  await t.tap(find.byKey(Key('agent-config-$option')));
  await t.pumpAndSettle();
  final target = _choice(value);
  await t.ensureVisible(target);
  await t.pumpAndSettle();
  await t.tap(target);
  await t.pumpAndSettle();
}

/// Option [option] shows [label]: the segment announces (and its tooltip
/// reads) the full label, and its face shows that label or, when the
/// segment is too narrow for it, the label's tail after an ellipsis. A stale
/// or another value's label fails the announced check even when the tails
/// look alike.
Finder _shown(String option, String label) => find.descendant(
  of: find.byKey(Key('agent-config-$option')),
  matching: find.byElementPredicate((e) {
    final w = e.widget;
    final announced = w is Semantics ? w.properties.label ?? '' : '';
    // A grouped value (a variant) is announced as "group · name".
    if (!announced.endsWith(': $label') && !announced.endsWith(' · $label')) {
      return false;
    }
    var face = false;
    void visit(Element child) {
      final t = child.widget;
      if (t is Text && t.data != null) {
        final d = t.data!;
        if (d == label ||
            (d.startsWith('…') &&
                d.length > 1 &&
                label.endsWith(d.substring(1)))) {
          face = true;
        }
      }
      child.visitChildren(visit);
    }

    e.visitChildren(visit);
    return face;
  }),
);

Future<void> _pickProject(WidgetTester t, String path) async {
  await t.tap(find.byKey(const Key('project-switcher-btn')));
  await _frames(t);
  await t.tap(find.byKey(Key('project-menu-item-$path')));
  await _frames(t);
}

Future<void> _type(WidgetTester t, String text) async {
  await t.enterText(find.byKey(const Key('composer-input')), text);
  await t.pump();
}

String _composer(WidgetTester t) => t
    .widget<TextField>(find.byKey(const Key('composer-input')))
    .controller!
    .text;

/// The composer offers the native options, none of the Codex menu.
void _nativeControls() {
  expect(find.byKey(const Key('model-chip')), findsNothing);
  expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
  expect(find.byKey(const Key('agent-config-agent')), findsOneWidget);
}

/// Nothing of the Codex menu went out with the turn.
void _noMenuSettings(FakeBridgeApi api) {
  expect(api.lastModel, isNull);
  expect(api.lastTurnModel, isNull);
  expect(api.lastReasoningEffort, isNull);
  expect(api.lastCollaborationMode, isNull);
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('a draft offers model, agent and variant after a slow read; '
      'the first send applies them before the message', (t) async {
    final api = FakeBridgeApi()..draftSettings['$_svc|$_cwd'] = _options();
    final read = Completer<void>();
    addTearDown(() {
      if (!read.isCompleted) read.complete();
    });
    api.draftSettingsGates[_cwd] = read;
    await _mount(t, api);
    // While the project's options load nothing is offered, and nothing of
    // the Codex menu either; typing works.
    expect(find.byKey(const Key('model-chip')), findsNothing);
    expect(find.byKey(const Key('agent-config-model')), findsNothing);
    await _type(t, 'hello');
    expect(_composer(t), 'hello');

    read.complete();
    await _frames(t);
    _nativeControls();
    expect(_shown('model', 'Inherited'), findsOneWidget);

    await _pick(t, 'model', 'zen/pickle');
    expect(_shown('model', 'Big Pickle'), findsOneWidget);
    // Only the chosen model's variants.
    await t.tap(find.byKey(const Key('agent-config-variant')));
    await t.pumpAndSettle();
    expect(_choice('fast'), findsOneWidget);
    expect(_choice('high'), findsNothing);
    await t.tap(_choice('fast'));
    await t.pumpAndSettle();
    await _pick(t, 'agent', 'plan');
    expect(_shown('variant', 'fast'), findsOneWidget);
    expect(_shown('agent', 'plan'), findsOneWidget);
    expect(api.sessionConfigCalls, isEmpty);

    var turnsAtFirstChoice = -1;
    api.onSessionConfig = (id, value, current) {
      if (turnsAtFirstChoice < 0) turnsAtFirstChoice = api.turnStartCount;
      return current;
    };
    // The send's own read of the project's defaults is slow too.
    final applyRead = Completer<void>();
    addTearDown(() {
      if (!applyRead.isCompleted) applyRead.complete();
    });
    api.draftSettingsGates[_cwd] = applyRead;
    await t.tap(find.byKey(const Key('send-btn')));
    await _frames(t);
    expect(api.threadStartCalls, [_svc]);
    expect(api.sessionConfigCalls, isEmpty);
    expect(api.turnStartCount, 0, reason: 'the message waits for its options');

    applyRead.complete();
    await _frames(t);
    final thread = api.threadStartResults.single!;
    expect(api.lastCwd, _cwd);
    expect(api.sessionConfigCalls, [
      (thread, 'model', 'zen/pickle'),
      (thread, 'variant', 'fast'),
      (thread, 'agent', 'plan'),
    ]);
    expect(turnsAtFirstChoice, 0, reason: 'options before the message');
    expect(api.lastTurnThread, thread);
    expect(api.lastTurnText, 'hello');
    _noMenuSettings(api);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('an existing session offers its own options after a slow read '
      'and a choice is sent to it', (t) async {
    final api = FakeBridgeApi()
      ..sessionOpenResults.add(
        const SessionAccess(
          sessionId: _thread,
          hostId: 'host-1',
          generation: 1,
          provider: 'opencode',
          mode: 'write',
          writer: 'this_host',
          turn: 'idle',
          exclusion: 'pocket',
          reason: 'owned',
          canRelease: true,
          recheck: false,
        ),
      )
      ..readResult = const ThreadHistory(running: false, cwd: _cwd, items: [])
      ..sessionSettings['$_svc|$_thread'] = _options(
        model: 'zen/mimo',
        agent: 'build',
        variant: 'high',
        session: true,
      );
    api.onSessionConfig = (id, value, current) => _options(
      model: id == 'model' ? value : 'zen/mimo',
      agent: id == 'agent' ? value : 'build',
      variant: id == 'variant' ? value : 'high',
      session: true,
    );
    final read = Completer<void>();
    addTearDown(() {
      if (!read.isCompleted) read.complete();
    });
    api.sessionSettingsRefreshGate = read;
    await _mount(t, api, threadId: _thread);
    expect(find.byKey(const Key('model-chip')), findsNothing);
    expect(find.byKey(const Key('agent-config-model')), findsNothing);
    await _type(t, 'next');
    expect(_composer(t), 'next');

    api.sessionSettingsRefreshGate = null;
    read.complete();
    await _frames(t);
    _nativeControls();
    expect(_shown('model', 'PR109 Alpha MiMo'), findsOneWidget);
    expect(_shown('agent', 'build'), findsOneWidget);
    expect(_shown('variant', 'high'), findsOneWidget);

    await _pick(t, 'agent', 'plan');
    await _frames(t);
    expect(api.sessionConfigCalls, [(_thread, 'agent', 'plan')]);
    expect(_shown('agent', 'plan'), findsOneWidget);

    await t.tap(find.byKey(const Key('send-btn')));
    await _frames(t);
    expect(api.threadStartCalls, isEmpty);
    expect(api.lastTurnThread, _thread);
    expect(api.lastTurnText, 'next');
    _noMenuSettings(api);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('the same model id in another project shows that project\'s '
      'label', (t) async {
    final api = FakeBridgeApi()
      ..appThreads.addAll(const [
        ThreadMeta(id: 'a0', preview: 'a', cwd: _cwd, updatedAt: 2),
        ThreadMeta(id: 'b0', preview: 'b', cwd: _beta, updatedAt: 1),
      ])
      ..draftSettings['$_svc|$_cwd'] = _options(model: 'zen/mimo')
      ..draftSettings['$_svc|$_beta'] = _options(
        model: 'zen/mimo',
        mimo: 'PR109 Beta MiMo',
      );
    await _mount(t, api);
    expect(_shown('model', 'PR109 Alpha MiMo'), findsOneWidget);

    // Beta's read is slow: Alpha's label is not kept meanwhile.
    final read = Completer<void>();
    addTearDown(() {
      if (!read.isCompleted) read.complete();
    });
    api.draftSettingsGates[_beta] = read;
    await _pickProject(t, _beta);
    expect(_shown('model', 'PR109 Alpha MiMo'), findsNothing);
    read.complete();
    await _frames(t);
    expect(_shown('model', 'PR109 Beta MiMo'), findsOneWidget);
    expect(_shown('model', 'PR109 Alpha MiMo'), findsNothing);
    await t.tap(find.byKey(const Key('agent-config-model')));
    await t.pumpAndSettle();
    expect(find.text('PR109 Alpha MiMo'), findsNothing);
    await t.tapAt(Offset.zero);
    await t.pumpAndSettle();

    // And back in Alpha, Alpha's own label.
    await _pickProject(t, _cwd);
    expect(_shown('model', 'PR109 Alpha MiMo'), findsOneWidget);
    expect(_shown('model', 'PR109 Beta MiMo'), findsNothing);
    expect(api.threadStartCalls, isEmpty);
    expect(api.turnStartCount, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
