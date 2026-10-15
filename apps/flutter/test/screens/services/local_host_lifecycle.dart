part of '../services_test.dart';

void _registerLocalHostLifecycle() {
  testWidgets('desktop account mode: add a host, then stop it', (t) async {
    // The block is desktop-only; force a desktop target. Reset inside the body
    // (not addTearDown) so the framework's debug-var invariant check passes.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);

      // No hosts yet → only the "host another" entry (desktop + account mode).
      expect(find.byKey(const Key('add-local-host-card')), findsOneWidget);

      // Add a host → start on the default port with the default proxy.
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('start-hosting-btn')), findsOneWidget);
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.lastServePort, 18080);
      expect(api.lastServeProxy, 'http://127.0.0.1:11111');
      expect(api.serveHosts, hasLength(1));

      // The running host's card appears; open it → Stop tears it down.
      expect(find.byKey(const Key('local-host-default')), findsOneWidget);
      await t.tap(find.byKey(const Key('local-host-default')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('stop-hosting-btn')), findsOneWidget);
      await t.tap(find.byKey(const Key('stop-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.serveHosts, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a host whose codex did not exit stays listed and stoppable '
      'until a stop succeeds', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake()
        ..serveStopFailures = 1
        ..serveHosts.add(
          const AppServeStatus(
            name: 'stuck',
            device: 'local',
            provider: 'codex',
            protocol: 'codex-app-server',
            providerName: 'Codex',
            agentError: 'its codex did not exit; stop the host again',
          ),
        );
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      expect(find.byKey(const Key('local-host-stuck')), findsOneWidget);
      expect(find.byKey(const Key('local-host-stop-failed')), findsOneWidget);

      await t.tap(find.byKey(const Key('local-host-stuck')));
      await t.pumpAndSettle();
      final stop = find.byKey(const Key('stop-hosting-btn'));
      await t.ensureVisible(stop);
      await t.tap(stop);
      await t.pumpAndSettle();
      expect(api.serveHosts, hasLength(1), reason: 'the failed stop keeps it');
      expect(find.textContaining('did not exit'), findsWidgets);
      expect(
        t.widget<ButtonStyleButton>(stop).onPressed,
        isNotNull,
        reason: 'the retry stays reachable',
      );

      await t.tap(stop);
      await t.pumpAndSettle();
      expect(api.serveHosts, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: turning off the proxy passes no proxy', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      // The proxy field shows by default (proxy is mandatory); toggle it off.
      expect(find.byKey(const Key('proxy-field')), findsOneWidget);
      await tapRevealed(t, find.byKey(const Key('use-proxy-switch')));
      expect(find.byKey(const Key('proxy-field')), findsNothing);
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.lastServeProxy, isNull);
      expect(api.serveHosts, hasLength(1));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: "change path" reveals the codex path field', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake(); // codexLocate returns a path → "found"
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      // Found → no path field, but a "change path" override is offered.
      expect(find.byKey(const Key('codex-path-field')), findsNothing);
      expect(find.byKey(const Key('customize-codex-btn')), findsOneWidget);
      await tapRevealed(t, find.byKey(const Key('customize-codex-btn')));
      expect(find.byKey(const Key('codex-path-field')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: a second host coexists with the first', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    // Tall enough that both host cards and the add button build: the detail is
    // a lazy ListView, so anything below the fold is absent rather than merely
    // scrolled away, and `ensureVisible` has nothing to scroll to.
    t.view.physicalSize = const Size(1200, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);

      // First host "default".
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();

      // A second host defaults to a free name and an automatic port, so it
      // never collides with the first.
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      final name = t.widget<TextField>(
        find.byKey(const Key('codex-name-field')),
      );
      expect(name.controller!.text, 'default-2');
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.lastServeName, 'default-2');
      expect(api.lastServePort, 0);

      // A third, named by hand, with an explicit port behind "Advanced".
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('codex-name-field')), 'work');
      // The toggle spans the dialog's width with its button at the start;
      // reveal and tap the button itself, inside the dialog's scroll view.
      final advanced = find.descendant(
        of: find.byKey(const Key('codex-advanced-toggle')),
        matching: find.byType(TextButton),
      );
      await t.ensureVisible(advanced);
      await t.pumpAndSettle();
      await t.tap(advanced);
      await t.pumpAndSettle();
      final port = find.byKey(const Key('codex-port-field'));
      expect(port, findsOneWidget, reason: 'Advanced unfolded the port');
      await t.ensureVisible(port);
      await t.pumpAndSettle();
      await t.enterText(port, '18081');
      await t.ensureVisible(find.byKey(const Key('start-hosting-btn')));
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.lastServeName, 'work');
      expect(api.lastServePort, 18081);

      expect(api.serveHosts, hasLength(3));
      expect(find.byKey(const Key('local-host-default')), findsOneWidget);
      expect(find.byKey(const Key('local-host-default-2')), findsOneWidget);
      expect(find.byKey(const Key('local-host-work')), findsOneWidget);
      // The add entry stays available however many hosts run.
      expect(find.byKey(const Key('add-local-host-card')), findsOneWidget);

      // Stopping one Codex host forgets only its own restore record.
      final container = ProviderScope.containerOf(
        t.element(find.byType(ServicesScreen)),
      );
      final before = await container.read(uiPrefsProvider.future);
      expect(before.autoHostCodex.map((h) => h.name), [
        'default',
        'default-2',
        'work',
      ]);
      await t.tap(find.byKey(const Key('local-host-default-2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('stop-hosting-btn')));
      await t.pumpAndSettle();
      final after = await container.read(uiPrefsProvider.future);
      expect(after.autoHostCodex.map((h) => h.name), ['default', 'work']);
      expect(api.serveHosts.map((h) => h.name), ['default', 'work']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: a hosted server is labeled local in the App-server '
      'list', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = FakeBridgeApi(
        config: const ConfigInfo(
          relay: '',
          hasKey: false,
          mode: 'account',
          accountLogin: 'acking-you',
        ),
        // A discovered app-server whose key matches the host we'll start.
        services: const [
          ServiceEntry(
            device: 'local',
            kind: 'app',
            name: 'default',
            key: 'pcx:local:app:default',
          ),
        ],
      );
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      // Before hosting, the device is just a discovered remote one.
      expect(find.text('本机'), findsNothing);

      // Host "default" locally → its key matches the discovered service. The
      // title bar's button is the route in when no local device is selected.
      await t.tap(find.byKey(const Key('host-this-device-btn')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();

      // The device now reads as this machine rather than a remote peer, and the
      // host it published is listed under it by name — the state change, not
      // just the presence of the word somewhere on the page.
      expect(find.text('本机'), findsWidgets);
      expect(find.byKey(const Key('local-host-default')), findsOneWidget);
      // Its app-server capability is the same discovered service as before.
      expect(
        find.byKey(const Key('device-capability-pcx:local:app:default')),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: a tunnel can be deregistered, then re-registered', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      // Host one server → it publishes both an app and an api tunnel.
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.serveHosts.single.apiRegistered, isTrue);
      expect(api.serveHosts.single.appRegistered, isTrue);

      // Deregister just the API tunnel. Its capability row owns both actions now
      // — the separate tunnel list described the same three things twice.
      const apiMenu = Key('capability-menu-pcx:local:api:default');
      await t.tap(find.byKey(apiMenu));
      await t.pumpAndSettle();
      await t.tap(find.text('注销')); // deregister (zh)
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('deregister-confirm-btn')));
      await t.pumpAndSettle();
      // Only the api tunnel is unpublished; the app tunnel + host stay up.
      expect(api.serveHosts.single.apiRegistered, isFalse);
      expect(api.serveHosts.single.appRegistered, isTrue);

      // The row stays — listed as offline — so re-registering is still reachable.
      // Hiding it would strand the tunnel with no route back.
      expect(find.text('已下架'), findsOneWidget); // tunnelOffline (zh)
      await t.tap(find.byKey(apiMenu));
      await t.pumpAndSettle();
      await t.tap(find.text('重新注册')); // reregister (zh)
      await t.pumpAndSettle();
      expect(api.serveHosts.single.apiRegistered, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: the session tunnel can be taken down and put back', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();
      expect(api.serveHosts.single.metaRegistered, isTrue);

      // Session sharing rides its own tunnel, so it unpublishes like the other
      // two — the row it replaced offered exactly this.
      const metaMenu = Key('capability-menu-meta-pcx:local:app:default');
      await t.tap(find.byKey(metaMenu));
      await t.pumpAndSettle();
      await t.tap(find.text('注销')); // deregister (zh)
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('deregister-confirm-btn')));
      await t.pumpAndSettle();
      expect(api.serveHosts.single.metaRegistered, isFalse);
      // The app tunnel it shares a row-key with is untouched.
      expect(api.serveHosts.single.appRegistered, isTrue);

      await t.tap(find.byKey(metaMenu));
      await t.pumpAndSettle();
      await t.tap(find.text('重新注册')); // reregister (zh)
      await t.pumpAndSettle();
      expect(api.serveHosts.single.metaRegistered, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('local-host: each tunnel is described once, address and all', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = accountFake();
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();

      // The capability row IS the tunnel row now: each protocol is named once,
      // on the same line as the listen address that only the tunnel row used to
      // carry. A second mention would mean the duplicate list is back.
      expect(find.textContaining('App-server'), findsOneWidget);
      expect(
        find.textContaining(RegExp(r'App-server\s+·\s+127\.0\.0\.1:18080')),
        findsOneWidget,
      );
      expect(
        find.textContaining(RegExp(r'^API\s+·\s+127\.0\.0\.1:')),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Codex and native OpenCode are hosted side by side', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    t.view.physicalSize = const Size(1200, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    try {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
        services: const [],
      );
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();
      await openDevice(t);
      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();

      await t.tap(find.byKey(const Key('add-local-host-card')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('agent-choice-opencode')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('start-hosting-btn')));
      await t.tap(find.byKey(const Key('start-hosting-btn')));
      await t.pumpAndSettle();

      expect(api.serveHosts.map((h) => (h.name, h.provider)), [
        ('default', 'codex'),
        ('opencode', 'opencode'),
      ]);
      // Each card leads with its own agent's mark, from its engine.
      expect(
        find.descendant(
          of: find.byKey(const Key('local-host-icon-default')),
          matching: find.byKey(const Key('agent-icon-codex')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('local-host-icon-opencode')),
          matching: find.byKey(const Key('agent-icon-opencode')),
        ),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
