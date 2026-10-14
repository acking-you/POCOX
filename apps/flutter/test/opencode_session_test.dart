// Native OpenCode conversations: options chosen on an unsent draft stay
// local until its first send creates the session, are applied to that new
// session before the message goes out, and never touch a host-wide default;
// the `/` command list only writes text into the draft.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';

import 'fake_bridge_api.dart';
import 'support/acp_capabilities.dart';
import 'support/screen_harness.dart';

const _svc = 'pcx:local:opencode:opencode';

const _defaults = SessionSettings(
  configOptions: [
    SessionConfigOption(
      id: 'model',
      name: 'Model',
      category: 'model',
      currentValue: 'anthropic/sonnet',
      values: [
        SessionConfigValue(value: 'anthropic/sonnet', name: 'Sonnet'),
        SessionConfigValue(value: 'openai/gpt', name: 'GPT'),
      ],
    ),
    SessionConfigOption(
      id: 'variant',
      name: 'Variant',
      category: 'thought_level',
      currentValue: 'high',
      values: [
        SessionConfigValue(
          value: 'high',
          name: 'High',
          group: 'anthropic/sonnet',
        ),
        SessionConfigValue(
          value: 'minimal',
          name: 'Minimal',
          group: 'openai/gpt',
        ),
      ],
    ),
  ],
);

Future<void> _frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
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

/// The option chip [option] showing [label].
Finder _shown(String option, String label) => find.descendant(
  of: find.byKey(Key('agent-config-$option')),
  matching: find.text(label),
);

