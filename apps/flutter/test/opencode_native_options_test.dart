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
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/opencode_chat.dart';

const _svc = openCodeService;
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

Future<FakeBridgeApi> _mount(
  WidgetTester t,
  FakeBridgeApi api, {
  String? threadId,
}) {
  api.acpCapabilities[_svc] = negotiatedOpenCodeCapabilities();
  return mountChat(t, api, cwd: _cwd, threadId: threadId);
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

/// The composer offers the native options, none of the Codex menu.
void _nativeControls() {
  expect(find.byKey(const Key('model-chip')), findsNothing);
  expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
  expect(find.byKey(const Key('agent-config-agent')), findsOneWidget);
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
    await typeMessage(t, 'hello');
    expect(composerText(t), 'hello');

    read.complete();
    await frames(t);
    _nativeControls();
    expect(_shown('model', 'Inherited'), findsOneWidget);

    await pickOption(t, 'model', 'zen/pickle');
    expect(_shown('model', 'Big Pickle'), findsOneWidget);
    // Only the chosen model's variants.
    await t.tap(find.byKey(const Key('agent-config-variant')));
    await t.pumpAndSettle();
    expect(optionChoice('fast'), findsOneWidget);
    expect(optionChoice('high'), findsNothing);
    await t.tap(optionChoice('fast'));
    await t.pumpAndSettle();
    await pickOption(t, 'agent', 'plan');
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
    await frames(t);
    expect(api.threadStartCalls, [_svc]);
    expect(api.sessionConfigCalls, isEmpty);
    expect(api.turnStartCount, 0, reason: 'the message waits for its options');

    applyRead.complete();
    await frames(t);
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
    expectNoModelMenuSettings(api);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('an existing session offers its own options after a slow read '
      'and a choice is sent to it', (t) async {
    final api = FakeBridgeApi()
      ..sessionOpenResults.add(openCodeWritable(_thread))
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
    await typeMessage(t, 'next');
    expect(composerText(t), 'next');

    api.sessionSettingsRefreshGate = null;
    read.complete();
    await frames(t);
    _nativeControls();
    expect(_shown('model', 'PR109 Alpha MiMo'), findsOneWidget);
    expect(_shown('agent', 'build'), findsOneWidget);
    expect(_shown('variant', 'high'), findsOneWidget);

    await pickOption(t, 'agent', 'plan');
    await frames(t);
    expect(api.sessionConfigCalls, [(_thread, 'agent', 'plan')]);
    expect(_shown('agent', 'plan'), findsOneWidget);

    await t.tap(find.byKey(const Key('send-btn')));
    await frames(t);
    expect(api.threadStartCalls, isEmpty);
    expect(api.lastTurnThread, _thread);
    expect(api.lastTurnText, 'next');
    expectNoModelMenuSettings(api);
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
    await pickProject(t, _beta);
    expect(_shown('model', 'PR109 Alpha MiMo'), findsNothing);
    read.complete();
    await frames(t);
    expect(_shown('model', 'PR109 Beta MiMo'), findsOneWidget);
    expect(_shown('model', 'PR109 Alpha MiMo'), findsNothing);
    await t.tap(find.byKey(const Key('agent-config-model')));
    await t.pumpAndSettle();
    expect(find.text('PR109 Alpha MiMo'), findsNothing);
    await t.tapAt(Offset.zero);
    await t.pumpAndSettle();

    // And back in Alpha, Alpha's own label.
    await pickProject(t, _cwd);
    expect(_shown('model', 'PR109 Alpha MiMo'), findsOneWidget);
    expect(_shown('model', 'PR109 Beta MiMo'), findsNothing);
    expect(api.threadStartCalls, isEmpty);
    expect(api.turnStartCount, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
