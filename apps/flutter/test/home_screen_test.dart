import 'dart:async';

// Chat-first home: service resolution, latest-conversation restore, fallback
// heroes, auto-retry, service switching, and the sidebar's home-mode extras.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/dismissed_services.dart';
import 'package:pocket_codex/src/hosting/host_editor_page.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/managed/managed_providers.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/screens/home_screen.dart';
import 'package:pocket_codex/src/ui_prefs.dart';

import 'fake_bridge_api.dart';

const _app1 = ServiceEntry(
  device: 'devbox',
  kind: 'app',
  name: 'alpha',
  key: 'pcx:devbox:app:alpha',
);
const _app2 = ServiceEntry(
  device: 'laptop',
  kind: 'app',
  name: 'beta',
  key: 'pcx:laptop:app:beta',
);
const _accountConfig = ConfigInfo(
  relay: null,
  hasKey: false,
  mode: 'account',
  accountLogin: 'octocat',
);

/// In-memory prefs: the store's real load/save seam, so a test never reads
/// or writes the app-support file. [saved] is the "file"; [gate] holds the
/// initial load open.
class _MemoryPrefs extends UiPrefsStore {
  _MemoryPrefs([this.saved = const UiPrefs(), this.gate]);

  final UiPrefs saved;
  final Completer<void>? gate;

  /// How many waits on the authoritative snapshot were started.
  int readyReads = 0;

  @override
  Future<UiPrefs> get ready {
    readyReads++;
    return super.ready;
  }

  @override
  Future<UiPrefs> load() async {
    await gate?.future;
    return saved;
  }

  @override
  Future<void> save(UiPrefs prefs) async {}
}

/// In-memory dismissed services (none), so a test never depends on how the
/// app-support lookup fails without a platform.
class _MemoryDismissed extends DismissedServices {
  @override
  Future<Set<String>> build() async => <String>{};
}

/// Owns the test's container and router: both are disposed when this leaves
/// the tree, after every descendant has been deactivated and disposed. A
/// failed test (whose tree the framework leaves mounted) is unmounted in this
/// order too, so its screens never read a disposed container.
class _Owned extends StatefulWidget {
  const _Owned({
    required this.container,
    required this.router,
    required this.child,
  });

  final ProviderContainer container;
  final GoRouter router;
  final Widget child;

  @override
  State<_Owned> createState() => _OwnedState();
}

class _OwnedState extends State<_Owned> {
  @override
  void dispose() {
    widget.router.dispose();
    widget.container.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: widget.container,
    child: widget.child,
  );
}

