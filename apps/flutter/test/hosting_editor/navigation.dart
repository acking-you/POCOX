part of '../hosting_editor_test.dart';

void _navigationTests() {
  testWidgets('back with unsaved edits asks before discarding them', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    await _pumpEditor(t, api, existing: _codexHost);
    await _tapKey(t, 'host-source-custom');
    await _enter(t, 'host-base-url', 'https://models.example/v1');

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
    await _tapKey(t, 'host-leave-stay');
    expect(find.byType(HostingEditor), findsOneWidget);
    expect(find.text('https://models.example/v1'), findsOneWidget);

    // The page's own Close button asks the same way.
    await _tapKey(t, 'host-editor-close');
    expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
    await _tapKey(t, 'host-leave-discard');
    expect(find.byType(HostingEditor), findsNothing);
    expect(api.hostConfigSaves, isEmpty);
  });

  testWidgets('an unedited page closes without asking', (t) async {
    final api = FakeBridgeApi();
    api.serveHosts.add(_codexHost);
    await _pumpEditor(t, api, existing: _codexHost);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-leave-dialog')), findsNothing);
    expect(find.byType(HostingEditor), findsNothing);
  });
}

void _entryTests() {
  testWidgets('the page menu, origin and parent of the real router ask '
      'before leaving edits, then navigate', (t) async {
    t.view.physicalSize = const Size(1440, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final api = FakeBridgeApi();
      await t.pumpWidget(
        routerHost(
          api,
          initial: '/manage',
          routes: [
            stub('/', 'conversation-page'),
            GoRoute(path: '/manage', builder: (_, _) => const ServicesScreen()),
            stub('/settings', 'settings-page'),
          ],
        ),
      );
      await t.pumpAndSettle();

      Future<void> openEdited() async {
        await _tapKey(t, 'host-this-device-btn');
        expect(find.byType(HostingEditor), findsOneWidget);
        await _tapKey(t, 'host-source-custom');
        await _enter(t, 'host-base-url', 'https://models.example/v1');
      }

      Future<void> menuTo(String label) async {
        await _tapKey(t, 'utility-page-menu');
        await t.tap(find.text(label).last);
        await t.pumpAndSettle();
      }

      await openEdited();
      final l10n = _l10n(t);
      // The menu marks Manage (the parent) as current and asks first.
      await menuTo(l10n.settingsTitle);
      expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
      // Keyboard: Escape means stay.
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.byType(HostingEditor), findsOneWidget);
      expect(find.text('https://models.example/v1'), findsOneWidget);

      // Discarding replaces the page with the sibling, editor and all.
      await menuTo(l10n.settingsTitle);
      await _tapKey(t, 'host-leave-discard');
      expect(find.byType(HostingEditor), findsNothing);
      expect(find.text('settings-page'), findsOneWidget);

      // The parent breadcrumb leads back to Manage, after asking.
      GoRouter.of(t.element(find.text('settings-page'))).go('/manage');
      await t.pumpAndSettle();
      await openEdited();
      await _tapKey(t, 'utility-parent-origin');
      expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
      await _tapKey(t, 'host-leave-discard');
      expect(find.byType(HostingEditor), findsNothing);
      expect(find.byType(ServicesScreen), findsOneWidget);

      // The conversation origin asks too, then goes home.
      await openEdited();
      await _tapKey(t, 'utility-chat-origin');
      expect(find.byKey(const Key('host-leave-dialog')), findsOneWidget);
      await _tapKey(t, 'host-leave-discard');
      expect(find.byType(HostingEditor), findsNothing);
      expect(find.text('conversation-page'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('shared navigation waits for the page to agree', (t) async {
    final answer = <Completer<bool>>[];
    var navigated = 0;
    late BuildContext inside;
    await t.pumpWidget(
      MaterialApp(
        home: UtilityLeaveGuard(
          confirm: () {
            final c = Completer<bool>();
            answer.add(c);
            return c.future;
          },
          child: Builder(
            builder: (context) {
              inside = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    UtilityLeaveGuard.leave(inside, () => navigated++);
    await t.pump();
    expect(navigated, 0, reason: 'asked, not answered');
    answer.single.complete(false);
    await t.pump();
    expect(navigated, 0, reason: 'the page said stay');

    UtilityLeaveGuard.leave(inside, () => navigated++);
    answer.last.complete(true);
    await t.pump();
    expect(navigated, 1);

    // Without a guard, navigation is immediate (existing pages unchanged).
    late BuildContext bare;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            bare = context;
            return const SizedBox();
          },
        ),
      ),
    );
    UtilityLeaveGuard.leave(bare, () => navigated++);
    expect(navigated, 2);
  });
}
