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
import 'support/opencode_chat.dart';

const _svc = openCodeService;

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

Future<FakeBridgeApi> _openDraft(WidgetTester t) {
  final api = FakeBridgeApi()
    ..acpCapabilities[_svc] = negotiatedOpenCodeCapabilities()
    // The service's defaults for a new session (empty thread id).
    ..sessionSettings['$_svc|'] = _defaults
    ..agentCommands = const [
      AgentCommand(name: 'review', description: 'Review changes'),
      AgentCommand(name: 'init', description: 'Create AGENTS.md'),
    ];
  return mountChat(t, api, cwd: '/work/alpha');
}

void main() {
  setUp(AppSessionScreen.debugResetThreadMemory);

  testWidgets('a draft applies exactly what it shows: a model alone leaves '
      'the variant unset', (t) async {
    final api = await _openDraft(t);
    await pickOption(t, 'model', 'openai/gpt');
    expect(optionShows('model', 'GPT'), findsOneWidget);
    expect(optionShows('variant', 'Default'), findsOneWidget);
    await typeMessage(t, 'hello');
    await tapSend(t);
    final thread = api.threadStartResults.single!;
    // No variant was shown as chosen, so none is applied.
    expect(api.sessionConfigCalls, [(thread, 'model', 'openai/gpt')]);
    expect(api.lastTurnText, 'hello');
  });

  testWidgets('a draft reads its options once the host negotiates, '
      'opening nothing', (t) async {
    final api = FakeBridgeApi()..sessionSettings['$_svc|'] = _defaults;
    await mountChat(t, api, cwd: '/work/alpha');
    // Before negotiation nothing optional is offered.
    expect(find.byKey(const Key('agent-config-model')), findsNothing);
    api.acpCapabilities[_svc] = negotiatedOpenCodeCapabilities();
    // Any rebuild sees the negotiated capabilities; no event is needed.
    await t.enterText(find.byKey(const Key('composer-input')), 'h');
    await frames(t);
    expect(find.byKey(const Key('agent-config-model')), findsOneWidget);
    expect(api.threadStartCalls, isEmpty);
    expect(api.sessionConfigCalls, isEmpty);
    expect(api.turnStartCount, 0);
  });

  testWidgets('a failed option leaves the message unsent with its text', (
    t,
  ) async {
    final api = await _openDraft(t);
    await pickOption(t, 'model', 'openai/gpt');
    api.sessionConfigError = StateError('model not available');
    await typeMessage(t, 'keep me');
    await tapSend(t);
    expect(api.threadStartCalls, hasLength(1));
    final thread = api.threadStartResults.single!;
    // The refused choice was the only call, on the created session.
    expect(api.sessionConfigCalls, [(thread, 'model', 'openai/gpt')]);
    expect(api.turnStartCount, 0);
    // The message is back in the composer, not shown as sent, and the
    // refusal is said.
    expect(composerText(t), 'keep me');
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
    await tapSend(t);
    expect(api.threadStartCalls, hasLength(1));
    expect(api.sessionConfigCalls, hasLength(1));
    expect(api.lastTurnThread, thread);
    expect(api.lastTurnText, 'keep me');
    expect(api.sessionConfigCalls.where((c) => c.$1.isEmpty), isEmpty);
  });

  testWidgets('the command list writes `/name ` and sends nothing', (t) async {
    final api = await _openDraft(t);
    await t.enterText(find.byKey(const Key('composer-input')), '/re');
    await frames(t);
    expect(find.byKey(const Key('command-palette')), findsOneWidget);
    expect(find.byKey(const Key('command-review')), findsOneWidget);
    expect(find.byKey(const Key('command-init')), findsNothing);
    await t.tap(find.byKey(const Key('command-review')));
    await frames(t);
    expect(composerText(t), '/review ');
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
      await frames(t);
      expect(find.byKey(const Key('command-palette')), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await frames(t);
      expect(find.byKey(const Key('command-palette')), findsNothing);
      expect(composerText(t), '/');
      expect(api.turnStartCount, 0);
      await t.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