/// Mount [HomeScreen] under a MaterialApp (zh locale, matching the app
/// default) inside an [UncontrolledProviderScope] so tests can seed prefs on
/// the container before the first frame.
Future<ProviderContainer> _pumpHome(
  WidgetTester t,
  FakeBridgeApi api, {
  void Function(ProviderContainer c)? seed,
  List<GoRoute> extraRoutes = const [],
  _MemoryPrefs? prefs,
  bool memoryDismissed = false,
}) async {
  final store = prefs ?? _MemoryPrefs();
  final container = ProviderContainer(
    overrides: [
      bridgeApiProvider.overrideWithValue(api),
      uiPrefsProvider.overrideWith(() => store),
      if (memoryDismissed)
        dismissedServicesProvider.overrideWith(_MemoryDismissed.new),
    ],
  );
  seed?.call(container);
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (c, s) => const HomeScreen()),
      ...extraRoutes,
    ],
  );
  await t.pumpWidget(
    _Owned(
      container: container,
      router: router,
      child: MaterialApp.router(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  return container;
}

GoRoute _stub(String path, String label) => GoRoute(
  path: path,
  builder: (c, s) => Scaffold(
    // AppBar so `tester.pageBack()` has a back button to press.
    appBar: AppBar(title: Text(label)),
    body: Text('stub:$label ${s.uri.query}'),
  ),
);

/// The saved file of the lifecycle tests: a Codex host to restore and the
/// conversation last open on `_app1` (named as the last service, so it
/// outranks the restored local host).
const _savedRestore = UiPrefs(
  lastServiceKey: 'pcx:devbox:app:alpha',
  lastThreadByService: {'pcx:devbox:app:alpha': 't-old'},
  autoHostCodex: [AutoHostPrefs(port: 0, name: 'work')],
);

FakeBridgeApi _lifecycleApi() =>
    FakeBridgeApi(config: _accountConfig, services: [_app1])
      ..appThreads.addAll(const [
        ThreadMeta(id: 't-old', preview: 'old', cwd: '', updatedAt: 1000),
        ThreadMeta(id: 't-new', preview: 'new', cwd: '', updatedAt: 2000),
      ]);

/// With the initial load held, step a fresh home into its second bounded
/// prefs wait: the cached-session peek times out (2 s), then the resolve
/// reaches the next `_prefs()` — the hosting restore on desktop, the ranking
/// on a phone. Returns the home's State.
Future<State> _enterSecondPrefsWait(WidgetTester t, _MemoryPrefs prefs) async {
  final home = t.state(find.byType(HomeScreen));
  await t.pump();
  await t.pump();
  expect(prefs.readyReads, 1, reason: 'the cached-session wait started');
  await t.pump(const Duration(milliseconds: 2100));
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
  expect(prefs.readyReads, 2, reason: 'the second prefs wait started');
  expect(prefs.gate!.isCompleted, isFalse);
  return home;
}

/// Navigate away and step the route transition (at most 1 s of fake time)
/// until the home is gone and its State disposed.
Future<void> _leaveHome(WidgetTester t, State home) async {
  GoRouter.of(t.element(find.byType(HomeScreen))).go('/away');
  for (var i = 0; i < 20; i++) {
    if (find.byType(HomeScreen).evaluate().isEmpty) break;
    await t.pump(const Duration(milliseconds: 50));
  }
  expect(find.byType(HomeScreen), findsNothing);
  expect(home.mounted, isFalse, reason: 'the old home was disposed');
}

/// The bridge calls a resolving home makes once its prefs arrive, counted
/// from the moment it was left.
class _Effects {
  _Effects(this.api)
    : discover = api.discoverCalls,
      acpSupported = api.acpHostingSupportedCalls;

  final FakeBridgeApi api;
  final int discover;
  final int acpSupported;

  void expectNone() {
    expect(api.serveStatusCalls, 0, reason: 'no local-host query');
    expect(
      api.acpHostingSupportedCalls,
      acpSupported,
      reason: 'no restore planning',
    );
    expect(api.serveHosts, isEmpty, reason: 'no Codex hosting start');
    expect(api.acpServeCalls, isEmpty, reason: 'no ACP hosting start');
    expect(api.discoverCalls, discover, reason: 'no re-discovery');
    expect(api.capabilityCalls, isEmpty, reason: 'no capability read');
    expect(api.appProbeCalls, isEmpty, reason: 'no probe');
    expect(api.lastResumed, isNull, reason: 'no resume');
  }
}

void main() {
  setUp(() {
    AppSessionScreen.debugResetThreadMemory();
    HomeScreen.debugResetAutoHost();
  });

  testWidgets('Home opens straight into the most recent conversation', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1]);
    api.appThreads.addAll(const [
      ThreadMeta(
        id: 't-old',
        preview: 'old topic',
        cwd: r'D:\proj\alpha',
        updatedAt: 1000,
      ),
      ThreadMeta(
        id: 't-new',
        preview: 'newest topic',
        cwd: r'D:\proj\beta',
        updatedAt: 2000,
      ),
    ]);
    await _pumpHome(t, api);
    await t.pumpAndSettle();

    // Connected + resumed the newest thread; the chat composer is on screen.
    expect(api.appIsConnected(_app1.key), isTrue);
    expect(api.lastResumed, 't-new');
    expect(find.byKey(const Key('send-btn')), findsOneWidget);
    // The sidebar (inline at 800px) lists sessions from BOTH projects, each
    // annotated with its project name. 'beta' can only come from the second
    // project's row annotation (the single-service switcher label reads
    // 'devbox · alpha'), so this pins the per-row project tag specifically.
    expect(find.text('old topic'), findsOneWidget);
    // Twice: the sidebar row and the content top bar, which titles the
    // (resumed) conversation with its preview.
    expect(find.text('newest topic'), findsNWidgets(2));
    expect(find.textContaining('beta'), findsWidgets);
  });

  testWidgets('Home waits for the prefs file before choosing a conversation', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1]);
    api.appThreads.addAll(const [
      ThreadMeta(id: 't-old', preview: 'old', cwd: '', updatedAt: 1000),
      ThreadMeta(id: 't-new', preview: 'new', cwd: '', updatedAt: 2000),
    ]);
    final gate = Completer<void>();
    final prefs = _MemoryPrefs(
      const UiPrefs(lastThreadByService: {'pcx:devbox:app:alpha': 't-old'}),
      gate,
    );
    // An operation issued during the load makes an interim snapshot that
    // knows nothing of the file's last conversation.
    await _pumpHome(
      t,
      api,
      prefs: prefs,
      seed: (c) => c.read(uiPrefsProvider.notifier).setLastService(_app1.key),
    );
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(gate.isCompleted, isFalse);
    expect(api.lastResumed, isNull);

    gate.complete();
    await t.pumpAndSettle();
    expect(api.lastResumed, 't-old');
  });

  // Lifecycle of a home whose prefs wait outlives it. Each test holds the
  // initial load, steps the home into its second bounded wait, removes the
  // home, then lets the wait end. The held load completes with the real saved
  // restore record, so an unguarded continuation would query, plan and start
  // `work`; timing out to defaults would not, which is why the completion
  // cases are the ones that tell the guard apart.

  testWidgets('A home left while its hosting restore waits for prefs does '
      'nothing once the file arrives; the next home restores it once', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final api = _lifecycleApi();
      final prefs = _MemoryPrefs(_savedRestore, Completer<void>());
      await _pumpHome(
        t,
        api,
        prefs: prefs,
        memoryDismissed: true,
        extraRoutes: [_stub('/away', 'away')],
      );
      final home = await _enterSecondPrefsWait(t, prefs);
      expect(api.serveStatusCalls, 0, reason: 'the restore is still waiting');
      final effects = _Effects(api);
      await _leaveHome(t, home);

      // The restore's wait began after 2 s and has spent at most 1.35 s, so
      // the file arrives inside its 2 s bound, as real saved prefs.
      prefs.gate!.complete();
      await t.pump();
      await t.pump();
      expect(prefs.readyReads, 2, reason: 'the old resolve went no further');
      effects.expectNone();
      // Past the old bound too: nothing was left to fire.
      await t.pump(const Duration(seconds: 3));
      await t.pump();
      expect(t.takeException(), isNull);
      effects.expectNone();

      // The next home owns the outcome; the once-per-run flag was not burnt.
      GoRouter.of(t.element(find.text('stub:away '))).go('/');
      await t.pumpAndSettle();
      expect(api.serveHosts.map((h) => h.name), ['work']);
      expect(api.lastResumed, 't-old');
      expect(t.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('A phone home left while ranking waits for prefs does nothing '
      'once the file arrives; the next home opens the saved conversation', (
    t,
  ) async {
    final api = _lifecycleApi();
    final prefs = _MemoryPrefs(_savedRestore, Completer<void>());
    await _pumpHome(
      t,
      api,
      prefs: prefs,
      memoryDismissed: true,
      extraRoutes: [_stub('/away', 'away')],
    );
    // No hosting restore on a phone: the second wait is the ranking's.
    final home = await _enterSecondPrefsWait(t, prefs);
    expect(api.serveStatusCalls, 0, reason: 'the ranking is still waiting');
    final effects = _Effects(api);
    await _leaveHome(t, home);

    prefs.gate!.complete();
    await t.pump();
    await t.pump();
    expect(prefs.readyReads, 2);
    effects.expectNone();
    await t.pump(const Duration(seconds: 3));
    await t.pump();
    expect(t.takeException(), isNull);
    effects.expectNone();

    GoRouter.of(t.element(find.text('stub:away '))).go('/');
    await t.pumpAndSettle();
    expect(api.lastResumed, 't-old');
    expect(api.serveHosts, isEmpty, reason: 'phones never host');
    expect(t.takeException(), isNull);
  });

  for (final completes in [false, true]) {
    final ending = completes ? 'the file arrives' : 'the wait times out';
    testWidgets('A container torn down while the restore waits for prefs '
        'has no late effects when $ending; a fresh one restores once', (
      t,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final api = _lifecycleApi();
        final prefs = _MemoryPrefs(_savedRestore, Completer<void>());
        await _pumpHome(t, api, prefs: prefs, memoryDismissed: true);
        final home = await _enterSecondPrefsWait(t, prefs);
        final effects = _Effects(api);
        // Unmounting the owner disposes the home first, then its router and
        // container (see [_Owned]).
        await t.pumpWidget(const SizedBox());
        expect(home.mounted, isFalse);
        expect(find.byType(HomeScreen), findsNothing);

        if (completes) {
          // A store disposed during its load still resolves `ready`, with
          // the file it read.
          prefs.gate!.complete();
          await t.pump();
          await t.pump();
          effects.expectNone();
        }
        // Otherwise the bounded wait times out here, after the ref is gone.
        await t.pump(const Duration(seconds: 3));
        await t.pump();
        expect(t.takeException(), isNull);
        expect(prefs.readyReads, 2, reason: 'the old resolve went no further');
        effects.expectNone();

        await _pumpHome(
          t,
          api,
          prefs: _MemoryPrefs(_savedRestore),
          memoryDismissed: true,
        );
        await t.pumpAndSettle();
        expect(api.serveHosts.map((h) => h.name), ['work']);
        expect(api.lastResumed, 't-old');
        expect(t.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('An unreadable restore authority restores nothing (no '
      'fallback to old preferences) and reports why', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = _lifecycleApi()
        ..restoreOverridesError = Exception('restore records unreadable');
      final container = await _pumpHome(
        t,
        api,
        prefs: _MemoryPrefs(_savedRestore),
        memoryDismissed: true,
      );
      await t.pumpAndSettle();
      expect(api.restoreServiceCalls, isEmpty);
      expect(api.serveHosts, isEmpty);
      expect(
        container.read(hostRestoreBlockedProvider),
        contains('restore records unreadable'),
      );
      await t.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Home restores the conversation the user last had open', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1]);
    api.appThreads.addAll(const [
      ThreadMeta(id: 't-old', preview: 'old', cwd: '', updatedAt: 1000),
      ThreadMeta(id: 't-new', preview: 'new', cwd: '', updatedAt: 2000),
    ]);
    await _pumpHome(
      t,
      api,
      seed: (c) =>
          c.read(uiPrefsProvider.notifier).setLastThread(_app1.key, 't-old'),
    );
    await t.pumpAndSettle();
    expect(api.lastResumed, 't-old');
  });

  testWidgets('Idle desktop hero offers one-tap hosting (account mode)', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final api = FakeBridgeApi(config: _accountConfig);
      await _pumpHome(t, api);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('home-hero-title')), findsOneWidget);
      expect(find.byKey(const Key('home-start-hosting-btn')), findsOneWidget);
      expect(find.byKey(const Key('home-retry-btn')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Idle desktop hero offers hosting in self-host mode too', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
      );
      await _pumpHome(t, api);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('home-start-hosting-btn')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the hero opens the hosting editor, which returns home', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = FakeBridgeApi(config: _accountConfig);
      await _pumpHome(t, api);
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('home-start-hosting-btn')));
      await t.pumpAndSettle();
      expect(find.byType(HostingEditor), findsOneWidget);
      // Unedited: its own Close leaves without asking.
      await t.tap(find.byKey(const Key('host-editor-close')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('host-leave-dialog')), findsNothing);
      expect(find.byType(HostingEditor), findsNothing);
      expect(find.byKey(const Key('home-hero-title')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Cold start restores every saved Codex host', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final api = FakeBridgeApi(config: _accountConfig);
      await _pumpHome(
        t,
        api,
        seed: (c) {
          c.read(uiPrefsProvider.notifier)
            ..setAutoHost(const AutoHostPrefs(port: 18080, name: 'default'))
            ..setAutoHost(const AutoHostPrefs(port: 0, name: 'work'));
        },
      );
      await t.pumpAndSettle();
      expect(api.serveHosts.map((h) => h.name), ['default', 'work']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Idle phone hero points at the desktop, no hosting button', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _accountConfig);
    await _pumpHome(t, api);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('home-hero-title')), findsOneWidget);
    expect(find.byKey(const Key('home-start-hosting-btn')), findsNothing);
    expect(
      find.text('在电脑上打开 PocketCodex 并开启托管（app-server），这里就会自动进入对话。'),
      findsOneWidget,
    );
  });

  testWidgets('Home enters the chat by itself once a host appears', (t) async {
    final api = FakeBridgeApi(config: _accountConfig);
    await _pumpHome(t, api);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('home-hero-title')), findsOneWidget);

    // The desktop host comes online; the periodic re-check finds it. The
    // background re-resolve doesn't animate the hero, so advance fake time
    // explicitly past the bounded prefs/dismissed waits before settling.
    api.services.add(_app1);
    await t.pump(const Duration(seconds: 16));
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('send-btn')), findsOneWidget);
    expect(api.appIsConnected(_app1.key), isTrue);
  });

  testWidgets('Cold start restores hosting even when a remote host exists', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      // A reachable REMOTE host is discoverable, but this machine held a
      // hosting record — both must come up: hosting restored AND the chat
      // opens (preferring the local host in the ranking).
      final api = FakeBridgeApi(config: _accountConfig, services: [_app2]);
      await _pumpHome(
        t,
        api,
        seed: (c) => c
            .read(uiPrefsProvider.notifier)
            .setAutoHost(const AutoHostPrefs(port: 18080, name: 'default')),
      );
      await t.pumpAndSettle();

      expect(api.lastServePort, 18080);
      expect(find.byKey(const Key('send-btn')), findsOneWidget);
      expect(api.appIsConnected('pcx:local:app:default'), isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

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

    // Retry once the host is back: the same switch, now succeeding.
    api.reachable[_app2.key] = true;
    await t.tap(find.byKey(const Key('host-switch-retry')));
    await t.pumpAndSettle();
    expect(banner, findsNothing);
    expect(api.appIsConnected(_app2.key), isTrue);
  });

  testWidgets('A failed switch notice can be dismissed', (t) async {
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1, _app2]);
    api.reachable[_app2.key] = false;
    await _pumpHome(t, api);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('sidebar-service-switcher')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(Key('host-switch-item-${_app2.key}')).last);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-switch-banner')), findsOneWidget);
    await t.tap(find.byKey(const Key('host-switch-dismiss')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('host-switch-banner')), findsNothing);
    expect(api.appIsConnected(_app1.key), isTrue);
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
      find.descendant(of: banner, matching: find.text('正在建立连接…')),
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
    expect(find.text('已切换到 laptop · beta'), findsOneWidget);
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
        matching: find.byIcon(Icons.check),
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
    'Sidebar footer reaches manage / host history / logs / settings',
    (t) async {
      final api = FakeBridgeApi(config: _accountConfig, services: [_app1]);
      await _pumpHome(
        t,
        api,
        extraRoutes: [
          _stub('/manage', 'manage'),
          _stub('/sessions', 'sessions'),
          _stub('/logs', 'logs'),
          _stub('/settings', 'settings'),
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

  testWidgets(
    'Desktop cold start migrates built-in hosting to external Codex',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final api = FakeBridgeApi(config: _accountConfig);
        await _pumpHome(
          t,
          api,
          seed: (c) => c
              .read(uiPrefsProvider.notifier)
              .setAutoHost(
                const AutoHostPrefs(
                  port: 18080,
                  name: 'default',
                  proxy: 'http://127.0.0.1:11111',
                  embedded: true,
                ),
              ),
        );
        await t.pumpAndSettle();

        // Hosting was re-run with the persisted params and the chat opened on
        // the freshly published local service.
        expect(api.lastServePort, 18080);
        expect(api.lastServeEmbedded, isFalse);
        expect(api.lastServeProxy, 'http://127.0.0.1:11111');
        expect(find.byKey(const Key('send-btn')), findsOneWidget);
        expect(api.appIsConnected('pcx:local:app:default'), isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
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
    await t.tap(find.byIcon(Icons.menu));
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

    await t.tap(find.byIcon(Icons.menu));
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

  testWidgets('Discovery failure shows the retry hero, then recovers', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _accountConfig, services: [_app1]);
    api.discoverError = StateError('relay down');
    await _pumpHome(t, api);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('home-hero-title')), findsOneWidget);

    api.discoverError = null;
    await t.tap(find.byKey(const Key('home-retry-btn')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('send-btn')), findsOneWidget);
  });

  testWidgets('Expired account session returns directly to sign-in', (t) async {
    final api = FakeBridgeApi(config: _accountConfig)
      ..discoverError = StateError('session expired; sign in again');
    await _pumpHome(t, api, extraRoutes: [_stub('/onboarding', 'login')]);
    await t.pumpAndSettle();

    expect(
      find.textContaining('stub:login reason=session-expired'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('home-hero-title')), findsNothing);
  });

  testWidgets('Rejected services token also returns directly to sign-in', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _accountConfig)
      ..discoverError = StateError('/v1/services failed: 401 Unauthorized');
    await _pumpHome(t, api, extraRoutes: [_stub('/onboarding', 'login')]);
    await t.pumpAndSettle();

    expect(
      find.textContaining('stub:login reason=session-expired'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('home-retry-btn')), findsNothing);
  });
}
