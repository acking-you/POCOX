part of '../hosting_editor_test.dart';

void _runningHostTests() {
  testWidgets('nothing is editable until the saved configuration is read', (
    t,
  ) async {
    final gate = Completer<void>();
    final api = FakeBridgeApi()..hostConfigGetGate = gate;
    api.serveHosts.add(_codexHost);
    // The read is held, so the page cannot settle on it: pump instead.
    await _mount(t, api, const HostingEditor(existing: _codexHost));
    await t.pump();
    expect(find.byKey(const Key('host-config-loading')), findsOneWidget);
    expect(find.byKey(const Key('host-config-save')), findsNothing);
    expect(find.byKey(const Key('host-base-url')), findsNothing);

    gate.complete();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-config-loading')), findsNothing);
    expect(find.byKey(const Key('host-config-save')), findsOneWidget);
    expect(find.byKey(const Key('codex-runtime-section')), findsOneWidget);
  });

  testWidgets('a failed read offers a retry and blocks saving', (t) async {
    final api = FakeBridgeApi()
      ..hostConfigGetError = StateError('profiles unreadable');
    api.serveHosts.add(_codexHost);
    await _pumpEditor(t, api, existing: _codexHost);

    expect(find.byKey(const Key('host-config-load-failed')), findsOneWidget);
    expect(find.textContaining('profiles unreadable'), findsOneWidget);
    expect(find.byKey(const Key('host-config-save')), findsNothing);

    await _tapKey(t, 'host-config-retry');
    expect(find.byKey(const Key('host-config-load-failed')), findsNothing);
    expect(find.byKey(const Key('host-config-save')), findsOneWidget);
    expect(api.hostConfigGets, 2);
  });

  testWidgets('a running Codex runtime is saved without a restart, then '
      'applied after confirmation', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    await _pumpEditor(t, api, existing: _codexHost);
    final l10n = _l10n(t);

    // Filled from what the host runs; its name is fixed.
    expect(
      find.text(l10n.codexFoundAt('/usr/local/bin/codex')),
      findsOneWidget,
    );
    final name = t.widget<TextField>(find.byKey(const Key('codex-name-field')));
    expect(name.enabled, isFalse);
    expect(_onPressed(t, 'host-config-save'), isNull, reason: 'unchanged');

    await _openAdvanced(t, 'codex-advanced-toggle');
    await _enter(t, 'codex-port-field', '18081');
    await _enter(t, 'proxy-field', 'http://127.0.0.1:22222');
    await _tapKey(t, 'host-config-save');

    final runtime = api.hostConfigSaveRuntimes.single!;
    expect(runtime.isCodex, isTrue);
    expect(runtime.binary, '/usr/local/bin/codex');
    expect(runtime.port, 18081);
    expect(runtime.proxy, 'http://127.0.0.1:22222');
    expect(api.applyCalls, isEmpty, reason: 'save never restarts');
    expect(api.serveHosts.single.appListenAddr, '127.0.0.1:18080');
    expect(find.text(l10n.hostConfigSaved), findsOneWidget);
    expect(find.byKey(const Key('host-config-pending')), findsOneWidget);

    // Applying explains the interruption first; cancelling changes nothing.
    await _tapKey(t, 'host-config-apply');
    expect(find.byKey(const Key('host-apply-dialog')), findsOneWidget);
    expect(find.text(l10n.hostApplyConfirmBody), findsOneWidget);
    await _tapKey(t, 'host-apply-cancel');
    expect(api.applyCalls, isEmpty);

    await _tapKey(t, 'host-config-apply');
    await _tapKey(t, 'host-apply-confirm');
    expect(api.applyCalls.single, ('alpha', 'inc-alpha', 1));
    expect(api.serveHosts.single.appListenAddr, '127.0.0.1:18081');
    expect(find.text(l10n.hostApplied), findsOneWidget);
    expect(find.byKey(const Key('host-config-pending')), findsNothing);
  });

  testWidgets('a detection begun before a refill never reaches the running '
      'host', (t) async {
    // A host whose executable is unknown: its first fill looks one up.
    const unknown = AppServeStatus(
      name: 'alpha',
      device: 'local',
      pid: 4242,
      alive: true,
      appListenAddr: '127.0.0.1:18080',
      appServiceKey: 'pcx:local:app:alpha',
      appRegistered: true,
      metaListenAddr: '127.0.0.1:18090',
      metaServiceKey: 'pcx:local:meta:alpha',
      metaRegistered: true,
      provider: 'codex',
      configSource: 'inherited',
      configRevision: 0,
      incarnation: 'inc-alpha',
    );
    final api = FakeBridgeApi()..codexPath = '/usr/local/bin/other-codex';
    final detecting = Completer<void>();
    api.codexLocateGate = detecting;
    api.serveHosts.add(unknown);
    final container = await _mount(
      t,
      api,
      const HostingEditor(existing: unknown),
    );
    // Detection keeps a progress bar animating: pump bounded frames.
    Future<void> frames() async {
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
    }

    await frames();
    expect(api.codexLocateCalls, 1, reason: 'the first fill is looking one up');

    // The host is started again elsewhere with a saved executable; the page
    // says so, and its Reload fills the fields again (a second prefill)
    // while the first lookup is still pending.
    api.serveHosts[0] = const AppServeStatus(
      name: 'alpha',
      device: 'local',
      pid: 4343,
      alive: true,
      appListenAddr: '127.0.0.1:18080',
      appServiceKey: 'pcx:local:app:alpha',
      appRegistered: true,
      metaListenAddr: '127.0.0.1:18090',
      metaServiceKey: 'pcx:local:meta:alpha',
      metaRegistered: true,
      codexBinary: '/opt/saved/codex',
      provider: 'codex',
      configSource: 'inherited',
      configRevision: 1,
      incarnation: 'inc-beta',
    );
    api.hostConfigs['alpha'] = const HostConfig(
      revision: 1,
      runtime: HostRuntime.codex(binary: '/opt/saved/codex', port: 18080),
    );
    container.invalidate(localServeListProvider);
    await frames();
    final reload = find.descendant(
      of: find.byKey(const Key('host-replaced')),
      matching: find.byType(TextButton),
    );
    expect(reload, findsOneWidget);
    await t.tap(reload);
    await frames();
    expect(find.byKey(const Key('host-replaced')), findsNothing);

    // The old lookup answers last; it never replaces the explicit path.
    detecting.complete();
    await frames();
    await t.pumpAndSettle();
    expect(find.textContaining('/opt/saved/codex'), findsWidgets);
    expect(find.textContaining('/usr/local/bin/other-codex'), findsNothing);
    expect(_onPressed(t, 'host-config-save'), isNull, reason: 'not an edit');
  });

  testWidgets('a running generic ACP agent is edited from what it runs', (
    t,
  ) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_acpHost);
    api.activeRuntimes['tool'] = const HostRuntime.acp(_genericAgent);
    await _pumpEditor(t, api, existing: _acpHost);

    expect(find.byKey(const Key('host-agent-edit')), findsOneWidget);
    expect(find.text('Tool'), findsWidgets);
    await _enter(t, 'acp-display-name-field', 'Tool (edited)');
    await _tapKey(t, 'host-config-save');

    final runtime = api.hostConfigSaveRuntimes.single!;
    expect(runtime.agent!.displayName, 'Tool (edited)');
    expect(runtime.agent!.program, _genericAgent.program);
    expect(runtime.agent!.args, _genericAgent.args, reason: 'args kept');
    expect(runtime.agent!.profileId, _genericAgent.profileId);
    expect(api.applyCalls, isEmpty);
  });

  testWidgets('a saved provider API this agent cannot use is kept and blocks '
      'saving', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_acpHost);
    // The Claude preset takes a custom provider over Anthropic Messages only.
    api.activeRuntimes['tool'] = const HostRuntime.acp(
      AcpAgentSpec(
        profileId: 'claude',
        displayName: 'Claude',
        program: 'claude-agent-acp',
      ),
    );
    // Saved with the Responses API, which this agent cannot use.
    api.hostConfigs['tool'] = const HostConfig(
      source: 'custom',
      protocol: 'responses',
      baseUrl: 'https://models.example/v1',
      keySet: true,
      revision: 2,
    );
    await _pumpEditor(t, api, existing: _acpHost);
    final l10n = _l10n(t);

    expect(find.byKey(const Key('host-source-incompatible')), findsOneWidget);
    expect(find.text(l10n.hostSourceUnsupported), findsOneWidget);
    expect(find.text('https://models.example/v1'), findsOneWidget);
    // Not quietly replaced by the API it does support.
    final anthropic = t.widget<ServiceChoice>(
      find.byKey(const Key('host-protocol-anthropic-messages')),
    );
    expect(anthropic.selected, isFalse);
    await _tapKey(t, 'host-config-save');
    expect(
      api.hostConfigSaves,
      isEmpty,
      reason: 'the saved API was not swapped',
    );

    // Choosing the supported API clears it.
    await _tapKey(t, 'host-protocol-anthropic-messages');
    expect(find.byKey(const Key('host-source-incompatible')), findsNothing);
  });

  testWidgets('a stored key is kept unless replaced or removed', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    api.hostConfigs['alpha'] = const HostConfig(
      source: 'custom',
      protocol: 'responses',
      baseUrl: 'https://models.example/v1',
      keySet: true,
      revision: 3,
    );
    await _pumpEditor(t, api, existing: _codexHost);

    await _enter(t, 'host-model', 'gpt-next');
    await _tapKey(t, 'host-config-save');
    expect(api.hostConfigSaves.last.$3, HostKeyAction.keep);
    expect(api.hostConfigSaves.last.$4, isNull);
    expect(api.hostConfigSaveRuntimes.last, isNull, reason: 'runtime kept');

    await _tapKey(t, 'host-api-key-remove');
    await _tapKey(t, 'host-config-save');
    expect(api.hostConfigSaves.last.$3, HostKeyAction.remove);
    expect(api.hostConfigs['alpha']!.keySet, isFalse);
  });

  testWidgets('a save made elsewhere meanwhile is refused, not overwritten', (
    t,
  ) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    await _pumpEditor(t, api, existing: _codexHost);
    api.hostConfigs['alpha'] = const HostConfig(
      source: 'official',
      revision: 4,
    );

    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://models.example/v1');
    await _tapKey(t, 'host-config-save');
    expect(find.textContaining('changed elsewhere'), findsOneWidget);
    expect(api.hostConfigs['alpha']!.source, 'official');
  });

  testWidgets('a host restarted elsewhere is not applied by name', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    api.hostConfigs['alpha'] = const HostConfig(
      source: 'official',
      revision: 1,
    );
    final container = await _pumpEditor(t, api, existing: _codexHost);
    api.serveHosts[0] = api.relaunched(api.serveHosts[0]);
    container.invalidate(localServeListProvider);
    await t.pumpAndSettle();

    expect(find.byKey(const Key('host-replaced')), findsOneWidget);
    await _tapKey(t, 'host-config-apply');
    expect(api.applyCalls, isEmpty);
    expect(find.text(_l10n(t).hostReplaced), findsWidgets);
  });

  testWidgets('a host replaced while the save is in flight is not applied', (
    t,
  ) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    await _pumpEditor(t, api, existing: _codexHost);
    final l10n = _l10n(t);

    // The save the apply triggers pauses; meanwhile the host is replaced.
    final gate = Completer<void>();
    api.hostConfigSaveGate = gate;
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://models.example/v1');
    await _tapKeyPumped(t, 'host-config-apply');
    await t.tap(find.byKey(const Key('host-apply-confirm')));
    await t.pump();
    expect(api.hostConfigSaves, hasLength(1), reason: 'the save started');

    api.serveHosts[0] = api.relaunched(api.serveHosts[0]);
    gate.complete();
    await t.pumpAndSettle();

    expect(api.applyCalls, isEmpty, reason: 'the reviewed incarnation is gone');
    expect(find.text(l10n.hostReplaced), findsWidgets);
  });

  testWidgets('a stopped host is not operated on', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    final container = await _pumpEditor(t, api, existing: _codexHost);
    api.serveHosts.clear();
    container.invalidate(localServeListProvider);
    await t.pumpAndSettle();

    expect(find.byKey(const Key('host-gone')), findsOneWidget);
    expect(_onPressed(t, 'stop-hosting-btn'), isNull);
    expect(_onPressed(t, 'host-config-apply'), isNull);
  });

  testWidgets('failed restarts report what runs afterwards', (t) async {
    final api = FakeBridgeApi()
      ..applyResult = const HostApplyResult(
        name: 'alpha',
        applied: false,
        restoredPrevious: true,
        error: 'provider refused',
      );
    api.serveHosts.add(_codexHost);
    api.hostConfigs['alpha'] = const HostConfig(
      source: 'official',
      revision: 1,
    );
    await _pumpEditor(t, api, existing: _codexHost);
    final l10n = _l10n(t);

    // Saved but not running yet: restarting applies it.
    expect(find.text(l10n.hostConfigPending), findsOneWidget);
    await _tapKey(t, 'host-config-apply');
    await _tapKey(t, 'host-apply-confirm');
    expect(
      find.text(l10n.hostApplyRestored('provider refused')),
      findsOneWidget,
    );
    expect(api.hostConfigSaves, isEmpty, reason: 'nothing was edited');

    api.applyResult = const HostApplyResult(
      name: 'alpha',
      applied: false,
      error: 'provider refused',
      restoreError: 'port taken',
    );
    await _tapKey(t, 'host-config-apply');
    await _tapKey(t, 'host-apply-confirm');
    expect(
      find.text(l10n.hostApplyStopped('provider refused', 'port taken')),
      findsOneWidget,
    );
  });

  testWidgets('a later read never overwrites pending edits', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    api.hostConfigs['alpha'] = const HostConfig(
      source: 'official',
      revision: 1,
    );
    await _pumpEditor(t, api, existing: _codexHost);

    // The apply re-reads the configuration; hold that read.
    final gate = Completer<void>();
    api.hostConfigGetGate = gate;
    await _tapKey(t, 'host-config-apply');
    await _tapKey(t, 'host-apply-confirm');
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://mine.example/v1');

    gate.complete();
    await t.pumpAndSettle();
    expect(find.text('https://mine.example/v1'), findsOneWidget);
    expect(find.byKey(const Key('host-config-newer')), findsOneWidget);
  });
}
