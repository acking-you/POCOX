part of '../hosting_editor_test.dart';

void _openCodeHostTests() {
  testWidgets('native OpenCode starts with its own configuration by default', (
    t,
  ) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'agent-choice-opencode');
    expect(find.byKey(const Key('opencode-runtime-section')), findsOneWidget);
    expect(
      find.text(
        _l10n(t).openCodeFoundAt('1.19.0', '/Users/me/.opencode/bin/opencode'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('host-inherited-opencode')), findsOneWidget);
    // No ACP program/argv; its own configuration or a custom provider, and
    // no official account.
    expect(find.byKey(const Key('acp-host-form')), findsNothing);
    expect(find.byKey(const Key('host-source-inherited')), findsOneWidget);
    expect(find.byKey(const Key('host-source-custom')), findsOneWidget);
    expect(find.byKey(const Key('host-source-official')), findsNothing);
    expect(find.text(_l10n(t).hostInheritedOnly), findsNothing);
    await _tapKey(t, 'start-hosting-btn');

    final (name, runtime, input, action, key) = api.startConfiguredCalls.single;
    expect(name, 'opencode');
    expect(runtime.isOpenCode, isTrue);
    expect(runtime.binary, isNull, reason: 'a detected one is resolved there');
    expect(input.source, 'inherited');
    // A new host never keeps a key left under its name.
    expect(action, HostKeyAction.remove);
    expect(key, isNull);
    expect(api.serveHosts.single.isOpenCode, isTrue);
    expect(find.byType(HostingEditor), findsNothing);
  });

  testWidgets('a new OpenCode host can use a custom provider of each API', (
    t,
  ) async {
    final api = FakeBridgeApi();
    await _pumpEditor(t, api);
    await _tapKey(t, 'agent-choice-opencode');
    await _tapKey(t, 'host-source-custom');
    for (final protocol in const [
      'responses',
      'anthropic-messages',
      'chat-completions',
    ]) {
      expect(find.byKey(Key('host-protocol-$protocol')), findsOneWidget);
    }
    await _tapKey(t, 'host-protocol-anthropic-messages');
    await _enter(t, 'host-base-url', 'https://gateway.example');
    // The bridge asks for a model and a key: nothing starts without them.
    await _tapKey(t, 'start-hosting-btn');
    expect(api.startConfiguredCalls, isEmpty);
    expect(find.text(_l10n(t).hostModelRequired), findsWidgets);
    await _enter(t, 'host-model', 'claude-sonnet');
    await _tapKey(t, 'start-hosting-btn');
    expect(api.startConfiguredCalls, isEmpty);
    expect(find.text(_l10n(t).hostKeyRequired), findsWidgets);
    await _enter(t, 'host-api-key', 'sk-test');
    await _tapKey(t, 'start-hosting-btn');

    final (_, runtime, input, action, key) = api.startConfiguredCalls.single;
    expect(runtime.isOpenCode, isTrue);
    expect(input.source, 'custom');
    expect(input.protocol, 'anthropic-messages');
    expect(input.baseUrl, 'https://gateway.example');
    expect(input.model, 'claude-sonnet');
    expect(action, HostKeyAction.replace);
    expect(key, 'sk-test');
    expect(api.hostConfigs['opencode']!.keySet, isTrue);
    expect(find.byType(HostingEditor), findsNothing);
  });

  testWidgets('a running OpenCode host keeps, replaces or removes its stored '
      'key; the key is never shown', (t) async {
    final api = FakeBridgeApi();
    final running = FakeBridgeApi.openCodeHost('opencode');
    api.serveHosts.add(running);
    api.hostConfigs['opencode'] = const HostConfig(
      source: 'custom',
      protocol: 'chat-completions',
      baseUrl: 'https://models.example/v1',
      model: 'fixture/model',
      keySet: true,
      revision: 2,
      runtime: HostRuntime.opencode(),
    );
    await _pumpEditor(t, api, existing: running);
    expect(
      find.byKey(const Key('host-protocol-chat-completions')),
      findsOneWidget,
    );
    expect(find.text(_l10n(t).hostApiKeyStored), findsOneWidget);
    final field = t.widget<TextField>(find.byKey(const Key('host-api-key')));
    expect(field.controller!.text, isEmpty, reason: 'no key is read back');

    await _enter(t, 'host-model', 'fixture/other');
    await _tapKey(t, 'host-config-save');
    expect(api.hostConfigSaves.last.$3, HostKeyAction.keep);
    expect(api.hostConfigSaves.last.$4, isNull);
    expect(api.hostConfigs['opencode']!.keySet, isTrue);
    expect(
      api.serveHosts.single.incarnation,
      running.incarnation,
      reason: 'saving restarts nothing',
    );

    await _enter(t, 'host-api-key', 'sk-new');
    await _tapKey(t, 'host-config-save');
    expect(api.hostConfigSaves.last.$3, HostKeyAction.replace);
    expect(api.hostConfigSaves.last.$4, 'sk-new');

    // Back to OpenCode's own configuration: the key goes with the provider.
    await _tapKey(t, 'host-source-inherited');
    await _tapKey(t, 'host-config-save');
    expect(api.hostConfigSaves.last.$3, HostKeyAction.remove);
    expect(api.hostConfigs['opencode']!.source, 'inherited');
  });

  testWidgets('a missing OpenCode is said before anything starts', (t) async {
    final api = FakeBridgeApi()
      ..openCodeEnvironment = const OpenCodeEnvironment(problem: 'not_found');
    await _pumpEditor(t, api);
    await _tapKey(t, 'agent-choice-opencode');
    final l10n = _l10n(t);
    expect(find.text(l10n.openCodeNotFound), findsOneWidget);
    expect(find.byKey(const Key('opencode-path-field')), findsOneWidget);
    await _tapKey(t, 'start-hosting-btn');
    expect(api.startConfiguredCalls, isEmpty);
    expect(find.byType(HostingEditor), findsOneWidget);
  });

  testWidgets('a second OpenCode host is refused with guidance', (t) async {
    final api = FakeBridgeApi()
      ..openCodeServeError = StateError('opencode_already_hosted');
    await _pumpEditor(t, api);
    await _tapKey(t, 'agent-choice-opencode');
    await _tapKey(t, 'start-hosting-btn');
    expect(find.text(_l10n(t).openCodeAlreadyHosted), findsOneWidget);
    expect(find.byType(HostingEditor), findsOneWidget);
  });

  testWidgets('a running OpenCode host is opened, never started twice', (
    t,
  ) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(FakeBridgeApi.openCodeHost('studio'));
    await _pumpEditor(t, api);
    final l10n = _l10n(t);
    expect(find.text(l10n.agentChoiceRunningAs('studio')), findsOneWidget);
    await _tapKey(t, 'agent-choice-opencode');
    // The tile opened that host's own page.
    expect(find.byKey(const Key('opencode-host-details')), findsOneWidget);
    expect(find.byKey(const Key('opencode-scope-note')), findsOneWidget);
    expect(api.startConfiguredCalls, isEmpty);
  });

  testWidgets('a running host without a provider says so; Refresh re-reads', (
    t,
  ) async {
    final api = FakeBridgeApi();
    final running = FakeBridgeApi.openCodeHost(
      'opencode',
      status: const OpenCodeHostStatus(
        version: '1.19.0',
        providersConnected: 0,
        models: 0,
      ),
    );
    api.serveHosts.add(running);
    await _pumpEditor(t, api, existing: running);
    expect(find.byKey(const Key('opencode-problem')), findsOneWidget);
    expect(find.text(_l10n(t).openCodeNoProvider), findsOneWidget);
    // Refresh asks this host, by name, to re-read OpenCode's catalog, and
    // the page shows what the same host reports afterwards.
    api.openCodeRefreshStatus = const OpenCodeHostStatus(
      version: '1.19.0',
      providersConnected: 1,
      models: 3,
      defaultModel: 'fixture/new',
      agents: ['build'],
    );
    await _tapKey(t, 'opencode-refresh');
    expect(api.openCodeRefreshCalls, ['opencode']);
    expect(find.byKey(const Key('opencode-problem')), findsNothing);
    final details = find.byKey(const Key('opencode-host-details'));
    Finder inDetails(String text) =>
        find.descendant(of: details, matching: find.text(text));
    expect(inDetails('fixture/new'), findsOneWidget);
    expect(inDetails('3'), findsOneWidget);
    final refreshed = api.serveHosts.single;
    expect(refreshed.name, 'opencode');
    expect(refreshed.incarnation, running.incarnation);
    expect(refreshed.appServiceKey, running.appServiceKey);
    expect(api.startConfiguredCalls, isEmpty);
  });

  testWidgets('Refresh stays offered on a healthy host and reports a failure', (
    t,
  ) async {
    final api = FakeBridgeApi();
    final running = FakeBridgeApi.openCodeHost('opencode');
    api.serveHosts.add(running);
    await _pumpEditor(t, api, existing: running);
    expect(find.byKey(const Key('opencode-problem')), findsNothing);
    final refresh = find.byKey(const Key('opencode-refresh'));
    expect(refresh, findsOneWidget);
    // Busy while the host reads: a second tap starts nothing.
    final gate = Completer<void>();
    api.openCodeRefreshGate = gate;
    api.openCodeRefreshError = StateError('catalog unreachable');
    await t.ensureVisible(refresh);
    await t.tap(refresh);
    await t.pump();
    await t.tap(refresh, warnIfMissed: false);
    await t.pump();
    expect(api.openCodeRefreshCalls, ['opencode']);
    gate.complete();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('opencode-refresh-error')), findsOneWidget);
    expect(find.textContaining('catalog unreachable'), findsOneWidget);
    // The host and its status are unchanged; Refresh can be tried again.
    expect(api.serveHosts.single.opencode?.models, 2);
    await _tapKey(t, 'opencode-refresh');
    expect(api.openCodeRefreshCalls, ['opencode', 'opencode']);
    expect(find.byKey(const Key('opencode-refresh-error')), findsNothing);
  });

  testWidgets('a refresh answered after the page closed changes nothing', (
    t,
  ) async {
    final api = FakeBridgeApi();
    final running = FakeBridgeApi.openCodeHost('opencode');
    api.serveHosts.add(running);
    final container = await _pumpEditor(t, api, existing: running);
    final gate = Completer<void>();
    api.openCodeRefreshGate = gate;
    api.openCodeRefreshStatus = const OpenCodeHostStatus(
      version: '1.19.0',
      providersConnected: 1,
      models: 3,
    );
    final refresh = find.byKey(const Key('opencode-refresh'));
    await t.ensureVisible(refresh);
    await t.tap(refresh);
    await t.pump();
    await t.pumpWidget(const SizedBox.shrink());
    gate.complete();
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(api.openCodeRefreshCalls, ['opencode']);
    // The host list is still re-read for whoever shows it next.
    final hosts = await container.read(localServeListProvider.future);
    expect(hosts.single.opencode?.models, 3);
  });
}
