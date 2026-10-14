part of '../acp_hosting_test.dart';

void _registerLifecycle() {
  _lifetimeTests();
  _restartLifetimeTests();
}

bool _isStop(_Op op) => op == _Op.codexStop || op == _Op.acpStop;

/// One operation held at its bridge call: the dialog is open on a live
/// scope that also restores other hosts, and [release] lets the call finish.
class _Held {
  _Held(this.api, this.prefs, this.container, this.gate);

  final FakeBridgeApi api;
  final _HeldPrefs prefs;
  final ProviderContainer container;
  final Completer<void> gate;
  String? stoppedKey;
}

const _otherCodex = AutoHostPrefs(
  port: 18990,
  name: 'other-codex',
  embedded: false,
);

const _otherAcp = AutoHostAcpPrefs(name: 'other-acp', spec: _fixtureSpec);

Future<_Held> _hold(WidgetTester t, _Op op) async {
  final api = FakeBridgeApi();
  if (op == _Op.codexStop) {
    await api.appServeStart(port: 18080, name: 'alpha', embedded: false);
  } else if (op == _Op.acpStop) {
    await api.appServeStartAcp(name: 'beta', spec: _fixtureSpec);
  }
  final prefs = _HeldPrefs(
    UiPrefs(
      autoHostCodex: [
        _otherCodex,
        if (op == _Op.codexStop)
          const AutoHostPrefs(port: 18080, name: 'alpha', embedded: false),
      ],
      autoHostAcp: [
        _otherAcp,
        if (op == _Op.acpStop)
          const AutoHostAcpPrefs(name: 'beta', spec: _fixtureSpec),
      ],
    ),
  );
  final existing = _isStop(op)
      ? api.serveHosts.singleWhere((h) => h.name == _opName(op))
      : null;
  final container = await _pumpDialog(t, api, existing: existing, prefs: prefs);
  await container.read(uiPrefsProvider.future);
  // Keep discovery and the host list observed, so an invalidation refetches.
  container.listen(servicesProvider, (_, _) {});
  container.listen(localServeListProvider, (_, _) {});
  await t.pumpAndSettle();
  final gate = Completer<void>();
  final held = _Held(api, prefs, container, gate)
    ..stoppedKey = existing?.appServiceKey;
  switch (op) {
    case _Op.codexStart:
      api.serveStartGate = gate;
      await _start(t);
    case _Op.acpStart:
      await _chooseAcp(t);
      api.serveStartAcpGate = gate;
      await _start(t);
    case _Op.codexStop || _Op.acpStop:
      api.serveStopGate = gate;
      await t.tap(find.byKey(const Key('stop-hosting-btn')));
      await t.pumpAndSettle();
  }
  expect(find.byType(LocalHostDialog), findsOneWidget);
  return held;
}

/// The completed bookkeeping in a live scope: this host's record restored
/// or forgotten by name, every other record kept, the host list and
/// discovery refreshed (and, for a stop, its entry hidden at once).
Future<void> _expectRecorded(_Held held, _Op op, int discoveriesBefore) async {
  final c = held.container;
  final name = _opName(op);
  final prefs = c.read(uiPrefsProvider).requireValue;
  final codex = prefs.autoHostCodex.map((h) => h.name).toSet();
  final acp = prefs.autoHostAcp.map((h) => h.name).toSet();
  switch (op) {
    case _Op.codexStart:
      expect(codex, {'other-codex', name});
      expect(acp, {'other-acp'});
    case _Op.acpStart:
      expect(codex, {'other-codex'});
      expect(acp, {'other-acp', name});
    case _Op.codexStop:
      expect(codex, {'other-codex'});
      expect(acp, {'other-acp'});
    case _Op.acpStop:
      expect(codex, {'other-codex'});
      expect(acp, {'other-acp'});
  }
  expect(held.prefs.written, isNotEmpty, reason: 'the change was saved');
  final hosts = (await c.read(
    localServeListProvider.future,
  )).map((h) => h.name).toSet();
  expect(hosts.contains(name), !_isStop(op), reason: 'host list refreshed');
  expect(
    held.api.discoverCalls,
    greaterThan(discoveriesBefore),
    reason: 'discovery refetched',
  );
  if (_isStop(op)) {
    expect(c.read(pendingRemovalProvider), contains(held.stoppedKey));
  }
}

