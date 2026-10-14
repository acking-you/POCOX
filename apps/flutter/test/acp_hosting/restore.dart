part of '../acp_hosting_test.dart';

void _registerRestore() {
  test('restore plans by what hosts are, never by what they are not', () {
    const acpSpec = AcpAgentSpec(
      profileId: 'fixture',
      displayName: 'Fixture Agent',
      program: 'fixture-agent',
      args: ['acp'],
    );
    const prefs = UiPrefs(
      autoHostCodex: [AutoHostPrefs(port: 0, name: 'default')],
      autoHostAcp: [
        AutoHostAcpPrefs(name: 'agent', spec: acpSpec),
        AutoHostAcpPrefs(name: 'other', spec: acpSpec),
      ],
    );
    // A running ACP host is not "a Codex host": Codex must still restore.
    final plan = planHostRestore(
      prefs,
      [_acpHost.copyForTest(name: 'agent')],
      codexAttempted: const {},
      acpAttempted: const {},
      acpSupported: true,
    );
    expect(plan.codex.map((h) => h.name), ['default']);
    expect(plan.acp.map((a) => a.name), ['other']);
    final attempted = planHostRestore(
      prefs,
      const [],
      codexAttempted: const {'default'},
      acpAttempted: const {'agent', 'other'},
      acpSupported: true,
    );
    expect(attempted.isEmpty, isTrue);
    final unsupported = planHostRestore(
      prefs,
      const [],
      codexAttempted: const {'default'},
      acpAttempted: const {},
      acpSupported: false,
    );
    expect(unsupported.acp, isEmpty);
  });

  test('restore runs every planned ACP host with its saved argv', () async {
    final api = FakeBridgeApi();
    const spec = AcpAgentSpec(
      profileId: 'custom-x',
      displayName: 'X',
      program: '/bin/x',
      args: ['a b', ''],
    );
    final restored = await runHostRestore(
      api,
      const HostRestorePlan(
        acp: [AutoHostAcpPrefs(name: 'x', spec: spec)],
      ),
    );
    expect(restored, isTrue);
    expect(api.acpServeCalls.single.$2.args, ['a b', '']);
  });

  test('preferences grow compatibly and drop malformed ACP records', () {
    final old = UiPrefs.fromJson({
      'autoHost': {'name': 'default', 'port': 0},
    });
    expect(old.acpAgents, isEmpty);
    expect(old.autoHostAcp, isEmpty);
    expect(old.toJson().containsKey('acpAgents'), isFalse);
    final parsed = UiPrefs.fromJson({
      'acpAgents': [
        {
          'profileId': 'custom-a',
          'displayName': 'A',
          'program': '/bin/a',
          'args': ['x', ''],
        },
        {'profileId': 'broken'},
        'garbage',
      ],
      'autoHostAcp': [
        {
          'name': 'a',
          'spec': {
            'profileId': 'custom-a',
            'displayName': 'A',
            'program': '/bin/a',
            'args': <String>[],
          },
        },
        {'name': '', 'spec': null},
      ],
    });
    expect(parsed.acpAgents.single.args, ['x', '']);
    expect(parsed.autoHostAcp.single.name, 'a');
    final again = UiPrefs.fromJson(parsed.toJson());
    expect(again.acpAgents.single, parsed.acpAgents.single);
  });

  test('a single legacy Codex record migrates to the per-instance list', () {
    final legacy = UiPrefs.fromJson({
      'autoHost': {'name': 'work', 'port': 18081, 'proxy': 'http://p:1'},
    });
    expect(legacy.autoHostCodex.single.name, 'work');
    expect(legacy.autoHost?.port, 18081);
    // Written back, the first record stays under the legacy key too, so an
    // older build still restores one host.
    final json = legacy.toJson();
    expect((json['autoHost'] as Map)['name'], 'work');
    expect((json['autoHostCodex'] as List).single['name'], 'work');
    // The list wins over the legacy key; duplicate names keep the first.
    final both = UiPrefs.fromJson({
      'autoHost': {'name': 'stale', 'port': 1},
      'autoHostCodex': [
        {'name': 'a', 'port': 0},
        {'name': 'b', 'port': 18081},
        {'name': 'a', 'port': 9},
        'garbage',
      ],
    });
    expect(both.autoHostCodex.map((h) => (h.name, h.port)), [
      ('a', 0),
      ('b', 18081),
    ]);
    expect(UiPrefs.fromJson(const {}).autoHostCodex, isEmpty);
  });

  test('every saved Codex host restores once, skipping names in use', () {
    const prefs = UiPrefs(
      autoHostCodex: [
        AutoHostPrefs(port: 0, name: 'default'),
        AutoHostPrefs(port: 0, name: 'work'),
        AutoHostPrefs(port: 0, name: 'beta'),
      ],
    );
    final plan = planHostRestore(
      prefs,
      // `default` already runs; `beta` is held by an ACP host.
      [const AppServeStatus(name: 'default', device: 'local'), _acpHost],
      codexAttempted: const {},
      acpAttempted: const {},
      acpSupported: true,
    );
    expect(plan.codex.map((h) => h.name), ['work']);
    final again = planHostRestore(
      prefs,
      const [],
      codexAttempted: const {'default', 'work', 'beta'},
      acpAttempted: const {},
      acpSupported: true,
    );
    expect(again.codex, isEmpty);
  });

  test('restore runs every planned Codex host under its own name', () async {
    final api = FakeBridgeApi();
    final restored = await runHostRestore(
      api,
      const HostRestorePlan(
        codex: [
          AutoHostPrefs(port: 0, name: 'a'),
          AutoHostPrefs(port: 18081, name: 'b'),
        ],
      ),
    );
    expect(restored, isTrue);
    expect(api.serveHosts.map((h) => h.name), ['a', 'b']);
  });

  test('OpenCode is restored with its saved model service and runtime, '
      'its stored key kept', () async {
    final api = FakeBridgeApi();
    api.hostConfigs['studio'] = const HostConfig(
      source: 'custom',
      protocol: 'anthropic-messages',
      baseUrl: 'https://gateway.example',
      model: 'claude-sonnet',
      keySet: true,
      revision: 4,
      runtime: HostRuntime.opencode(binary: '/opt/opencode'),
    );
    final restored = await runHostRestore(
      api,
      const HostRestorePlan(
        opencode: AutoHostOpenCodePrefs(name: 'studio', binary: '/old/oc'),
      ),
    );
    expect(restored, isTrue);
    final (name, runtime, input, action, key) = api.startConfiguredCalls.single;
    expect(name, 'studio');
    expect(runtime.isOpenCode, isTrue);
    expect(runtime.binary, '/opt/opencode', reason: 'the desired runtime');
    expect(input.source, 'custom');
    expect(input.protocol, 'anthropic-messages');
    expect(input.baseUrl, 'https://gateway.example');
    expect(input.model, 'claude-sonnet');
    expect(action, HostKeyAction.keep);
    expect(key, isNull, reason: 'no key is read back or resent');
  });

  test('an unreadable OpenCode configuration restores nothing and replaces '
      'nothing', () async {
    final api = FakeBridgeApi()
      ..hostConfigGetError = StateError('profile unreadable');
    api.hostConfigs['studio'] = const HostConfig(
      source: 'custom',
      protocol: 'responses',
      baseUrl: 'https://models.example/v1',
      model: 'm',
      keySet: true,
    );
    final restored = await runHostRestore(
      api,
      const HostRestorePlan(
        opencode: AutoHostOpenCodePrefs(name: 'studio', binary: '/bin/oc'),
      ),
    );
    expect(restored, isFalse);
    expect(api.startConfiguredCalls, isEmpty);
    expect(api.hostConfigs['studio']!.source, 'custom');
  });

  // A damaged record is reported, not thrown: its fields are only defaults
  // (source inherited), and starting from them would save over it.
  test('a damaged OpenCode configuration restores nothing and replaces '
      'nothing', () async {
    const damaged = HostConfig(revision: 7, problem: 'unreadable profile');
    final api = FakeBridgeApi();
    api.hostConfigs['studio'] = damaged;
    final restored = await runHostRestore(
      api,
      const HostRestorePlan(
        opencode: AutoHostOpenCodePrefs(name: 'studio', binary: '/bin/oc'),
      ),
    );
    expect(restored, isFalse);
    expect(api.startConfiguredCalls, isEmpty);
    expect(api.serveHosts, isEmpty);
    expect(identical(api.hostConfigs['studio'], damaged), isTrue);
  });

  test('an OpenCode record whose saved runtime is another engine restores '
      'nothing and replaces nothing', () async {
    const other = HostConfig(
      source: 'custom',
      protocol: 'responses',
      baseUrl: 'https://models.example/v1',
      keySet: true,
      revision: 3,
      runtime: HostRuntime.codex(binary: '/usr/local/bin/codex'),
    );
    final api = FakeBridgeApi();
    api.hostConfigs['studio'] = other;
    final restored = await runHostRestore(
      api,
      const HostRestorePlan(
        opencode: AutoHostOpenCodePrefs(name: 'studio', binary: '/bin/oc'),
      ),
    );
    expect(restored, isFalse);
    expect(api.startConfiguredCalls, isEmpty);
    expect(api.serveHosts, isEmpty);
    expect(identical(api.hostConfigs['studio'], other), isTrue);
  });

  test('a skipped OpenCode restore keeps its restore record', () {
    // The plan is made from the record; nothing in a refused restore
    // touches preferences, so the next launch plans it again.
    const prefs = UiPrefs(
      autoHostOpenCode: AutoHostOpenCodePrefs(name: 'studio', binary: '/oc'),
    );
    final plan = planHostRestore(
      prefs,
      const [],
      codexAttempted: const {},
      acpAttempted: const {},
      acpSupported: true,
    );
    expect(plan.opencode?.name, 'studio');
  });

  group('restore records decided on the loaded file', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final full = [
      for (var i = 0; i < UiPrefs.maxAutoHosts; i++)
        AutoHostPrefs(port: 0, name: 'h$i'),
    ];

    testWidgets('a Codex host started while a full file is still loading '
        'says it will not be restored, and keeps every record', (t) async {
      final gate = Completer<void>();
      final prefs = _HeldPrefs(UiPrefs(autoHostCodex: full), gate);
      final api = FakeBridgeApi();
      final c = await _pumpDialog(t, api, prefs: prefs);
      await _start(t);
      expect(api.lastServeName, 'default', reason: 'hosting started');
      expect(find.byType(LocalHostDialog), findsNothing);
      // The interim snapshot looks empty; no verdict yet, so no notice.
      expect(find.text(en.hostRestoreFull(UiPrefs.maxAutoHosts)), findsNothing);
      gate.complete();
      await t.pumpAndSettle();
      expect(
        find.text(en.hostRestoreFull(UiPrefs.maxAutoHosts)),
        findsOneWidget,
      );
      final settled = await c.read(uiPrefsProvider.notifier).ready;
      expect(settled.autoHostCodex.map((h) => h.name), [
        for (final h in full) h.name,
      ]);
      await c.read(uiPrefsProvider.notifier).debugWritesDone;
      expect(prefs.written.last.autoHostCodex.map((h) => h.name), [
        for (final h in full) h.name,
      ]);
    });

    testWidgets('with room in the loading file the record is stored without '
        'a notice', (t) async {
      final gate = Completer<void>();
      final prefs = _HeldPrefs(UiPrefs(autoHostCodex: full.sublist(1)), gate);
      final api = FakeBridgeApi();
      final c = await _pumpDialog(t, api, prefs: prefs);
      await _start(t);
      gate.complete();
      await t.pumpAndSettle();
      expect(find.text(en.hostRestoreFull(UiPrefs.maxAutoHosts)), findsNothing);
      final settled = await c.read(uiPrefsProvider.notifier).ready;
      expect(settled.autoHostCodex.map((h) => h.name), [
        for (final h in full.sublist(1)) h.name,
        'default',
      ]);
    });

    testWidgets('an ACP host and a custom agent refused by a full file are '
        'reported and not shown as saved', (t) async {
      final gate = Completer<void>();
      final prefs = _HeldPrefs(
        UiPrefs(
          autoHostAcp: [
            for (var i = 0; i < UiPrefs.maxAutoHosts; i++)
              AutoHostAcpPrefs(
                name: 'x$i',
                spec: AcpAgentSpec(
                  profileId: 'custom-x$i',
                  displayName: 'X$i',
                  program: '/opt/agents/x$i',
                ),
              ),
          ],
          acpAgents: [
            for (var i = 0; i < UiPrefs.maxSavedAgents; i++)
              AcpAgentSpec(
                profileId: 'custom-s$i',
                displayName: 'S$i',
                program: '/opt/agents/s$i',
              ),
          ],
        ),
        gate,
      );
      final api = FakeBridgeApi();
      final c = await _pumpDialog(t, api, prefs: prefs);
      await _chooseCustom(t);
      await t.enterText(
        find.byKey(const Key('acp-display-name-field')),
        'Fresh',
      );
      await t.enterText(
        find.byKey(const Key('acp-program-field')),
        '/opt/agents/fresh',
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await _start(t);
      expect(api.acpServeCalls, hasLength(1), reason: 'hosting started');
      gate.complete();
      await t.pumpAndSettle();
      final notice = find.textContaining(
        en.hostRestoreFull(UiPrefs.maxAutoHosts),
      );
      expect(notice, findsOneWidget);
      expect(
        find.textContaining(en.acpSavedAgentsFull(UiPrefs.maxSavedAgents)),
        findsOneWidget,
      );
      final settled = await c.read(uiPrefsProvider.notifier).ready;
      expect(
        settled.acpAgents.map((a) => a.displayName),
        isNot(contains('Fresh')),
      );
      expect(settled.acpAgents, hasLength(UiPrefs.maxSavedAgents));
      expect(settled.autoHostAcp.map((h) => h.name), isNot(contains('agent')));
      // Reopened, the agent grid offers no saved tile for it.
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'agent-choice-saved:custom-fresh',
              ),
        ),
        findsNothing,
      );
    });
  });
}
