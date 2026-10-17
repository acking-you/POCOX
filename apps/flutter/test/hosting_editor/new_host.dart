part of '../hosting_editor_test.dart';

void _newHostTests() {
  testWidgets(
    'Claude environment draft survives agent changes and reaches start',
    (t) async {
      final api = _withClaude();
      await _pumpEditor(t, api);
      await _choosePreset(t, 'claude');
      await _tapKey(t, 'claude-env-group-models');
      await _tapKey(t, 'claude-env-override-ANTHROPIC_DEFAULT_OPUS_MODEL');
      await _enter(
        t,
        'claude-env-value-ANTHROPIC_DEFAULT_OPUS_MODEL',
        'provider.exact-opus',
      );
      await _choosePreset(t, 'fixture');
      expect(find.byKey(const Key('claude-environment-section')), findsNothing);
      await _choosePreset(t, 'claude');
      final draft = t
          .widget<ModelServiceSection>(find.byType(ModelServiceSection))
          .draft;
      expect(draft.input.claudeEnv, {
        'ANTHROPIC_DEFAULT_OPUS_MODEL': 'provider.exact-opus',
      });
      await _tapKey(t, 'start-hosting-btn');
      expect(api.startConfiguredCalls.single.$3.claudeEnv, {
        'ANTHROPIC_DEFAULT_OPUS_MODEL': 'provider.exact-opus',
      });
      expect(api.startConfiguredCalls.single.$3.source, 'inherited');
    },
  );

  testWidgets('a new Codex host is saved and started as one operation', (
    t,
  ) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);

    // Codex offers all three sources and only the Responses API.
    for (final source in ['inherited', 'official', 'custom']) {
      expect(find.byKey(Key('host-source-$source')), findsOneWidget);
    }
    await _tapKey(t, 'host-source-custom');
    expect(find.byKey(const Key('host-protocol-responses')), findsOneWidget);
    expect(
      find.byKey(const Key('host-protocol-anthropic-messages')),
      findsNothing,
    );
    await _enter(t, 'host-base-url', ' https://models.example/v1 ');
    await _enter(t, 'host-api-key', 'sk-test');
    await _enter(t, 'host-model', 'gpt-test');
    await _tapKey(t, 'start-hosting-btn');

    expect(api.hostConfigSaves, isEmpty, reason: 'no separate pre-save');
    final (name, runtime, input, action, key) = api.startConfiguredCalls.single;
    expect(name, 'default');
    expect(runtime.isCodex, isTrue);
    expect(runtime.port, 18080);
    expect(runtime.proxy, 'http://127.0.0.1:11111');
    // A detected codex is left to the bridge to resolve.
    expect(runtime.binary, isNull);
    expect(input.source, 'custom');
    expect(input.protocol, 'responses');
    expect(input.baseUrl, 'https://models.example/v1');
    expect(input.model, 'gpt-test');
    expect(action, HostKeyAction.replace);
    expect(key, 'sk-test');
    expect(api.serveHosts, hasLength(1));
    expect(find.byType(HostingEditor), findsNothing);
    expect(find.text(_l10nOf(t).managedStarted('default')), findsOneWidget);
  });

  testWidgets('a failed start keeps the page and no new configuration', (
    t,
  ) async {
    final api = FakeBridgeApi()
      ..hostConfigs['default'] = const HostConfig(source: 'official')
      // Another computer publishes the name on the relay.
      ..serveStartError = StateError('the service name is already in use');
    await _pumpEditor(t, api);
    await _tapKey(t, 'start-hosting-btn');

    expect(find.text(_l10n(t).hostNameConflict), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('host-editor-scroll')),
        matching: find.byKey(const Key('host-editor-error')),
      ),
      findsNothing,
      reason: 'pinned above the actions, seen wherever the form is scrolled',
    );
    expect(find.byType(HostingEditor), findsOneWidget);
    expect(api.hostConfigs['default']!.source, 'official', reason: 'kept');
  });

  testWidgets('a name another host here uses is refused before anything '
      'starts', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost.copyName('default'));
    await _pumpEditor(t, api);
    final l10n = _l10n(t);
    final field = find.byKey(const Key('codex-name-field'));
    // The suggestion avoids it; a typed alias of it is the same instance.
    expect(t.widget<TextField>(field).controller!.text, 'default-2');
    await _enter(t, 'codex-name-field', ' Default ');
    expect(find.text(l10n.hostNameInUse('default')), findsOneWidget);
    await _tapKey(t, 'start-hosting-btn');
    expect(api.startConfiguredCalls, isEmpty);
    expect(find.byType(HostingEditor), findsOneWidget);
    // Under the field and as the refusal; a new name clears both.
    expect(find.text(l10n.hostNameInUse('default')), findsNWidgets(2));
    await _enter(t, 'codex-name-field', 'mine');
    expect(find.text(l10n.hostNameInUse('default')), findsNothing);
  });

  testWidgets('a new host with the existing configuration drops a stale key', (
    t,
  ) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    expect(find.byKey(const Key('host-inherited-status')), findsOneWidget);
    await _tapKey(t, 'start-hosting-btn');

    final (_, _, input, action, key) = api.startConfiguredCalls.single;
    expect(input.source, 'inherited');
    expect(input.baseUrl, isNull);
    // A key left by an earlier host of the same name is never inherited.
    expect(action, HostKeyAction.remove);
    expect(key, isNull);
  });

  testWidgets('a typed key is not sent once the source leaves custom', (
    t,
  ) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://models.example/v1');
    await _enter(t, 'host-api-key', 'sk-test');
    await _tapKey(t, 'host-source-inherited');
    await _tapKey(t, 'start-hosting-btn');

    final (_, _, input, action, key) = api.startConfiguredCalls.single;
    expect(input.source, 'inherited');
    expect(action, HostKeyAction.remove);
    expect(key, isNull);
  });

  testWidgets('required provider fields are named before anything starts', (
    t,
  ) async {
    final api = _withClaude();
    await _pumpEditor(t, api);
    final l10n = _l10n(t);
    await _tapKey(t, 'host-source-custom');
    expect(find.text(l10n.hostBaseUrlRequired), findsOneWidget);

    // Claude needs a key, or its own sign-in would reach the gateway.
    await _choosePreset(t, 'claude');
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://models.example');
    expect(find.text(l10n.hostKeyRequired), findsOneWidget);
    await _tapKey(t, 'start-hosting-btn');
    expect(api.startConfiguredCalls, isEmpty);
  });

  testWidgets('each agent offers only its real provider APIs', (t) async {
    final api = _withClaude();
    await _pumpEditor(t, api);

    await _choosePreset(t, 'claude');
    expect(find.byKey(const Key('host-source-official')), findsNothing);
    await _tapKey(t, 'host-source-custom');
    expect(
      find.byKey(const Key('host-protocol-anthropic-messages')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('host-protocol-responses')), findsNothing);

    await _choosePreset(t, 'fixture');
    expect(find.byKey(const Key('host-source-custom')), findsNothing);

    // A custom ACP agent has only its own configuration: no choice, just
    // what it uses.
    await _tapKey(t, 'agent-choice-custom');
    expect(find.byKey(const Key('host-source-inherited')), findsNothing);
    expect(find.byKey(const Key('host-source-custom')), findsNothing);
    expect(find.text(_l10n(t).hostInheritedAcp), findsOneWidget);
  });

  testWidgets('each agent choice keeps its own model-service draft', (t) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://codex.example/v1');
    await _enter(t, 'host-api-key', 'sk-codex');

    // Another agent starts from its own (inherited) draft: nothing carries.
    await _choosePreset(t, 'fixture');
    expect(find.byKey(const Key('host-base-url')), findsNothing);

    // Back to Codex: its draft is still there.
    await _tapKey(t, 'agent-choice-codex');
    expect(find.text('https://codex.example/v1'), findsOneWidget);
    await _tapKey(t, 'start-hosting-btn');
    final (_, _, input, _, key) = api.startConfiguredCalls.single;
    expect(input.baseUrl, 'https://codex.example/v1');
    expect(key, 'sk-codex');
  });

  testWidgets('switching agents and back keeps each agent form', (t) async {
    final api = _withClaude();
    await _pumpEditor(t, api);
    await _choosePreset(t, 'fixture');
    await _openAdvanced(t, 'acp-advanced-toggle');
    await _enter(t, 'acp-program-field', '/opt/fixture/custom');

    await _choosePreset(t, 'claude');
    expect(find.text('/opt/fixture/custom'), findsNothing);
    await _tapKey(t, 'agent-choice-preset:fixture');
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();

    // A preset reopens with Advanced closed; the restored program (not the
    // preset's `fixture-agent` default) is what its field holds once shown.
    await _openAdvanced(t, 'acp-advanced-toggle');
    expect(
      t
          .widget<TextField>(find.byKey(const Key('acp-program-field')))
          .controller!
          .text,
      '/opt/fixture/custom',
    );
    await _tapKey(t, 'start-hosting-btn');
    expect(
      api.startConfiguredCalls.single.$2.agent!.program,
      '/opt/fixture/custom',
    );
  });

  testWidgets('a typed instance name or the save toggle alone is an edit, '
      'kept on a choice switched away from', (t) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _choosePreset(t, 'fixture');
    await _enter(t, 'acp-instance-name-field', 'my-fixture');
    // Another agent is shown; the edited one is not.
    await _tapKey(t, 'agent-choice-codex');
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
    await _tapKey(t, 'host-leave-stay');
    expect(find.byType(HostingEditor), findsOneWidget);
    // Switching back restores the typed name.
    await _choosePreset(t, 'fixture');
    expect(find.text('my-fixture'), findsOneWidget);
    // Leave this editor (discarding its edits), then take the whole tree
    // down: the next mount gets a new navigator, not this one's routes.
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await _tapKey(t, 'host-leave-discard');
    expect(find.byType(HostingEditor), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pumpAndSettle();

    // The save toggle of a custom agent, on its own, asks too.
    final fresh = FakeBridgeApi();
    await _pumpEditor(t, fresh);
    await _tapKey(t, 'agent-choice-custom');
    await _openAdvanced(t, 'acp-advanced-toggle');
    await _tapKey(t, 'acp-save-agent');
    await _tapKey(t, 'agent-choice-codex');
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
    await _tapKey(t, 'host-leave-discard');
    expect(find.byType(HostingEditor), findsNothing);
  });
}
