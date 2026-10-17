part of '../services_test.dart';

void _registerDeregistration() {
  testWidgets('注销: cancel keeps the service, confirm removes it', (t) async {
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
          kind: 'api',
          name: 'default',
          key: 'pcx:lb7666:api:default',
        ),
      ],
    );
    await showServices(t, api);
    // The list card (the wide layout ALSO shows the name in the detail pane,
    // so presence is asserted on the card key, absence on the text).
    expect(
      find.byKey(const Key('device-capability-pcx:lb7666:api:default')),
      findsOneWidget,
    );

    // Open the card overflow menu → 注销 → cancel: nothing happens.
    await t.tap(
      find.byKey(const Key('capability-menu-pcx:lb7666:api:default')),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('注销'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('deregister-dialog')), findsOneWidget);
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(api.lastDeregistered, isNull);
    expect(
      find.byKey(const Key('device-capability-pcx:lb7666:api:default')),
      findsOneWidget,
    );

    // Re-open → confirm: the service is deregistered + leaves the list.
    await t.tap(
      find.byKey(const Key('capability-menu-pcx:lb7666:api:default')),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('注销'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('deregister-confirm-btn')));
    await t.pumpAndSettle();
    expect(api.lastDeregistered, 'pcx:lb7666:api:default');
    expect(find.text('API'), findsNothing);
  });

  testWidgets('注销 on an unreachable remote entry dismisses it: hidden while '
      'the relay still lists it, back once it is reachable again', (t) async {
    final api =
        FakeBridgeApi(
            config: const ConfigInfo(
              relay: '',
              hasKey: false,
              mode: 'account',
              accountLogin: 'acking-you',
            ),
            services: const [
              ServiceEntry(
                device: 'otherdev',
                kind: 'api',
                name: 'orphan',
                key: 'pcx:otherdev:api:orphan',
              ),
            ],
          )
          // Unreachable => the honest "remove" path; and the backend can't drop it
          // (the key lingers on the relay even after the DELETE).
          ..reachable['pcx:otherdev:api:orphan'] = false
          ..keepOnDeregister = true;
    const card = Key('device-capability-pcx:otherdev:api:orphan');
    await showServices(t, api);
    expect(find.byKey(card), findsOneWidget);

    // Overflow → 注销 → the honest "remove unreachable" dialog → confirm.
    await t.tap(
      find.byKey(const Key('capability-menu-pcx:otherdev:api:orphan')),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('注销'));
    await t.pumpAndSettle();
    expect(find.text('移除该不可达服务？'), findsOneWidget);
    await t.tap(find.byKey(const Key('deregister-confirm-btn')));
    await t.pumpAndSettle();

    // Best-effort backend drop still attempted; and even though discovery STILL
    // lists the key, the durable dismiss keeps it hidden, across a refresh too.
    expect(api.lastDeregistered, 'pcx:otherdev:api:orphan');
    expect(find.byKey(card), findsNothing);
    await t.tap(find.byKey(const Key('refresh-btn')));
    await t.pumpAndSettle();
    expect(find.byKey(card), findsNothing);

    // The backend recovers behind the still-registered key. A re-probe lifts the
    // durable dismissal — reachability, not discovery-absence, is the un-hide
    // signal, so a recovered-in-place service is never stranded.
    api.reachable['pcx:otherdev:api:orphan'] = true;
    await t.tap(find.byKey(const Key('refresh-btn')));
    await t.pumpAndSettle();
    expect(find.byKey(card), findsOneWidget);
  });
}
