part of '../acp_hosting_test.dart';

void _registerPresets() {
  testWidgets('a built-in ACP preset hosts its program with its argv', (
    t,
  ) async {
    final api = FakeBridgeApi();
    final c = await _pumpDialog(t, api);
    // One tile per agent, each with its own mark; Codex is preselected.
    // Native OpenCode has its own tile, apart from the ACP presets.
    expect(find.byKey(const Key('agent-choice-codex')), findsOneWidget);
    expect(find.byKey(const Key('agent-choice-opencode')), findsOneWidget);
    expect(
      find.byKey(const Key('agent-choice-preset:fixture')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('agent-choice-custom')), findsOneWidget);
    await _chooseAcp(t);
    expect(find.byKey(const Key('acp-host-form')), findsOneWidget);
    final program = t.widget<TextField>(
      find.byKey(const Key('acp-program-field')),
    );
    expect(program.controller!.text, 'fixture-agent');
    expect(find.byKey(const Key('acp-program-found')), findsOneWidget);
    final arg = t.widget<TextField>(find.byKey(const Key('acp-arg-field-0')));
    expect(arg.controller!.text, 'acp');
    // Codex-only fields are not part of an ACP host.
    expect(find.byKey(const Key('use-proxy-switch')), findsNothing);
    expect(find.byKey(const Key('codex-path-field')), findsNothing);
    await _start(t);
    expect(api.acpServeCalls, hasLength(1));
    final (name, spec) = api.acpServeCalls.single;
    expect(name, 'fixture');
    expect(spec.profileId, 'fixture');
    expect(spec.program, 'fixture-agent');
    expect(spec.args, ['acp']);
    final prefs = await c.read(uiPrefsProvider.future);
    expect(prefs.autoHostAcp.single.name, 'fixture');
    expect(prefs.acpAgents, isEmpty, reason: 'presets are not saved');
  });

  testWidgets('agent chooser shows a preset, Claude adapter, saved long names '
      'and Custom, wrapping safely at 320px with reachable Start', (t) async {
    final api = FakeBridgeApi();
    api.presets = const [
      fixturePreset,
      AcpPreset(
        id: 'claude',
        displayName: 'Claude',
        program: 'claude-agent-acp',
        args: [],
      ),
    ];
    api.acpPrograms['claude-agent-acp'] = '/usr/local/bin/claude-agent-acp';
    const longAgent = AcpAgentSpec(
      profileId: 'custom-enterprise-agent',
      displayName: 'Internal Enterprise Security & Code Audit Agent',
      program: '/opt/agents/audit-runner',
      args: ['--audit'],
    );
    final c = await _pumpDialog(
      t,
      api,
      size: const Size(320, 640),
      prefs: _HeldPrefs(const UiPrefs(acpAgents: [longAgent])),
    );
    expect(find.byKey(const Key('agent-choice-codex')), findsOneWidget);
    expect(
      find.byKey(const Key('agent-choice-preset:fixture')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('agent-choice-preset:claude')), findsOneWidget);
    expect(find.byKey(const Key('agent-icon-claude')), findsOneWidget);
    expect(
      find.byKey(const Key('agent-choice-saved:custom-enterprise-agent')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('agent-choice-custom')), findsOneWidget);

    // The program and arguments sit behind Advanced, as for any preset.
    await _chooseAcp(t, 'claude');
    expect(find.byKey(const Key('acp-host-form')), findsOneWidget);
    final program = t.widget<TextField>(
      find.byKey(const Key('acp-program-field')),
    );
    expect(program.controller!.text, 'claude-agent-acp');
    // Claude shows what it will run on (adapter, Node.js, CLI) instead of a
    // bare program lookup.
    expect(find.byKey(const Key('claude-environment')), findsOneWidget);
    expect(find.byKey(const Key('claude-adapter')), findsOneWidget);
    expect(find.byKey(const Key('claude-node')), findsOneWidget);
    expect(find.byKey(const Key('claude-cli')), findsOneWidget);
    expect(api.claudePrepareStarts, 0);
    expect(find.byKey(const Key('acp-arg-field-0')), findsNothing);

    await _start(t);

    expect(api.acpServeCalls, hasLength(1));
    final (name, spec) = api.acpServeCalls.single;
    expect(name, 'claude');
    expect(spec.profileId, 'claude');
    expect(spec.program, 'claude-agent-acp');
    expect(spec.args, isEmpty);
    final prefs = await c.read(uiPrefsProvider.future);
    expect(prefs.autoHostAcp.single.name, 'claude');
  });

  testWidgets('custom agents keep every argument verbatim and are saved', (
    t,
  ) async {
    final api = FakeBridgeApi()..acpPrograms['my-agent'] = '/usr/bin/my-agent';
    final c = await _pumpDialog(t, api);
    await _chooseCustom(t);
    await t.enterText(
      find.byKey(const Key('acp-display-name-field')),
      'My Agent',
    );
    await t.enterText(
      find.byKey(const Key('acp-program-field')),
      '/Applications/My Agent.app/bin/agent',
    );
    for (final value in ['--flag=a b', r'$HOME;*', '']) {
      await t.ensureVisible(find.byKey(const Key('acp-arg-add')));
      await t.tap(find.byKey(const Key('acp-arg-add')));
      await t.pumpAndSettle();
      final index = find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('acp-arg-field-'),
          )
          .evaluate()
          .length;
      await t.enterText(find.byKey(Key('acp-arg-field-${index - 1}')), value);
      // Done on the keyboard, as a user would: the field's selection
      // handle hangs below it, over the add button.
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
    }
    // Reorder: move the last (empty) argument above the second.
    await t.ensureVisible(find.byKey(const Key('acp-arg-up-2')));
    await t.tap(find.byKey(const Key('acp-arg-up-2')));
    await t.pumpAndSettle();
    await _start(t);
    final (_, spec) = api.acpServeCalls.single;
    expect(spec.program, '/Applications/My Agent.app/bin/agent');
    expect(spec.args, ['--flag=a b', '', r'$HOME;*']);
    expect(spec.profileId, matches(RegExp(r'^custom-my-agent-[0-9a-f]{8}$')));
    final prefs = await c.read(uiPrefsProvider.future);
    expect(prefs.acpAgents.single, spec);
    expect(prefs.autoHostAcp.single.spec, spec);
  });

  testWidgets('a platform without ACP hosting says so', (t) async {
    final api = FakeBridgeApi()..acpHosting = false;
    await _pumpDialog(t, api);
    await _chooseAcp(t);
    expect(find.byKey(const Key('acp-hosting-unsupported')), findsOneWidget);
    expect(find.byKey(const Key('acp-program-field')), findsNothing);
  });

  for (final (device, size) in [
    ('phone', const Size(320, 640)),
    ('tablet', const Size(800, 1100)),
    ('desktop', const Size(1440, 900)),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('ACP form lays out on $device (${brightness.name})', (
        t,
      ) async {
        final api = FakeBridgeApi();
        await _pumpDialog(t, api, size: size, brightness: brightness);
        await _chooseAcp(t);
        expect(t.takeException(), isNull);
        expect(find.byKey(const Key('acp-arg-field-0')), findsOneWidget);
        // Reordering buttons only where the row stays wide enough to read.
        expect(
          find.byKey(const Key('acp-arg-up-0')),
          device == 'phone' ? findsNothing : findsOneWidget,
        );
        // The argument's label is whole at every width; where the row's
        // buttons would cut it they move under the field and stay usable.
        final arg = find.byKey(const Key('acp-arg-field-0'));
        final argLabel = AppLocalizations.of(
          t.element(arg),
        ).acpArgumentLabel(1);
        final paragraph = t.renderObject<RenderParagraph>(
          find.descendant(of: arg, matching: find.text(argLabel)),
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: 'label is cut');
        await t.ensureVisible(find.byKey(const Key('acp-arg-remove-0')));
        await t.pumpAndSettle();
        expect(
          find.byKey(const Key('acp-arg-remove-0')).hitTestable(),
          findsOneWidget,
        );
        // Touch targets stay at least 48 dp tall.
        final remove = t.getSize(find.byKey(const Key('acp-arg-remove-0')));
        expect(remove.height, greaterThanOrEqualTo(48));
        final tile = t.getSize(
          find.byKey(const Key('agent-choice-preset:fixture')),
        );
        expect(tile.height, greaterThanOrEqualTo(48));
      });
    }
  }

  testWidgets('agent marks follow the profile or engine, never the host '
      'name', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Row(
          children: [
            AgentIcon.of(
              key: const Key('named-opencode'),
              provider: 'acp',
              profileId: 'custom-x',
              name: 'opencode',
            ),
            AgentIcon.of(
              key: const Key('retired-preset'),
              provider: 'acp',
              profileId: 'opencode',
            ),
            AgentIcon.of(key: const Key('native'), provider: 'opencode'),
            AgentIcon.of(key: const Key('codex'), provider: 'codex'),
          ],
        ),
      ),
    );
    for (final key in ['named-opencode', 'retired-preset']) {
      expect(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byKey(const Key('agent-icon-letter')),
        ),
        findsOneWidget,
        reason: key,
      );
    }
    expect(
      find.descendant(
        of: find.byKey(const Key('native')),
        matching: find.byKey(const Key('agent-icon-opencode')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('codex')),
        matching: find.byKey(const Key('agent-icon-codex')),
      ),
      findsOneWidget,
    );
    expect(agentKindOf(provider: 'acp', profileId: 'claude'), AgentKind.claude);
    expect(agentKindOf(provider: 'opencode'), AgentKind.opencode);
    expect(agentKindOf(provider: 'acp'), AgentKind.other);
  });

  test('suggested instance names avoid every running host, as the bridge '
      'compares names', () {
    expect(uniqueHostName('default', const []), 'default');
    expect(uniqueHostName('default', const ['default']), 'default-2');
    expect(
      uniqueHostName('default', const ['Default', 'default-2']),
      'default-3',
    );
    expect(hostNameClash('My Host', const ['other', 'my-host']), 'my-host');
    expect(hostNameClash('mine', const ['my-host']), isNull);
    expect(hostNameClash(' ', const ['default']), isNull);
  });

  testWidgets('a name another host owns gets localized guidance', (t) async {
    final api = FakeBridgeApi()
      ..acpServeError = StateError(
        '`fixture` is already hosting Codex on this device; choose another name',
      );
    await _pumpDialog(t, api);
    await _chooseAcp(t);
    await _start(t);
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.hostNameInUse('fixture')), findsOneWidget);
  });

  test('protocols come from the key kind', () {
    expect(sessionProtocolOf('pcx:mac:acp:agent'), SessionProtocol.acp);
    expect(sessionProtocolOf('pcxu:u:mac:acp:agent'), SessionProtocol.acp);
    expect(
      sessionProtocolOf('pcx:mac:app:acp'),
      SessionProtocol.codexAppServer,
    );
    expect(isSessionKind('acp'), isTrue);
    expect(
      sessionProtocolOf('pcx:mac:opencode:opencode'),
      SessionProtocol.opencode,
    );
    expect(isSessionKind('opencode'), isTrue);
    expect(
      customProfileId('My Agent!', '0a1b2c3d'),
      'custom-my-agent-0a1b2c3d',
    );
    expect(customProfileId('***', '0a1b2c3d'), 'custom-agent-0a1b2c3d');
    // Names in other scripts share a slug; the salt keeps them apart.
    final first = customProfileId('我的智能体', newProfileSalt());
    final second = customProfileId('另一个智能体', newProfileSalt());
    expect(first, startsWith('custom-agent-'));
    expect(first, isNot(second));
    expect(newProfileSalt(), matches(RegExp(r'^[0-9a-f]{8}$')));
  });

  testWidgets('two custom agents with non-Latin names are saved separately', (
    t,
  ) async {
    final api = FakeBridgeApi();
    final c = await _pumpDialog(t, api);
    for (final (index, name) in ['我的智能体', '另一个智能体'].indexed) {
      if (index > 0) {
        await t.tap(find.text('open'));
        await t.pumpAndSettle();
      }
      await _chooseCustom(t);
      await t.enterText(find.byKey(const Key('acp-display-name-field')), name);
      await t.enterText(
        find.byKey(const Key('acp-instance-name-field')),
        'agent-$index',
      );
      await t.enterText(
        find.byKey(const Key('acp-program-field')),
        '/opt/agents/agent-$index',
      );
      await _start(t);
    }
    final prefs = await c.read(uiPrefsProvider.future);
    expect(prefs.acpAgents.map((a) => a.displayName), ['我的智能体', '另一个智能体']);
    expect(prefs.acpAgents.map((a) => a.profileId).toSet(), hasLength(2));
  });

  test('native Codex capability values are unchanged and ACP starts empty', () {
    expect(AppCapabilities.codex.voice, isTrue);
    expect(AppCapabilities.codex.nativeMetadata, isTrue);
    const acp = AppCapabilities.acp;
    expect(acp.negotiated, isFalse);
    expect([
      acp.voice,
      acp.dictation,
      acp.imageInput,
      acp.steer,
      acp.modelCatalog,
    ], everyElement(isFalse));
    expect(acp.permissionOptions, isTrue);
  });
}
