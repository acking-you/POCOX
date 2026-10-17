part of '../home_screen_test.dart';

/// The host switcher, its refresh and switch feedback, and the sidebar
/// footer on desktop and phone.
void _registerHostSwitching() {
  testWidgets('Refresh services in the host switcher lists a host started '
      'elsewhere, in place, keeping the draft', (t) async {
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1]);
    await _pumpHome(t, api);
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('composer-input')), 'draft');
    await t.tap(find.byKey(const Key('sidebar-service-switcher')));
    await t.pumpAndSettle();
    expect(find.byKey(Key('host-switch-item-${_app2.key}')), findsNothing);
    // Another device starts a host meanwhile.
    api.services.add(_app2);
    final calls = api.discoverCalls;
    await t.tap(find.byKey(const Key('host-switch-refresh')).last);
    await t.pumpAndSettle();
    expect(api.discoverCalls, greaterThan(calls));
    expect(find.byKey(Key('host-switch-item-${_app2.key}')), findsWidgets);
    expect(find.byKey(const Key('host-switch-refresh-error')), findsNothing);
    expect(
      t
          .widget<TextField>(find.byKey(const Key('composer-input')))
          .controller!
          .text,
      'draft',
    );
  });

  testWidgets('Switching to an unreachable host keeps the current chat', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1, _app2]);
    api.reachable[_app2.key] = false;
    await _pumpHome(t, api);
    await t.pumpAndSettle();
    expect(api.appIsConnected(_app1.key), isTrue);

    await t.tap(find.byKey(const Key('sidebar-service-switcher')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('host-switch-item-${_app2.key}')).last);
    await t.pumpAndSettle();

    // Probe failed → a failure strip that names the host, says why and that
    // the chat stayed; no teardown: the chat stays on the first host.
    final banner = find.byKey(const Key('host-switch-banner'));
    expect(banner, findsOneWidget);
    expect(
      find.descendant(
        of: banner,
        matching: find.textContaining('laptop · beta'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: banner,
        matching: find.textContaining('devbox · alpha'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('send-btn')), findsOneWidget);
    expect(api.appIsConnected(_app2.key), isFalse);
    expect(api.appIsConnected(_app1.key), isTrue);

    // Dismissing the notice keeps the chat where it is.
    await t.tap(find.byKey(const Key('host-switch-dismiss')));
    await t.pumpAndSettle();
    expect(banner, findsNothing);
    expect(api.appIsConnected(_app1.key), isTrue);

    // Retry once the host is back: the same switch fails again, then succeeds.
    await t.tap(find.byKey(const Key('sidebar-service-switcher')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('host-switch-item-${_app2.key}')).last);
    await t.pumpAndSettle();
    expect(banner, findsOneWidget);
    api.reachable[_app2.key] = true;
    await t.tap(find.byKey(const Key('host-switch-retry')));
    await t.pumpAndSettle();
    expect(banner, findsNothing);
    expect(api.appIsConnected(_app2.key), isTrue);
  });

  testWidgets('A switch in flight shows its target and step, then confirms', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1, _app2]);
    await _pumpHome(t, api);
    await t.pumpAndSettle();
    final gate = Completer<void>();
    api.appConnectGate = gate.future;

    await t.tap(find.byKey(const Key('sidebar-service-switcher')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('host-switch-item-${_app2.key}')).last);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    // Held at "connecting": the strip and the switcher row both say so, and
    // the old conversation is still there underneath.
    final banner = find.byKey(const Key('host-switch-banner'));
    expect(banner, findsOneWidget);
    expect(
      find.descendant(
        of: banner,
        matching: find.text(_zh.hostSwitchConnecting),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('host-switch-progress')), findsOneWidget);
    expect(find.byKey(const Key('send-btn')), findsOneWidget);
    // A second pick while busy is ignored: the switcher row is inert.
    await t.tap(find.byKey(const Key('sidebar-service-switcher')));
    await t.pump();
    expect(find.byKey(Key('host-switch-item-${_app1.key}')), findsNothing);

    gate.complete();
    await t.pumpAndSettle();
    expect(banner, findsNothing);
    expect(find.byKey(const Key('host-switch-progress')), findsNothing);
    expect(api.appIsConnected(_app2.key), isTrue);
    expect(find.text(_zh.hostSwitched('laptop · beta')), findsOneWidget);
  });

  testWidgets('An explicit default host outranks the last-used host', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1, _app2]);
    await _pumpHome(
      t,
      api,
      seed: (container) {
        final prefs = container.read(uiPrefsProvider.notifier);
        prefs.setLastService(_app1.key);
        prefs.setPreferredAppService(_app2.key);
      },
    );
    await t.pumpAndSettle();

    expect(api.appIsConnected(_app2.key), isTrue);
    expect(api.appIsConnected(_app1.key), isFalse);
  });

  testWidgets('A single host still opens the switcher, which leads to host '
      'management', (t) async {
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1]);
    await _pumpHome(t, api, extraRoutes: [_stub('/manage', 'manage')]);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('sidebar-service-switcher')));
    await t.pumpAndSettle();
    expect(find.byKey(Key('host-switch-item-${_app1.key}')), findsWidgets);
    expect(find.byKey(Key('host-agent-icon-${_app1.key}')), findsWidgets);
    await t.tap(find.byKey(const Key('host-switch-manage')).last);
    await t.pumpAndSettle();
    expect(find.textContaining('stub:manage'), findsOneWidget);
  });

  testWidgets('Sidebar switcher moves the chat to another host', (t) async {
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1, _app2]);
    final container = await _pumpHome(t, api);
    await t.pumpAndSettle();
    expect(api.appIsConnected(_app1.key), isTrue);

    await t.tap(find.byKey(const Key('sidebar-service-switcher')));
    await t.pumpAndSettle();
    // The current host is checked in the list.
    expect(
      find.descendant(
        of: find.byKey(Key('host-switch-item-${_app1.key}')).last,
        matching: find.byIcon(AppIcons.check),
      ),
      findsOneWidget,
    );
    await t.tap(find.byKey(Key('host-switch-item-${_app2.key}')).last);
    await t.pumpAndSettle();

    expect(api.appIsConnected(_app2.key), isTrue);
    expect(find.byKey(const Key('send-btn')), findsOneWidget);
    expect(
      container.read(uiPrefsProvider).valueOrNull?.lastServiceKey,
      _app2.key,
    );
  });

  testWidgets(
    "Sidebar footer reaches host management and this host's history",
    (t) async {
      final api = FakeBridgeApi(config: _accountConfig, services: [_app1]);
      await _pumpHome(
        t,
        api,
        extraRoutes: [
          _stub('/manage', 'manage'),
          _stub('/sessions', 'sessions'),
        ],
      );
      await t.pumpAndSettle();

      await t.tap(find.byKey(const Key('sidebar-manage-btn')));
      await t.pumpAndSettle();
      expect(find.textContaining('stub:manage'), findsOneWidget);
      // pageBack() looks for the English 'Back' tooltip; tap the button itself
      // (the app runs under the zh locale here).
      await t.tap(find.byType(BackButton));
      await t.pumpAndSettle();

      // The host-history shortcut carries the service key so the browser reads
      // THIS host's sessions over its meta tunnel.
      await t.tap(find.byKey(const Key('sidebar-history-btn')));
      await t.pumpAndSettle();
      expect(
        find.textContaining('svc=pcx%3Adevbox%3Aapp%3Aalpha'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Home sidebar on a phone: no back tile, footer shortcuts shown', (
    t,
  ) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1]);
    await _pumpHome(t, api);
    await t.pumpAndSettle();

    // Narrow layout: sessions lie under the chat, behind the hamburger.
    expect(find.byKey(const Key('sidebar-manage-btn')), findsNothing);
    await t.tap(find.byIcon(AppIcons.menu));
    await t.pumpAndSettle();
    final sidebar = t.widget<Material>(find.byKey(const Key('phone-sidebar')));
    expect(sidebar.color, isNotNull);
    expect(sidebar.color!.a, 1.0);
    expect(find.byKey(const Key('drawer-back-to-sessions')), findsNothing);
    expect(find.byKey(const Key('sidebar-manage-btn')), findsOneWidget);
    expect(find.byKey(const Key('sidebar-settings-btn')), findsOneWidget);
  });

  testWidgets('On a phone the host list is a sheet, and the drawer gets out '
      'of the way of the switch', (t) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1, _app2]);
    await _pumpHome(t, api);
    await t.pumpAndSettle();
    final gate = Completer<void>();
    api.appConnectGate = gate.future;

    await t.tap(find.byIcon(AppIcons.menu));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('sidebar-service-switcher')));
    await t.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    // Touch rows are full-height targets.
    final row = t.getSize(find.byKey(Key('host-switch-item-${_app2.key}')));
    expect(row.height, greaterThanOrEqualTo(44));
    await t.tap(find.byKey(Key('host-switch-item-${_app2.key}')));
    // The spinner never settles while the switch is held, so step the sheet
    // and drawer exit animations by hand.
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 60));
    }

    // Sheet and drawer are gone, so the progress strip is visible.
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byKey(const Key('sidebar-manage-btn')), findsNothing);
    expect(find.byKey(const Key('host-switch-banner')), findsOneWidget);
    gate.complete();
    await t.pumpAndSettle();
    expect(api.appIsConnected(_app2.key), isTrue);
    expect(find.byKey(const Key('host-switch-banner')), findsNothing);
  });
}
