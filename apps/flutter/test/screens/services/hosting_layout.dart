part of '../services_test.dart';

void _registerHostingLayout() {
  testWidgets('self-host desktop can host too, from the card and the title '
      'bar', (t) async {
    // Self-host: a relay and key, no account. Publishing works the same, so
    // hosting must not hide behind an account sign-in.
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'peer',
          kind: 'app',
          name: 'default',
          key: 'pcx:peer:app:default',
        ),
      ],
    );
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    // A remote peer is listed and nothing is hosted: the title bar is the
    // way in.
    expect(find.byKey(const Key('host-this-device-btn')), findsOneWidget);
    await t.tap(find.byKey(const Key('host-this-device-btn')));
    await t.pumpAndSettle();
    // The agent grid offers Codex and native OpenCode, each by mark.
    expect(find.byKey(const Key('agent-choice-codex')), findsOneWidget);
    expect(find.byKey(const Key('agent-choice-opencode')), findsOneWidget);
    expect(find.byKey(const Key('agent-icon-codex')), findsWidgets);
    expect(find.byKey(const Key('agent-icon-opencode')), findsOneWidget);
    await t.tap(find.byKey(const Key('start-hosting-btn')));
    await t.pumpAndSettle();
    expect(api.serveHosts, hasLength(1));
  }, variant: desktop);

  testWidgets('the hosting action stays reachable in a narrow or '
      'text-scaled title bar', (t) async {
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
    );
    const text = 'Host this device';
    final action = find.byKey(const Key('host-this-device-btn'));
    final labelled = find.descendant(of: action, matching: find.text(text));
    final back = find.byKey(const Key('utility-chat-origin'));
    Future<void> show(
      Size size,
      double scale, {
      Brightness brightness = Brightness.light,
      Locale locale = const Locale('en'),
    }) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = scale;
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        host(
          const ServicesScreen(),
          api,
          locale: locale,
          // The app's own themes: their title-bar and icon-button colours
          // are what the icon form is drawn with.
          theme: brightness == Brightness.light ? lightTheme() : darkTheme(),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: 'no overflow: $size ×$scale');
      // Every bar control stays on the bar and receives taps.
      for (final control in [
        back,
        find.byKey(const Key('refresh-btn')),
        action,
        find.byKey(const Key('utility-page-menu')),
      ]) {
        expect(control.hitTestable(), findsOneWidget, reason: '$control');
        final rect = t.getRect(control);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
      }
    }

    final grid = find.byKey(const Key('agent-choice-grid'));
    Future<void> opensDialog() async {
      await t.pumpAndSettle();
      expect(grid, findsOneWidget);
      Navigator.of(t.element(grid)).pop();
      await t.pumpAndSettle();
    }

    // The icon form is announced as an enabled, focusable button named
    // by its tooltip, and assistive technology can activate it.
    Future<void> expectAccessibleAction() async {
      final handle = t.ensureSemantics();
      try {
        final node = t.getSemantics(action);
        expect(
          node,
          isSemantics(
            tooltip: text,
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
          ),
        );
        // A real target, not a zero-size node; its on-screen placement
        // is checked by show().
        expect(node.rect.isEmpty, isFalse);
        node.owner!.performAction(node.id, SemanticsAction.tap);
        await opensDialog();
      } finally {
        handle.dispose();
      }
    }

    // The icon form's plus is drawn in a colour that stands out from its
    // filled disc (WCAG's 3:1 for graphics), in light and dark.
    void expectVisibleGlyph(String why) {
      final glyph = t.widget<RichText>(
        find.descendant(of: action, matching: find.byType(RichText)),
      );
      expect(glyph.text.toPlainText(), isNotEmpty, reason: why);
      final ink = glyph.text.style!.color!;
      final disc = t
          .widget<Material>(
            find.descendant(of: action, matching: find.byType(Material)).first,
          )
          .color!;
      final (hi, lo) = (
        math.max(ink.computeLuminance(), disc.computeLuminance()),
        math.min(ink.computeLuminance(), disc.computeLuminance()),
      );
      expect(
        (hi + 0.05) / (lo + 0.05),
        greaterThanOrEqualTo(3),
        reason: '$why: plus $ink on disc $disc',
      );
      expect(ink.a, greaterThan(0.5), reason: '$why: opaque plus');
      expect(disc.a, greaterThan(0.5), reason: '$why: filled disc');
    }

    // Tab to the action, then Enter.
    Future<void> activateByKeyboard() async {
      final target = t.element(action);
      bool focused() {
        final node = FocusManager.instance.primaryFocus?.context;
        if (node == null) return false;
        var inside = identical(node, target);
        node.visitAncestorElements((e) {
          if (identical(e, target)) inside = true;
          return !inside;
        });
        return inside;
      }

      for (var i = 0; i < 30 && !focused(); i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
      }
      expect(focused(), isTrue, reason: 'reachable by Tab');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await opensDialog();
    }

    await show(const Size(1440, 900), 1);
    expect(labelled, findsOneWidget, reason: 'room for the label');
    await activateByKeyboard();

    // A phone-width bar: the same action, named by tooltip and semantics.
    await show(const Size(320, 640), 1);
    expect(labelled, findsNothing);
    expect(find.byTooltip(text), findsOneWidget);
    expectVisibleGlyph('320 light');
    await expectAccessibleAction();
    await t.tap(action);
    await opensDialog();
    await activateByKeyboard();

    // Large text on a bar too narrow for the scaled label.
    await show(const Size(800, 900), 3);
    expect(labelled, findsNothing);
    expect(find.byTooltip(text), findsOneWidget);
    expectVisibleGlyph('800 ×3 light');
    await expectAccessibleAction();
    await activateByKeyboard();

    // Chinese: the short label is narrow enough for the 3× bar, but a
    // line of 3× text is taller than the bar's button, so the icon form
    // is chosen rather than a label cut off at the bottom.
    const zhText = '托管本机';
    final zhLabelled = find.descendant(of: action, matching: find.text(zhText));
    await show(const Size(1440, 900), 1, locale: const Locale('zh'));
    expect(zhLabelled, findsOneWidget, reason: 'regular text: labelled');
    await show(const Size(800, 900), 3, locale: const Locale('zh'));
    expect(zhLabelled, findsNothing, reason: 'the label would be cut');
    expect(find.byTooltip(zhText), findsOneWidget);
    expectVisibleGlyph('800 ×3 zh');
    await t.tap(action);
    await opensDialog();
    await activateByKeyboard();

    // The same in the dark theme.
    await show(const Size(1440, 900), 1, brightness: Brightness.dark);
    expect(labelled, findsOneWidget, reason: 'room for the label (dark)');
    for (final (size, scale) in [
      (const Size(320, 640), 1.0),
      (const Size(800, 900), 3.0),
    ]) {
      await show(size, scale, brightness: Brightness.dark);
      expect(labelled, findsNothing);
      expectVisibleGlyph('${size.width.toInt()} ×$scale dark');
      await t.tap(action);
      await opensDialog();
    }
  }, variant: desktop);

  testWidgets('large text keeps the identity, status and capability title '
      'whole', (t) async {
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'peer',
          kind: 'app',
          name: 'default',
          key: 'pcx:peer:app:default',
        ),
      ],
    );
    const relay = 'relay.example:7666';
    const online = 'Online';
    const title = 'Available capabilities';
    final identity = find.byKey(const Key('identity-open-settings'));
    final narrowList = find.byKey(const ValueKey('svc-narrow-devices'));
    Rect rectOf(Finder f) => t.getRect(f);
    bool within(Rect inner, Rect outer) =>
        inner.left >= outer.left - 0.5 &&
        inner.top >= outer.top - 0.5 &&
        inner.right <= outer.right + 0.5 &&
        inner.bottom <= outer.bottom + 0.5;
    Finder inIdentity(String text) =>
        find.descendant(of: identity, matching: find.text(text));

    Future<void> show(Size size, double scale, Brightness brightness) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = scale;
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(
        host(
          const ServicesScreen(),
          api,
          locale: const Locale('en'),
          theme: brightness == Brightness.light ? lightTheme() : darkTheme(),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: 'no overflow: $size ×$scale');
    }

    // The identity text and the whole status lie inside the row, which
    // stays on screen and opens settings when tapped.
    void identityWhole(Size size) {
      expect(identity.hitTestable(), findsOneWidget);
      final row = rectOf(identity);
      expect(within(row, Offset.zero & size), isTrue, reason: 'row $row');
      for (final text in [relay, online]) {
        expect(inIdentity(text), findsOneWidget, reason: text);
        expect(within(rectOf(inIdentity(text)), row), isTrue, reason: text);
      }
      final status = t.renderObject<RenderParagraph>(inIdentity(online));
      expect(status.didExceedMaxLines, isFalse);
    }

    // The capabilities title inside its group.
    void countWhole(Size size) {
      final card = find
          .ancestor(of: find.text(title), matching: find.byType(GroupCard))
          .first;
      final rect = rectOf(find.text(title));
      expect(within(rect, rectOf(card)), isTrue, reason: title);
      expect(within(rect, Offset.zero & size), isTrue, reason: title);
      final text = t.renderObject<RenderParagraph>(find.text(title));
      expect(text.didExceedMaxLines, isFalse, reason: title);
    }

    for (final brightness in Brightness.values) {
      // Regular text on a desktop: the column beside the detail, the
      // status beside the identity.
      await show(const Size(1440, 900), 1, brightness);
      expect(narrowList, findsNothing, reason: 'side by side');
      identityWhole(const Size(1440, 900));
      expect(
        (rectOf(inIdentity(online)).center.dy -
                rectOf(inIdentity(relay)).center.dy)
            .abs(),
        lessThan(4),
        reason: 'status on the identity line',
      );
      countWhole(const Size(1440, 900));

      // 3× text on a tablet: one level at a time, everything whole.
      await show(const Size(800, 900), 3, brightness);
      expect(narrowList, findsOneWidget, reason: 'one level at a time');
      identityWhole(const Size(800, 900));
      await t.tap(find.byKey(const Key('device-peer')));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      countWhole(const Size(800, 900));
      await t.tap(find.byKey(const Key('device-back')));
      await t.pumpAndSettle();
      expect(narrowList, findsOneWidget);

      // 2× text on a phone: the status moves under the identity.
      await show(const Size(320, 640), 2, brightness);
      identityWhole(const Size(320, 640));
      expect(
        rectOf(inIdentity(online)).top,
        greaterThanOrEqualTo(rectOf(inIdentity(relay)).bottom - 0.5),
        reason: 'status under the identity',
      );
    }
  }, variant: desktop);

  testWidgets('with a remote device selected, an existing local host still '
      'leaves hosting one tap away', (t) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
      services: const [
        ServiceEntry(
          device: 'peer',
          kind: 'app',
          name: 'default',
          key: 'pcx:peer:app:default',
        ),
      ],
    );
    await api.appServeStart(port: 18080, name: 'default', embedded: false);
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('device-peer')));
    await t.pumpAndSettle();
    // The local hosting card belongs to this machine and is not shown
    // under the peer, but the title bar still offers hosting.
    expect(find.byKey(const Key('add-local-host-card')), findsNothing);
    expect(find.byKey(const Key('host-this-device-btn')), findsOneWidget);
    await t.tap(find.byKey(const Key('host-this-device-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('start-hosting-btn')));
    await t.pumpAndSettle();
    expect(api.serveHosts.map((h) => h.name), ['default', 'default-2']);
  }, variant: desktop);

  testWidgets('hosting stays reachable while discovery fails or loads', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
    )..discoverError = StateError('relay unreachable');
    await t.pumpWidget(host(const ServicesScreen(), api));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-this-device-btn')), findsOneWidget);
    // And during the initial load, held pending on purpose.
    await t.pumpWidget(const SizedBox());
    api.discoverError = null;
    final discovery = Completer<void>();
    api.discoverGate = discovery;
    final callsBefore = api.discoverCalls;
    await t.pumpWidget(host(const ServicesScreen(), api));
    // The skeleton animates while loading: bounded frames only.
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(api.discoverCalls, greaterThan(callsBefore));
    expect(discovery.isCompleted, isFalse);
    expect(find.byType(ListLoadingSkeleton), findsOneWidget);
    expect(find.byKey(const Key('host-this-device-btn')), findsOneWidget);
    // The action works mid-load.
    await t.tap(find.byKey(const Key('host-this-device-btn')));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const Key('start-hosting-btn')), findsOneWidget);
    discovery.complete();
    api.discoverGate = null;
    await t.pumpAndSettle();
    // Data arrived: the skeleton gives way to the page.
    expect(find.byType(ListLoadingSkeleton), findsNothing);
  }, variant: desktop);

  testWidgets('a phone offers no hosting: no title-bar action, no add card', (
    t,
  ) async {
    // The harness reports android. On a desktop this account shows both: the
    // title-bar action always, the add card under the auto-selected device.
    await t.pumpWidget(host(const ServicesScreen(), accountFake()));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-this-device-btn')), findsNothing);
    expect(find.byKey(const Key('add-local-host-card')), findsNothing);
  });
}
