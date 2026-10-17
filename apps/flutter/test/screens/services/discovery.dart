part of '../services_test.dart';

void _registerDiscovery() {
  testWidgets('a device lists every kind it exposes, plus the relay', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'default',
          key: 'pcx:lb7666:api:default',
        ),
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    expect(find.text('lb7666.top:7666'), findsOneWidget);
    await openDevice(t);
    // Both kinds sit under the one device — no tab to switch between them.
    expect(
      find.byKey(const Key('device-capability-pcx:lb7666:api:default')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('device-capability-pcx:lb7666:app:default')),
      findsOneWidget,
    );
  });

  testWidgets('Opening a chat capability returns to the chat on that service', (
    t,
  ) async {
    // "Open" used to push a project picker at /app/:key — a third level whose
    // project tree and conversation list the chat sidebar already shows. It now
    // hands the key to the home and goes back to it.
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );
    late final ProviderContainer container;
    await t.pumpWidget(
      ProviderScope(
        overrides: [bridgeApiProvider.overrideWithValue(api)],
        child: Consumer(
          builder: (c, ref, _) {
            container = ProviderScope.containerOf(c);
            return MaterialApp.router(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: GoRouter(
                initialLocation: '/manage',
                routes: [
                  stub('/', 'chat-home'),
                  GoRoute(path: '/manage', builder: (_, _) => ServicesScreen()),
                ],
              ),
            );
          },
        ),
      ),
    );
    await t.pumpAndSettle();
    await openDevice(t);

    await t.tap(find.text('打开')); // servicesOpen (zh)
    await t.pumpAndSettle();

    // Back on the chat route, with the service handed over for it to switch to.
    expect(find.text('chat-home'), findsOneWidget);
    expect(container.read(requestedServiceProvider), 'pcx:lb7666:app:default');
  });

  testWidgets('Managing an API capability opens a panel, not a page', (
    t,
  ) async {
    // The /api/:key route was a whole page for one port field and one button.
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'default',
          key: 'pcx:lb7666:api:default',
        ),
      ],
    );
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);

    await t.tap(find.text('管理')); // servicesManage (zh)
    await t.pumpAndSettle();

    // The panel is up with its subscribe form, and the capability row it acts
    // on is still mounted behind it — the point of a panel over a route.
    expect(find.byKey(const Key('subscribe-btn')), findsOneWidget);
    expect(
      find.byKey(const Key('device-capability-pcx:lb7666:api:default')),
      findsOneWidget,
    );
  });

  testWidgets('Services shows error state with retry', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'r:1', hasKey: true),
    )..discoverError = Exception('relay down');
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('services-error')), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('Services explains an expired session and offers sign-in', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(
        relay: '',
        hasKey: false,
        mode: 'account',
        accountLogin: 'octocat',
      ),
    )..discoverError = StateError('session expired; sign in again');
    await t.pumpWidget(
      routerHost(
        api,
        initial: '/manage',
        routes: [
          GoRoute(path: '/manage', builder: (_, _) => const ServicesScreen()),
          GoRoute(
            path: '/onboarding',
            builder: (_, state) => Scaffold(
              body: Text('login:${state.uri.queryParameters['reason']}'),
            ),
          ),
        ],
      ),
    );
    await t.pumpAndSettle();

    expect(find.text('登录已过期'), findsOneWidget);
    expect(find.textContaining('请重新登录以恢复服务连接'), findsOneWidget);
    expect(find.text('无法连接到 relay'), findsNothing);
    expect(find.text('重试'), findsNothing);

    await t.tap(find.byKey(const Key('services-sign-in-again')));
    await t.pumpAndSettle();
    expect(find.text('login:session-expired'), findsOneWidget);
  });

  testWidgets('a registered-but-dead app-server reads "unreachable", not '
      '"online"', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    )..reachable['pcx:lb7666:app:default'] = false; // backend probe fails
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(400, 900); // narrow: single-pane list
    addTearDown(t.view.reset);

    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);

    // The probe says the backend is dead → honest "不可达" on the app-server.
    expect(find.text('不可达'), findsOneWidget); // statusUnreachable (zh)
    // The old bug showed a false green "online" here, off a cached flag.
    expect(find.text('在线'), findsNothing);
    // …and it spells out *why*: relay registration up, remote backend down.
    expect(find.textContaining('远端 app-server 没有响应'), findsOneWidget);
  });

  testWidgets('account mode shows the GitHub identity, not "(no relay)"', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(
        relay: '',
        hasKey: false,
        mode: 'account',
        accountLogin: 'acking-you',
      ),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcxu:u:lb7666:app:default',
        ),
      ],
    );
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    // The header shows the signed-in GitHub identity…
    expect(find.text('@acking-you'), findsOneWidget);
    // …and never the confusing "(no relay configured)" placeholder.
    expect(find.text('（未配置 relay）'), findsNothing);
  });

  testWidgets('the identity row is the way into settings', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await t.pumpWidget(
        routerHost(
          accountFake(),
          initial: '/manage',
          routes: [
            GoRoute(path: '/manage', builder: (_, _) => const ServicesScreen()),
            stub('/settings', 'settings-page'),
          ],
        ),
      );
      await t.pumpAndSettle();

      await t.tap(find.byKey(const Key('identity-open-settings')));
      await t.pumpAndSettle();
      expect(find.text('settings-page'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a registered-but-dead API proxy reads "unreachable", not '
      '"online"', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'default',
          key: 'pcx:lb7666:api:default',
        ),
      ],
    )..reachable['pcx:lb7666:api:default'] = false; // proxy probe fails
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(400, 900); // narrow: single-pane list
    addTearDown(t.view.reset);

    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle(); // let the API probe resolve
    await openDevice(t);

    // The probe says the proxy is dead → honest "不可达" on the API service…
    expect(find.text('不可达'), findsOneWidget);
    // …and spells out that the dead link is the remote API service.
    expect(find.textContaining('远端 API 服务没有响应'), findsOneWidget);
  });

  testWidgets('app-server auto-re-probes: a recovered server flips to online '
      'without a manual refresh', (t) async {
    final api =
        FakeBridgeApi(
            config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
            services: const [
              ServiceEntry(
                device: 'lb7666',
                kind: 'app',
                name: 'default',
                key: 'pcx:lb7666:app:default',
              ),
            ],
          )
          ..reachable['pcx:lb7666:app:default'] =
              false; // starts registered-but-dead
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(400, 900); // narrow: single-pane list
    addTearDown(t.view.reset);

    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);
    expect(find.text('不可达'), findsOneWidget); // honest dead status

    // The remote app-server comes back up out from under us...
    api.reachable['pcx:lb7666:app:default'] = true;
    // ...and the periodic re-probe picks it up with NO manual refresh tap.
    await t.pump(const Duration(seconds: 16)); // fire the 15s re-probe timer
    await t.pumpAndSettle(); // let the fresh probe resolve

    expect(find.text('不可达'), findsNothing); // recovered on its own
    expect(find.text('在线'), findsOneWidget); // the app-server reads online
  });

  testWidgets('Manage services agrees with a conversation that lost its link', (
    t,
  ) async {
    // The bug: the services list read `appIsConnected`, a CACHED health flag on
    // the session object, and short-circuited to a green "connected" on it. A
    // link that had actually dropped still satisfied that flag, so this row
    // stayed green while the conversation on top of it showed "reconnecting" —
    // two screens reporting opposite states for one service.
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );
    // Connected as far as the session object is concerned.
    await api.appConnect('pcx:lb7666:app:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1200, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);

    final container = ProviderScope.containerOf(
      t.element(find.byType(ServicesScreen)),
    );
    // Every kind is listed under the device at once, so the app-server
    // capability a conversation runs on is on screen already.
    // Baseline: the stale flag alone reads as connected.
    expect(find.text('已连接'), findsOneWidget); // statusConnected

    // A conversation observes the link go down — what the session screen
    // publishes when it enters reconnect or gives up.
    container.read(observedDisconnectedProvider.notifier).state = {
      'pcx:lb7666:app:default',
    };
    await t.pumpAndSettle();

    // The list now agrees instead of contradicting the transcript.
    expect(find.text('已连接'), findsNothing);
    expect(find.text('不可达'), findsOneWidget); // statusUnreachable
  });

  testWidgets('Manage services keeps theme switching in the page menu', (
    t,
  ) async {
    // Secondary desktop pages keep cross-page + appearance controls in one
    // quiet menu instead of repeating a row of unrelated icon buttons.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      );
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(1200, 900);
      addTearDown(t.view.reset);
      await t.pumpWidget(host(const ServicesScreen(), api));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('theme-toggle-btn')), findsNothing);
      expect(find.byKey(const Key('utility-page-menu')), findsOneWidget);
      await t.tap(find.byKey(const Key('utility-page-menu')));
      await t.pumpAndSettle();
      expect(find.text('页面'), findsOneWidget);
      expect(find.text('暗黑'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('ApiService rejects an out-of-range port before subscribing', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await t.pumpWidget(
      host(
        const Scaffold(
          body: ApiServicePanel(serviceKey: 'pcx:lb7666:api:default'),
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    // 70000 parses as an int but exceeds u16; must be rejected client-side.
    await t.enterText(find.byType(TextField), '70000');
    await t.tap(find.byKey(const Key('subscribe-btn')));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('api-error')), findsOneWidget);
    // Still on the subscribe form (no base-url shown) — nothing was subscribed.
    expect(find.byKey(const Key('base-url')), findsNothing);
  });

  testWidgets('App-server tile is tappable (not disabled)', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);
    // carries an onTap (a disabled row would have a null callback). The card's
    // own InkWell is the first descendant (the deregister overflow menu adds its
    // own InkWell deeper in the tree).
    final ink = t
        .widgetList<InkWell>(
          find.descendant(
            of: find.byKey(
              const Key('device-capability-pcx:lb7666:app:default'),
            ),
            matching: find.byType(InkWell),
          ),
        )
        .first;
    expect(ink.onTap, isNotNull);
  });

  testWidgets('Services renders English strings under Locale(en)', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'default',
          key: 'pcx:lb7666:api:default',
        ),
      ],
    );
    await t.pumpWidget(
      host(const ServicesScreen(), api, locale: const Locale('en')),
    );
    await t.pumpAndSettle();
    // English ARB values, proving the locale switch changes strings. The relay
    // banner's status pill reads "Online" (en) rather than "在线" (zh).
    expect(find.text('Online'), findsWidgets);
    expect(find.text('在线'), findsNothing);
  });

  testWidgets('Services list shows availability + subscription status', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'default',
          key: 'pcx:lb7666:api:default',
        ),
        ServiceEntry(
          device: 'lb7666',
          kind: 'api',
          name: 'other',
          key: 'pcx:lb7666:api:other',
        ),
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );
    // One API service is subscribed (alive) → it reads "subscribed"; the rest
    // are merely registered → "online".
    await api.apiSubscribe('pcx:lb7666:api:default', 28080);
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(500, 900); // narrow → single list pane
    addTearDown(t.view.reset);

    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);

    expect(find.text('已订阅'), findsOneWidget); // subscribedAlive (zh)
    expect(find.text('在线'), findsWidgets); // relay + unsubscribed api + app
    expect(find.byType(StatusDot), findsWidgets); // availability dots render
    expect(find.byType(PulsingDot), findsNothing); // nothing running
  });

  testWidgets('Services refresh button re-runs discovery', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(500, 900);
    addTearDown(t.view.reset);

    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await openDevice(t);
    expect(find.textContaining('App-server'), findsOneWidget);

    // Tapping refresh re-discovers (skeleton flashes, then data) without error.
    await t.tap(find.byKey(const Key('refresh-btn')));
    await t.pumpAndSettle();
    expect(find.textContaining('App-server'), findsOneWidget);
  });

  testWidgets('Services screen shows a loading skeleton before data', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'lb7666',
          kind: 'app',
          name: 'default',
          key: 'pcx:lb7666:app:default',
        ),
      ],
    );

    await t.pumpWidget(host(const ServicesScreen(), api));
    // First frame: discovery future hasn't resolved → skeleton.
    expect(find.byType(ListLoadingSkeleton), findsOneWidget);
    await t.pumpAndSettle();
    // Data arrived → skeleton gone, the capability is listed.
    expect(find.byType(ListLoadingSkeleton), findsNothing);
    await openDevice(t);
    expect(find.textContaining('App-server'), findsOneWidget);
  });
}