void _lifetimeTests() {
  group('LocalHostDialog operation lifetime', () {
    for (final op in _Op.values) {
      testWidgets('${op.name}: Escape and system back are refused while '
          'pending; completion records it', (t) async {
        final held = await _hold(t, op);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        expect(find.byType(LocalHostDialog), findsOneWidget, reason: 'Escape');
        await t.binding.handlePopRoute();
        await t.pumpAndSettle();
        expect(find.byType(LocalHostDialog), findsOneWidget, reason: 'back');

        final discoveries = held.api.discoverCalls;
        held.gate.complete();
        await t.pumpAndSettle();
        expect(find.byType(LocalHostDialog), findsNothing);
        await _expectRecorded(held, op, discoveries);
        await t.pumpWidget(const SizedBox());
      });

      testWidgets('${op.name}: a route removed while pending still records '
          'it in the live scope', (t) async {
        final held = await _hold(t, op);
        // Removal by the app (not a user dismissal) bypasses PopScope.
        Navigator.of(t.element(find.byType(LocalHostDialog))).pop();
        await t.pumpAndSettle();
        expect(find.byType(LocalHostDialog), findsNothing);

        final discoveries = held.api.discoverCalls;
        held.gate.complete();
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await _expectRecorded(held, op, discoveries);
        await t.pumpWidget(const SizedBox());
      });

      testWidgets('${op.name}: a scope disposed while pending is never '
          'touched again', (t) async {
        final held = await _hold(t, op);
        // Descendants unmount before their container is disposed.
        await t.pumpWidget(const SizedBox());
        held.container.dispose();
        final writes = held.prefs.written.length;
        final discoveries = held.api.discoverCalls;

        held.gate.complete();
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        expect(held.prefs.written.length, writes, reason: 'nothing saved');
        expect(held.api.discoverCalls, discoveries, reason: 'nothing read');
      });
    }
  });
}

/// The ACP details dialog with a restart held at its bridge call.
Future<(FakeBridgeApi, ProviderContainer, Completer<void>)> _holdRestart(
  WidgetTester t,
) async {
  final api = FakeBridgeApi();
  await api.appServeStartAcp(name: 'beta', spec: _fixtureSpec);
  final host = api.serveHosts.single;
  final container = await _pumpDialog(t, api, existing: host);
  container.listen(localServeListProvider, (_, _) {});
  await t.pumpAndSettle();
  final gate = Completer<void>();
  api.acpRestartGate = gate;
  await t.ensureVisible(find.byKey(const Key('acp-restart')));
  await t.tap(find.byKey(const Key('acp-restart')));
  await t.pump();
  expect(api.acpRestartCalls, ['beta']);
  return (api, container, gate);
}

void _restartLifetimeTests() {
  group('AcpHostDetails restart lifetime', () {
    testWidgets('a route closed while a restart is pending still refreshes '
        'the host list', (t) async {
      final (api, _, gate) = await _holdRestart(t);
      Navigator.of(t.element(find.byType(LocalHostDialog))).pop();
      await t.pumpAndSettle();
      expect(find.byType(LocalHostDialog), findsNothing);
      final reads = api.serveStatusCalls;

      gate.complete();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(api.serveStatusCalls, greaterThan(reads), reason: 'refetched');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a scope disposed while a restart is pending is never '
        'touched again', (t) async {
      final (api, container, gate) = await _holdRestart(t);
      await t.pumpWidget(const SizedBox());
      container.dispose();
      final reads = api.serveStatusCalls;

      gate.complete();
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(api.serveStatusCalls, reads, reason: 'nothing read');
    });

    testWidgets('a refused restart is shown on the open view', (t) async {
      final (api, _, gate) = await _holdRestart(t);
      api.acpRestartError = StateError('agent would not restart');
      gate.complete();
      await t.pumpAndSettle();
      expect(find.textContaining('agent would not restart'), findsOneWidget);
      expect(find.byType(LocalHostDialog), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });
}
