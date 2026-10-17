part of '../acp_hosting_test.dart';

void _registerClaudePreparation() {
  group('the Claude preset', () {
    const missing = AcpClaudeStatus(
      ready: false,
      adapter: 'missing',
      runtime: 'found',
      runtimeVersion: '22.11.0',
      runtimePath: '/usr/local/bin/node',
      cli: 'found',
      cliPath: '/Users/me/.local/bin/claude',
      canPrepare: true,
      package: '@agentclientprotocol/claude-agent-acp@0.89.1',
      problem: 'the adapter is not installed',
    );

    FakeBridgeApi claudeApi(AcpClaudeStatus status) => FakeBridgeApi()
      ..presets = const [
        AcpPreset(
          id: 'claude',
          displayName: 'Claude',
          program: 'claude-agent-acp',
          args: [],
        ),
      ]
      ..claudeStatus = status;

    Future<void> startPreparing(WidgetTester t, FakeBridgeApi api) async {
      await _pumpDialog(t, api);
      await _chooseAcp(t, 'claude');
      expect(
        find.byKey(const Key('claude-adapter-will-prepare')),
        findsOneWidget,
        reason: 'explained before Start',
      );
      expect(
        api.claudePrepareStarts,
        0,
        reason: 'picking the preset downloads nothing',
      );
      await t.ensureVisible(find.byKey(const Key('start-hosting-btn')));
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
    }

    Future<void> prepareOnly(WidgetTester t) async {
      final button = find.byKey(const Key('claude-prepare-environment'));
      await t.ensureVisible(button);
      await t.tap(button);
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
    }

    Future<void> finishPreparation(WidgetTester t) async {
      await t.pump(const Duration(milliseconds: 600));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
    }

    void expectNoHostMutation(FakeBridgeApi api, _HeldPrefs prefs) {
      expect(api.startConfiguredCalls, isEmpty);
      expect(api.acpServeCalls, isEmpty);
      expect(api.hostConfigSaves, isEmpty);
      expect(api.applyCalls, isEmpty);
      expect(prefs.written, isEmpty);
    }

    testWidgets('Prepare refreshes readiness and keeps the draft without '
        'starting or saving; a later Start reuses it', (t) async {
      final api = claudeApi(missing);
      final prefs = _HeldPrefs(const UiPrefs());
      await _pumpDialog(t, api, prefs: prefs);
      await _chooseAcp(t, 'claude');
      final name = find.byKey(const Key('acp-instance-name-field'));
      await t.enterText(name, 'my-claude');
      final semantics = t.ensureSemantics();
      final button = find.byKey(const Key('claude-prepare-environment'));
      await t.ensureVisible(button);
      final node = t.getSemantics(button);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(api.claudePrepareStarts, 1);
      expect(find.byKey(const Key('claude-prepare-progress')), findsOneWidget);
      expect(t.widget<OutlinedButton>(button).onPressed, isNull);
      expectNoHostMutation(api, prefs);
      api.claudeStatus = const AcpClaudeStatus(
        ready: true,
        adapter: 'prepared',
        adapterPath: '/app-cache/claude-agent-acp.js',
        runtime: 'found',
        runtimeVersion: '22.11.0',
        runtimePath: '/usr/local/bin/node',
        cli: 'found',
        cliPath: '/Users/me/.local/bin/claude',
        canPrepare: false,
        package: '@agentclientprotocol/claude-agent-acp@0.89.1',
      );
      api.settleClaudePrepare('done');
      await finishPreparation(t);
      expect(find.byType(LocalHostDialog), findsOneWidget);
      expect(button, findsNothing);
      expect(find.byKey(const Key('claude-adapter')), findsOneWidget);
      expect(t.widget<TextField>(name).controller!.text, 'my-claude');
      expectNoHostMutation(api, prefs);
      expect(find.byKey(const Key('host-editor-notice')), findsOneWidget);
      semantics.dispose();
      await _start(t);
      expect(api.claudePrepareStarts, 1);
      expect(api.acpServeCalls, hasLength(1));
      expect(api.acpServeCalls.single.$1, 'my-claude');
    });

    testWidgets('Prepare can retry failure and cancellation without hosting', (
      t,
    ) async {
      final api = claudeApi(missing);
      final prefs = _HeldPrefs(const UiPrefs());
      await _pumpDialog(t, api, prefs: prefs);
      await _chooseAcp(t, 'claude');
      await prepareOnly(t);
      api.settleClaudePrepare('failed', error: 'npm could not install it');
      await finishPreparation(t);
      expect(find.textContaining('npm could not install it'), findsOneWidget);
      await prepareOnly(t);
      expect(api.claudePrepareStarts, 2);
      await t.tap(find.byKey(const Key('claude-prepare-cancel')));
      await finishPreparation(t);
      expect(api.claudeCancelledRuns, [2]);
      await prepareOnly(t);
      expect(api.claudePrepareStarts, 3);
      api.settleClaudePrepare('done');
      await finishPreparation(t);
      expectNoHostMutation(api, prefs);
    });

    testWidgets('Prepare shows the polled download size and speed, drops '
        'the speed while verifying and leaves once ready', (t) async {
      final api = claudeApi(missing);
      await _pumpDialog(t, api);
      await _chooseAcp(t, 'claude');
      await prepareOnly(t);
      final progress = find.byKey(const Key('claude-prepare-progress'));
      expect(progress, findsOneWidget);
      expect(
        find.descendant(
          of: progress,
          matching: find.byKey(const Key('claude-prepare-downloaded')),
        ),
        findsNothing,
        reason: 'no size before the bridge reports one',
      );
      final run = api.claudeSetup.run;
      api.claudeSetup = AcpClaudeSetup(
        state: 'running',
        stage: 'downloading',
        run: run,
        elapsedMs: 3000,
        downloadedBytes: 2500000,
        downloadBytesPerSecond: 640000,
      );
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('2.5 MB downloaded'), findsOneWidget);
      expect(find.text('640 KB/s'), findsOneWidget);
      expect(find.text('0:03'), findsOneWidget);
      expect(find.byKey(const Key('claude-prepare-cancel')), findsOneWidget);
      expect(find.byKey(const Key('claude-prepare-joined')), findsNothing);
      api.claudeSetup = AcpClaudeSetup(
        state: 'running',
        stage: 'verifying',
        run: run,
        elapsedMs: 9000,
        downloadedBytes: 4100000,
        downloadBytesPerSecond: 0,
      );
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('4.1 MB downloaded'), findsOneWidget);
      expect(find.byKey(const Key('claude-prepare-speed')), findsNothing);
      expect(
        t.widget<Text>(find.byKey(const Key('claude-prepare-title'))).data,
        lookupAppLocalizations(const Locale('en')).claudePrepareStageVerifying,
      );
      api.settleClaudePrepare('done');
      await finishPreparation(t);
      expect(progress, findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('independent Prepare joins without owning cancellation or '
        'using a late result after Stop waiting', (t) async {
      final api = claudeApi(missing)
        ..claudeSetup = const AcpClaudeSetup(
          state: 'running',
          stage: 'installing',
          run: 5,
        );
      final prefs = _HeldPrefs(const UiPrefs());
      await _pumpDialog(t, api, prefs: prefs);
      await _chooseAcp(t, 'claude');
      await prepareOnly(t);
      expect(api.claudePrepareStarts, 0);
      expect(find.byKey(const Key('claude-prepare-cancel')), findsNothing);
      await t.tap(find.byKey(const Key('claude-prepare-stop-waiting')));
      await t.pump();
      api.settleClaudePrepare('done');
      await finishPreparation(t);
      expect(api.claudePrepareCancels, 0);
      // The late result is not this page's: no "ready" notice.
      expect(
        find.text(
          lookupAppLocalizations(const Locale('en')).claudeEnvironmentReady,
        ),
        findsNothing,
      );
      expectNoHostMutation(api, prefs);
    });

    testWidgets(
      'independent Prepare cancels its late owned run after leaving',
      (t) async {
        final api = claudeApi(missing);
        final prefs = _HeldPrefs(const UiPrefs());
        final gate = Completer<void>();
        api.claudePrepareGate = gate;
        await _pumpDialog(t, api, prefs: prefs);
        await _chooseAcp(t, 'claude');
        await prepareOnly(t);
        Navigator.of(t.element(find.byType(LocalHostDialog))).pop();
        await t.pump();
        gate.complete();
        await t.pumpAndSettle();
        expect(api.claudeCancelledRuns, [1]);
        expect(t.takeException(), isNull);
        expectNoHostMutation(api, prefs);
      },
    );

    testWidgets(
      'independent Prepare rechecks prerequisites before downloading',
      (t) async {
        final api = claudeApi(missing);
        await _pumpDialog(t, api);
        await _chooseAcp(t, 'claude');
        api.claudeStatus = const AcpClaudeStatus(
          ready: false,
          adapter: 'missing',
          runtime: 'missing',
          cli: 'bundled',
          canPrepare: false,
          package: '@agentclientprotocol/claude-agent-acp@0.89.1',
          problem: 'Node.js is no longer available',
        );
        await prepareOnly(t);
        await finishPreparation(t);
        expect(api.claudePrepareStarts, 0);
        expect(
          find.byKey(const Key('claude-prepare-environment')),
          findsNothing,
        );
        expect(find.text('Node.js is no longer available'), findsWidgets);
        expect(api.acpServeCalls, isEmpty);
      },
    );

    testWidgets(
      'a running host can prepare its adapter without saving or restarting',
      (t) async {
        const host = AppServeStatus(
          name: 'claude',
          device: 'local',
          alive: true,
          appServiceKey: 'pcx:local:acp:claude',
          provider: 'acp',
          protocol: 'acp',
          profileId: 'claude',
          providerName: 'Claude',
          codexBinary: 'claude-agent-acp',
          agentPhase: 'ready',
        );
        final api = claudeApi(missing)..serveHosts.add(host);
        final prefs = _HeldPrefs(const UiPrefs());
        await _pumpDialog(t, api, existing: host, prefs: prefs);
        await t.pump(const Duration(milliseconds: 400));
        await t.pumpAndSettle();
        await prepareOnly(t);
        expect(
          find.byKey(const Key('claude-prepare-progress')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('claude-prepare-cancel')), findsOneWidget);
        api.settleClaudePrepare('done');
        await finishPreparation(t);
        expect(api.claudePrepareStarts, 1);
        expectNoHostMutation(api, prefs);
        expect(api.serveHosts.single, same(host));
        expect(api.acpRestartCalls, isEmpty);
      },
    );

    testWidgets('Start prepares a missing adapter, then hosts it', (t) async {
      final api = claudeApi(missing);
      await startPreparing(t, api);
      expect(api.claudePrepareStarts, 1);
      expect(find.byKey(const Key('claude-prepare-progress')), findsOneWidget);
      expect(find.byKey(const Key('claude-prepare-cancel')), findsOneWidget);
      expect(
        api.acpServeCalls,
        isEmpty,
        reason: 'not started before it is ready',
      );

      api.settleClaudePrepare('done');
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      expect(api.claudePrepareStarts, 1);
      expect(api.acpServeCalls, hasLength(1));
      expect(api.acpServeCalls.single.$2.program, 'claude-agent-acp');
    });

    testWidgets('a Start before the form showed the download announces it', (
      t,
    ) async {
      final api = claudeApi(missing);
      await _pumpDialog(t, api);
      final tile = find.byKey(const Key('agent-choice-preset:claude'));
      await t.ensureVisible(tile);
      await t.tap(tile);
      await t.pump();
      // Start while the form's detection is still debounced.
      await t.ensureVisible(find.byKey(const Key('start-hosting-btn')));
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pump();
      await t.pump();
      expect(
        api.claudePrepareStarts,
        0,
        reason: 'nothing downloads unannounced',
      );
      expect(
        find.textContaining('@agentclientprotocol/claude-agent-acp@0.89.1'),
        findsWidgets,
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(api.claudePrepareStarts, 1);
      api.settleClaudePrepare('done');
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      expect(api.acpServeCalls, hasLength(1));
    });

    testWidgets('cancelling stops the preparation and starts nothing', (
      t,
    ) async {
      final api = claudeApi(missing);
      await startPreparing(t, api);
      await t.tap(find.byKey(const Key('claude-prepare-cancel')));
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      expect(api.claudePrepareCancels, 1);
      expect(api.acpServeCalls, isEmpty);
      expect(find.byKey(const Key('host-editor-error')), findsOneWidget);
    });

    testWidgets('a failed preparation is reported and Start retries it', (
      t,
    ) async {
      final api = claudeApi(missing);
      await startPreparing(t, api);
      api.settleClaudePrepare('failed', error: 'npm could not install it');
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      expect(find.textContaining('npm could not install it'), findsOneWidget);
      expect(api.acpServeCalls, isEmpty);

      await t.tap(find.byKey(const Key('start-hosting-btn')));
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(api.claudePrepareStarts, 2);
      api.settleClaudePrepare('done');
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      expect(api.acpServeCalls, hasLength(1));
    });

    testWidgets('without a usable Node.js it explains and prepares nothing', (
      t,
    ) async {
      final api = claudeApi(
        const AcpClaudeStatus(
          ready: false,
          adapter: 'missing',
          runtime: 'tooOld',
          runtimeVersion: '20.20.1',
          cli: 'found',
          cliPath: '/Users/me/.local/bin/claude',
          canPrepare: false,
          package: '@agentclientprotocol/claude-agent-acp@0.89.1',
          problem: 'Claude needs Node.js 22 or newer',
        ),
      );
      await _pumpDialog(t, api);
      await _chooseAcp(t, 'claude');
      expect(find.byKey(const Key('claude-adapter-missing')), findsOneWidget);
      expect(find.byKey(const Key('claude-node-old')), findsOneWidget);
      expect(find.byKey(const Key('claude-problem')), findsOneWidget);
      await _start(t);
      expect(api.claudePrepareStarts, 0);
      expect(api.acpServeCalls, isEmpty);
      expect(
        find.text('Claude needs Node.js 22 or newer'),
        findsNWidgets(2),
        reason: 'in the panel and as the Start error',
      );
    });

    // A dialog removed (by the app, bypassing its PopScope) before or
    // during a preparation never goes on to start a host.
    void close(WidgetTester t) =>
        Navigator.of(t.element(find.byType(LocalHostDialog))).pop();

    testWidgets('closed while the environment is read, it starts nothing', (
      t,
    ) async {
      final api = claudeApi(missing);
      await _pumpDialog(t, api);
      await _chooseAcp(t, 'claude');
      final gate = Completer<void>();
      api.claudeStatusGate = gate;
      await t.ensureVisible(find.byKey(const Key('start-hosting-btn')));
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pump();
      close(t);
      await t.pump();
      gate.complete();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(api.claudePrepareStarts, 0);
      expect(api.acpServeCalls, isEmpty);
    });

    testWidgets('closed as a preparation finished at once, it starts nothing', (
      t,
    ) async {
      final api = claudeApi(missing)
        ..claudePrepareAnswer = const AcpClaudeSetup(state: 'done');
      final gate = Completer<void>();
      api.claudePrepareGate = gate;
      await startPreparing(t, api);
      expect(api.claudePrepareStarts, 1);
      close(t);
      await t.pump();
      gate.complete();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(api.acpServeCalls, isEmpty);
    });

    testWidgets('closed while preparing, a later done starts nothing', (
      t,
    ) async {
      final api = claudeApi(missing);
      await startPreparing(t, api);
      expect(api.claudePrepareStarts, 1);
      close(t);
      await t.pump();
      api.settleClaudePrepare('done');
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(api.acpServeCalls, isEmpty);
    });

    // Another page started run 5 and it still runs.
    FakeBridgeApi joinedApi() => claudeApi(missing)
      ..claudeSetup = const AcpClaudeSetup(
        state: 'running',
        stage: 'installing',
        run: 5,
      );

    testWidgets('a preparation joined from another caller is never '
        'cancelled by this page, and Stop waiting (its accessibility action '
        'too) leaves through the page', (t) async {
      final api = joinedApi();
      final semantics = t.ensureSemantics();
      await startPreparing(t, api);
      expect(api.claudePrepareStarts, 0, reason: 'joined, not started');
      expect(find.byKey(const Key('claude-prepare-progress')), findsOneWidget);
      expect(find.byKey(const Key('claude-prepare-joined')), findsOneWidget);
      expect(find.byKey(const Key('claude-prepare-cancel')), findsNothing);
      // Close is unavailable while Start waits; stopping the wait is not.
      final close = t.widget<TextButton>(
        find.byKey(const Key('host-editor-close')),
      );
      expect(close.onPressed, isNull);
      final node = t.getSemantics(
        find.byKey(const Key('claude-prepare-stop-waiting')),
      );
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await t.pump();
      expect(find.byKey(const Key('claude-prepare-progress')), findsNothing);
      expect(api.claudePrepareCancels, 0, reason: 'its run is not ours');
      expect(api.claudeSetup.running, isTrue);
      expect(
        t
            .widget<TextButton>(find.byKey(const Key('host-editor-close')))
            .onPressed,
        isNotNull,
        reason: 'the page may be left',
      );
      semantics.dispose();
      await t.tap(find.byKey(const Key('host-editor-close')));
      await t.pumpAndSettle();
      expect(find.byType(LocalHostDialog), findsNothing);
      expect(api.claudePrepareCancels, 0, reason: 'leaving stops nothing');
      // Its end later starts nothing from the closed page.
      api.settleClaudePrepare('done');
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      expect(api.acpServeCalls, isEmpty);
    });

    testWidgets('a start answered after the page closed stops exactly the '
        'run it started', (t) async {
      final api = claudeApi(missing);
      final gate = Completer<void>();
      api.claudePrepareGate = gate;
      await startPreparing(t, api);
      expect(api.claudePrepareStarts, 1);
      close(t);
      await t.pump();
      expect(api.claudeCancelledRuns, isEmpty, reason: 'no run known yet');
      gate.complete();
      await t.pumpAndSettle();
      expect(api.claudeCancelledRuns, [1], reason: 'its own run, late');
      expect(api.claudeSetup.state, 'cancelled');
      expect(api.acpServeCalls, isEmpty);
    });

    testWidgets('a joined start answered after the page closed cancels '
        'nothing', (t) async {
      final api = joinedApi();
      final gate = Completer<void>();
      api.claudePrepareGate = gate;
      await startPreparing(t, api);
      close(t);
      await t.pump();
      gate.complete();
      await t.pumpAndSettle();
      expect(api.claudeCancelledRuns, isEmpty);
      expect(api.claudeSetup.running, isTrue, reason: 'another owner keeps it');
    });

    testWidgets('a run replaced by another caller is never taken as this '
        "page's result", (t) async {
      final api = claudeApi(missing);
      await startPreparing(t, api);
      expect(api.claudeSetup.run, 1);
      // This page's run ends unseen and another caller's run begins, then
      // finishes: neither is this preparation's outcome.
      api
        ..settleClaudePrepare('cancelled')
        ..startOtherClaudePrepare();
      await t.pump(const Duration(milliseconds: 600));
      await t.pump();
      api.settleClaudePrepare('done');
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      expect(api.acpServeCalls, isEmpty, reason: 'nothing launched from it');
      expect(
        find.byKey(const Key('host-editor-error')),
        findsOneWidget,
        reason: 'an honest retry state',
      );
      expect(find.byKey(const Key('claude-prepare-progress')), findsNothing);
      // Start tries again (and prepares its own run).
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(api.claudePrepareStarts, 2);
    });

    testWidgets('an open dialog whose preparation is done at once hosts', (
      t,
    ) async {
      final api = claudeApi(missing)
        ..claudePrepareAnswer = const AcpClaudeSetup(state: 'done');
      await startPreparing(t, api);
      await t.pumpAndSettle();
      expect(api.claudePrepareStarts, 1);
      expect(api.acpServeCalls, hasLength(1));
    });

    testWidgets('an environment changed since the form showed it is '
        'announced again before anything downloads', (t) async {
      final api = claudeApi(missing);
      await _pumpDialog(t, api);
      await _chooseAcp(t, 'claude');
      expect(
        find.byKey(const Key('claude-adapter-will-prepare')),
        findsOneWidget,
      );
      // Another Node.js is found by the time Start asks.
      api.claudeStatus = const AcpClaudeStatus(
        ready: false,
        adapter: 'missing',
        runtime: 'found',
        runtimeVersion: '23.4.0',
        runtimePath: '/opt/node23/bin/node',
        cli: 'found',
        cliPath: '/Users/me/.local/bin/claude',
        canPrepare: true,
        package: '@agentclientprotocol/claude-agent-acp@0.89.1',
        problem: 'the adapter is not installed',
      );
      await _start(t);
      expect(
        api.claudePrepareStarts,
        0,
        reason: 'announced first, not prepared',
      );
      expect(api.acpServeCalls, isEmpty);
      // The same agent and environment again: now it prepares.
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(api.claudePrepareStarts, 1);
    });
  });
}
