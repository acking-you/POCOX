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
    // A legacy record carries its own runtime, and no override revision.
    final call = api.restoreServiceCalls.single;
    expect(call.name, 'x');
    expect(call.revision, isNull);
    expect(call.legacy!.agent!.args, ['a b', '']);
  });

  test('an override decides its name: a stop is never undone by old '
      'preferences, and a remotely added host restores too', () {
    const prefs = UiPrefs(
      autoHostCodex: [
        // Aliases of the override and of each other, as the bridge
        // canonicalizes names.
        AutoHostPrefs(port: 0, name: 'My Stopped!'),
        AutoHostPrefs(port: 0, name: 'legacy'),
        AutoHostPrefs(port: 0, name: ' Legacy '),
      ],
      autoHostOpenCode: AutoHostOpenCodePrefs(name: 'oc-old'),
    );
    final plan = planHostRestore(
      prefs,
      const [],
      codexAttempted: const {},
      acpAttempted: const {},
      acpSupported: true,
      overrides: const [
        // Stopped from another device: its legacy record must not count.
        HostRestoreOverride(name: 'my-stopped', revision: 4),
        HostRestoreOverride(
          name: 'remote-added',
          revision: 5,
          runtime: HostRuntime.codex(port: 18090),
        ),
        HostRestoreOverride(
          name: 'oc-new',
          revision: 6,
          runtime: HostRuntime.opencode(),
        ),
      ],
    );
    expect(plan.codex.map((h) => h.name), ['legacy']);
    expect(plan.overrides.map((o) => o.name), ['remote-added', 'oc-new']);
    // One host at a time on OpenCode's default database: the override's
    // wins over the legacy record.
    expect(plan.opencode, isNull);
    expect(plan.names.codex, {'legacy', 'remote-added'});
    expect(plan.names.acp, {'oc-new'});
    // Attempted, hosted or unsupported names are not planned again.
    final again = planHostRestore(
      prefs,
      [FakeBridgeApi.openCodeHost('busy')],
      codexAttempted: const {'my stopped', 'LEGACY', 'Remote Added'},
      acpAttempted: const {},
      acpSupported: true,
      overrides: const [
        HostRestoreOverride(
          name: 'oc-new',
          revision: 6,
          runtime: HostRuntime.opencode(),
        ),
      ],
    );
    expect(again.isEmpty, isTrue);
  });

  test('every restore revalidates through the bridge with the observed '
      'revision; only legacy records carry a runtime', () async {
    final api = FakeBridgeApi()
      ..restoreOverrides = const [
        HostRestoreOverride(
          name: 'remote',
          revision: 9,
          runtime: HostRuntime.codex(port: 18091),
        ),
      ];
    final restored = await runHostRestore(
      api,
      HostRestorePlan(
        overrides: api.restoreOverrides,
        codex: const [AutoHostPrefs(port: 18081, name: 'old')],
      ),
    );
    expect(restored, isTrue);
    expect(api.restoreServiceCalls.map((c) => (c.name, c.revision)), [
      ('remote', 9),
      ('old', null),
    ]);
    expect(api.restoreServiceCalls.first.legacy, isNull);
    expect(api.restoreServiceCalls.last.legacy!.port, 18081);
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

  test('a legacy OpenCode record restores through the bridge with its '
      'runtime, which starts from what is saved for it', () async {
    final api = FakeBridgeApi();
    final restored = await runHostRestore(
      api,
      const HostRestorePlan(
        opencode: AutoHostOpenCodePrefs(name: 'studio', binary: '/old/oc'),
      ),
    );
    expect(restored, isTrue);
    final call = api.restoreServiceCalls.single;
    expect(call.name, 'studio');
    expect(call.revision, isNull);
    expect(call.legacy!.isOpenCode, isTrue);
    expect(call.legacy!.binary, '/old/oc');
    // No configuration is read or re-sent from here: the bridge keeps the
    // saved model service and key, and refuses a damaged record.
    expect(api.startConfiguredCalls, isEmpty);
  });

  test('a refused restore (stopped elsewhere, changed or damaged) starts '
      'nothing', () async {
    final api = FakeBridgeApi()
      ..restoreServiceErrors['studio'] = StateError(
        'this service was stopped; automatic restore was skipped',
      );
    final restored = await runHostRestore(
      api,
      const HostRestorePlan(
        overrides: [
          HostRestoreOverride(
            name: 'studio',
            revision: 3,
            runtime: HostRuntime.opencode(),
          ),
        ],
      ),
    );
    expect(restored, isFalse);
    expect(api.serveHosts, isEmpty);
    expect(api.startConfiguredCalls, isEmpty);
  });

  test('OpenCode hosts with their own history all restore; one host on '
      'the default database', () {
    HostRestorePlan plan(List<AppServeStatus> local) => planHostRestore(
      const UiPrefs(),
      local,
      codexAttempted: const {},
      acpAttempted: const {},
      acpSupported: true,
      overrides: const [
        HostRestoreOverride(
          name: 'oc-a',
          revision: 1,
          runtime: HostRuntime.opencode(),
        ),
        HostRestoreOverride(
          name: 'oc-b',
          revision: 2,
          runtime: HostRuntime.opencode(separateHistory: true),
        ),
        HostRestoreOverride(
          name: 'oc-c',
          revision: 3,
          runtime: HostRuntime.opencode(separateHistory: true),
        ),
        HostRestoreOverride(
          name: 'oc-d',
          revision: 4,
          runtime: HostRuntime.opencode(),
        ),
      ],
    );
    expect(plan(const []).overrides.map((o) => o.name), [
      'oc-a',
      'oc-b',
      'oc-c',
    ]);
    expect(
      plan([FakeBridgeApi.openCodeHost('busy')]).overrides.map((o) => o.name),
      ['oc-b', 'oc-c'],
    );
  });

  group('restore records decided on the loaded file', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final full = [
      for (var i = 0; i < UiPrefs.maxAutoHosts; i++)
        AutoHostPrefs(port: 0, name: 'h$i'),
    ];

    testWidgets('a Codex host started while a full file is still loading '
        'starts without a restore warning, and keeps every record', (t) async {
      final gate = Completer<void>();
      final prefs = _HeldPrefs(UiPrefs(autoHostCodex: full), gate);
      final api = FakeBridgeApi();
      final c = await _pumpDialog(t, api, prefs: prefs);
      await _start(t);
      expect(api.lastServeName, 'default', reason: 'hosting started');
      expect(find.byType(LocalHostDialog), findsNothing);
      gate.complete();
      await t.pumpAndSettle();
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
      final settled = await c.read(uiPrefsProvider.notifier).ready;
      expect(settled.autoHostCodex.map((h) => h.name), [
        for (final h in full.sublist(1)) h.name,
        'default',
      ]);
    });

    testWidgets('a custom agent refused by a full file is reported and not '
        'shown as saved', (t) async {
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

    testWidgets('a restore-record warning is shown beside a successful start, '
        'never as its failure', (t) async {
      final api = FakeBridgeApi()
        ..restoreProblems['default'] = 'storage is read-only';
      await _pumpDialog(t, api);
      await _start(t);
      expect(api.lastServeName, 'default', reason: 'hosting started');
      expect(find.byType(LocalHostDialog), findsNothing);
      // One toast: the start, and the warning beside it.
      expect(
        find.text(
          '${en.managedStarted('default')}\n'
          '${en.managedRestoreProblem('storage is read-only')}',
        ),
        findsOneWidget,
      );
    });
  });
}