Future<FakeBridgeApi> _openDraft(WidgetTester t) async {
  t.view.physicalSize = const Size(1400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final api = FakeBridgeApi();
  api.acpCapabilities[_svc] = negotiatedOpenCodeCapabilities();
  // The service's defaults for a new session (empty thread id).
  api.sessionSettings['$_svc|'] = _defaults;
  api.agentCommands = const [
    AgentCommand(name: 'review', description: 'Review changes'),
    AgentCommand(name: 'init', description: 'Create AGENTS.md'),
  ];
  await api.appConnect(_svc, 28080);
  await t.pumpWidget(
    host(
      const AppSessionScreen(serviceKey: _svc, cwd: '/work/alpha'),
      api,
      locale: const Locale('en'),
    ),
  );
  await _frames(t);
  return api;
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('draft options stay local until the first send applies them '
      'to the new session', (t) async {
    final api = await _openDraft(t);
    expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
    // Nothing is opened ahead for the draft.
    expect(api.threadStartCalls, isEmpty);

    await _pick(t, 'model', 'openai/gpt');
    // Only the chosen model's variants remain, starting at none (the model
    // resets its variant), and nothing went out.
    expect(_shown('variant', 'Default'), findsOneWidget);
    expect(api.sessionConfigCalls, isEmpty);
    await _pick(t, 'variant', 'minimal');
    expect(_shown('variant', 'Minimal'), findsOneWidget);
    expect(api.sessionConfigCalls, isEmpty);
    expect(
      api.sessionSettings['$_svc|']!.configOptions.first.currentValue,
      'anthropic/sonnet',
      reason: 'the host-wide default is not changed',
    );

    var turnsAtFirstChoice = -1;
    api.onSessionConfig = (id, value, current) {
      if (turnsAtFirstChoice < 0) turnsAtFirstChoice = api.turnStartCount;
      return current;
    };
    await t.enterText(find.byKey(const Key('composer-input')), 'hello');
    // The send button reads the text when it rebuilds.
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await _frames(t);

    final thread = api.threadStartResults.single!;
    // Model first (it decides the variants), then the variant, both on the
    // created session; never with an empty id.
    expect(api.sessionConfigCalls, [
      (thread, 'model', 'openai/gpt'),
      (thread, 'variant', 'minimal'),
    ]);
    expect(turnsAtFirstChoice, 0, reason: 'options before the message');
    expect(api.lastTurnThread, thread);
    expect(api.lastTurnText, 'hello');
    expect(api.sessionConfigCalls.where((c) => c.$1.isEmpty), isEmpty);
  });

  testWidgets('a draft applies exactly what it shows: a model alone leaves '
      'the variant unset', (t) async {
    final api = await _openDraft(t);
    await _pick(t, 'model', 'openai/gpt');
    expect(_shown('model', 'GPT'), findsOneWidget);
    expect(_shown('variant', 'Default'), findsOneWidget);
    await t.enterText(find.byKey(const Key('composer-input')), 'hello');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await _frames(t);
    final thread = api.threadStartResults.single!;
    // No variant was shown as chosen, so none is applied.
    expect(api.sessionConfigCalls, [(thread, 'model', 'openai/gpt')]);
    expect(api.lastTurnText, 'hello');
  });

  testWidgets('after the host is replaced with another catalog, a draft '
      'choice it no longer offers is shown as the default and not applied', (
    t,
  ) async {
    final api = await _openDraft(t);
    await _pick(t, 'model', 'openai/gpt');
    await _pick(t, 'variant', 'minimal');
    await t.enterText(find.byKey(const Key('composer-input')), 'hello');
    await t.pump();
    // Apply restarted the host: it now offers only Sonnet.
    api.sessionSettings['$_svc|'] = SessionSettings(
      configOptions: [
        SessionConfigOption(
          id: 'model',
          name: 'Model',
          category: 'model',
          currentValue: 'anthropic/sonnet',
          values: const [
            SessionConfigValue(value: 'anthropic/sonnet', name: 'Sonnet'),
          ],
        ),
        _defaults.configOptions[1],
      ],
    );
    api.pushEvent(
      _svc,
      const AppEvent(kind: 'acp/host/state', raw: '{"connected":false}'),
    );
    await _frames(t);
    expect(_shown('model', 'Sonnet'), findsOneWidget);
    expect(_shown('variant', 'High'), findsOneWidget);
    // The draft text is kept and nothing went out by itself.
    expect(api.threadStartCalls, isEmpty);
    await t.tap(find.byKey(const Key('send-btn')));
    await _frames(t);
    expect(api.threadStartResults.single, isNotNull);
    expect(api.sessionConfigCalls, isEmpty);
    expect(api.lastTurnText, 'hello');
  });

  testWidgets('choosing the default again records no choice', (t) async {
    final api = await _openDraft(t);
    await _pick(t, 'model', 'openai/gpt');
    await _pick(t, 'model', 'anthropic/sonnet');
    // The default model shows its own default variant again.
    expect(_shown('variant', 'High'), findsOneWidget);
    await t.enterText(find.byKey(const Key('composer-input')), 'hello');
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await _frames(t);
    expect(api.threadStartResults, hasLength(1));
    expect(api.sessionConfigCalls, isEmpty);
    expect(api.lastTurnText, 'hello');
  });

  testWidgets('a draft reads its options once the host negotiates, '
      'opening nothing', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = FakeBridgeApi();
    api.sessionSettings['$_svc|'] = _defaults;
    await api.appConnect(_svc, 28080);
    await t.pumpWidget(
      host(
        const AppSessionScreen(serviceKey: _svc, cwd: '/work/alpha'),
        api,
        locale: const Locale('en'),
      ),
    );
    await _frames(t);
    // Before negotiation nothing optional is offered.
    expect(find.byKey(const Key('agent-config-model')), findsNothing);
    api.acpCapabilities[_svc] = negotiatedOpenCodeCapabilities();
    // Any rebuild sees the negotiated capabilities; no event is needed.
    await t.enterText(find.byKey(const Key('composer-input')), 'h');
    await _frames(t);
    expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
    expect(api.threadStartCalls, isEmpty);
    expect(api.sessionConfigCalls, isEmpty);
    expect(api.turnStartCount, 0);
  });

  testWidgets('a failed option leaves the message unsent with its text', (
    t,
  ) async {
    final api = await _openDraft(t);
    await _pick(t, 'model', 'openai/gpt');
    api.sessionConfigError = StateError('model not available');
    await t.enterText(find.byKey(const Key('composer-input')), 'keep me');
    // The send button reads the text when it rebuilds.
    await t.pump();
    await t.tap(find.byKey(const Key('send-btn')));
    await _frames(t);
    expect(api.threadStartCalls, hasLength(1));
    final thread = api.threadStartResults.single!;
    // The refused choice was the only call, on the created session.
    expect(api.sessionConfigCalls, [(thread, 'model', 'openai/gpt')]);
    expect(api.turnStartCount, 0);
    // The message is back in the composer, not shown as sent, and the
    // refusal is said.
    TextField composer() =>
        t.widget<TextField>(find.byKey(const Key('composer-input')));
    expect(composer().controller!.text, 'keep me');
    expect(find.textContaining('model not available'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('chat-conversation-layer')),
        matching: find.text('keep me'),
      ),
      findsNothing,
    );
    // Sending again sends it as typed, with the session's own options: the
    // refused choice is not applied behind the user's back.
    await t.tap(find.byKey(const Key('send-btn')));
    await _frames(t);
    expect(api.threadStartCalls, hasLength(1));
    expect(api.sessionConfigCalls, hasLength(1));
    expect(api.lastTurnThread, thread);
    expect(api.lastTurnText, 'keep me');
    expect(api.sessionConfigCalls.where((c) => c.$1.isEmpty), isEmpty);
  });

  testWidgets('the command list writes `/name ` and sends nothing', (t) async {
    final api = await _openDraft(t);
    await t.enterText(find.byKey(const Key('composer-input')), '/re');
    await _frames(t);
    expect(find.byKey(const Key('command-palette')), findsOneWidget);
    expect(find.byKey(const Key('command-review')), findsOneWidget);
    expect(find.byKey(const Key('command-init')), findsNothing);
    await t.tap(find.byKey(const Key('command-review')));
    await _frames(t);
    final input = t.widget<TextField>(find.byKey(const Key('composer-input')));
    expect(input.controller!.text, '/review ');
    expect(find.byKey(const Key('command-palette')), findsNothing);
    expect(api.turnStartCount, 0);
    expect(api.commandListCalls, [_svc]);
  });

  testWidgets('Escape closes the command list and keeps the text', (t) async {
    // Hardware-key handling is the desktop composer's.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = await _openDraft(t);
      await t.tap(find.byKey(const Key('composer-input')));
      await t.enterText(find.byKey(const Key('composer-input')), '/');
      await _frames(t);
      expect(find.byKey(const Key('command-palette')), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(t);
      expect(find.byKey(const Key('command-palette')), findsNothing);
      final input = t.widget<TextField>(
        find.byKey(const Key('composer-input')),
      );
      expect(input.controller!.text, '/');
      expect(api.turnStartCount, 0);
      await t.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
