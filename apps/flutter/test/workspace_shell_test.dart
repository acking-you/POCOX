// The workspace shell: one list of destinations, the Pocket, the phone drawer,
// the context card and sheet, Settings' two renderers and background processes,
// on real fonts at every size that used to break. Set POCOX_UI_PREVIEW_DIR to
// write each screen as a PNG.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/screens/app_session_screen.dart';
import 'package:pocox/src/screens/log_view_screen.dart';
import 'package:pocox/src/screens/settings_screen.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/ui_prefs.dart';
import 'package:pocox/src/widgets/layered_navigation.dart';
import 'package:pocox/src/widgets/workspace_navigation.dart';

import 'fake_bridge_api.dart';
import 'support/ui_preview.dart';

const _mac = 'pcx:my-mac:app:default';
const _box = 'pcx:dev-box:app:default';
const _acp = 'pcx:my-mac:acp:claude';
const _nas = 'pcx:nas:app:default';

const _account = ConfigInfo(
  relay: 'relay.example.com:7666',
  hasKey: true,
  mode: 'account',
  accountLogin: 'fixture-user',
);

int _ago(Duration d) =>
    DateTime.now().subtract(d).millisecondsSinceEpoch ~/ 1000;

ThreadMeta _thread(String id, String name, String cwd, Duration ago) =>
    ThreadMeta(
      id: id,
      preview: name,
      name: name,
      cwd: '/work/$cwd',
      updatedAt: _ago(ago),
    );

FakeBridgeApi _api({ConfigInfo config = _account}) {
  final api = FakeBridgeApi(
    config: config,
    services: const [
      ServiceEntry(device: 'my-mac', kind: 'app', name: 'default', key: _mac),
      ServiceEntry(device: 'dev-box', kind: 'app', name: 'default', key: _box),
      ServiceEntry(device: 'my-mac', kind: 'acp', name: 'claude', key: _acp),
      ServiceEntry(device: 'nas', kind: 'app', name: 'default', key: _nas),
    ],
  );
  api.appThreads.addAll([
    _thread(
      't1',
      'Group the settings page',
      'pocket-codex',
      const Duration(minutes: 1),
    ),
    _thread(
      't2',
      'Upgrade the relay SDK',
      'infra-notes',
      const Duration(minutes: 3),
    ),
    _thread(
      't3',
      'Find why the API times out',
      'demo-api',
      const Duration(hours: 5),
    ),
    _thread(
      't4',
      'Design cache invalidation',
      'demo-api',
      const Duration(days: 1),
    ),
  ]);
  api.backgroundTerminals = const [
    BackgroundTerminal(
      itemId: 'i1',
      processId: 'p1',
      command: 'flutter test --plain-name settings',
      cwd: '/work/pocket-codex',
      osPid: 4242,
      cpuPercent: 12.5,
      rssKb: 204800,
    ),
  ];
  api.putSubscription(
    const SubInfo(
      key: _mac,
      localAddr: '127.0.0.1:1',
      alive: true,
      path: TunnelPath.relay,
      ready: true,
    ),
  );
  api.readResult = const ThreadHistory(
    cwd: '/work/pocket-codex',
    branch: 'codex/settings-groups',
    running: false,
    tokensUsed: 84000,
    contextWindow: 200000,
    items: [
      ThreadItem(
        id: 'u1',
        itemType: 'userMessage',
        title: '',
        turnId: 'a',
        text: 'The settings page has no clear sections. Group it by purpose.',
      ),
      ThreadItem(
        id: 'a1',
        itemType: 'agentMessage',
        title: '',
        turnId: 'a',
        text:
            'Phone and desktop each write their own settings tree, so they '
            'disagree. One list of sections fixes both.',
      ),
    ],
  );
  api.rateLimitsJson =
      '{"rateLimits":{"primary":{"usedPercent":22,"windowDurationMins":300}}}';
  return api;
}

Future<void> _frames(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Mount the app's routes on [platform] at [size], with a chat at `/`.
Future<GoRouter> _mount(
  WidgetTester t, {
  required Size size,
  required TargetPlatform platform,
  required FakeBridgeApi api,
  bool dark = false,
  double scale = 1,
  Locale locale = const Locale('en'),
  EdgeInsets safe = EdgeInsets.zero,
  String initial = '/',
  UiPrefs prefs = const UiPrefs(lastServiceKey: _mac),
}) async {
  debugDefaultTargetPlatformOverride = platform;
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  t.view.padding = t.view.viewPadding = FakeViewPadding(
    top: safe.top,
    bottom: safe.bottom,
  );
  addTearDown(t.view.reset);
  await api.appConnect(_mac, 1);
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/',
        builder: (c, s) => AppPageShortcuts(
          currentRoute: '/',
          child: AppSessionScreen(
            serviceKey: _mac,
            threadId: 't1',
            home: true,
            services: api.services,
          ),
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (c, s) => const SettingsScreen(),
        routes: [
          GoRoute(
            path: ':section',
            builder: (c, s) => SettingsScreen(
              section: SettingsSection.parse(s.pathParameters['section']),
            ),
          ),
        ],
      ),
      GoRoute(path: '/logs', builder: (c, s) => const LogViewScreen()),
      for (final path in ['/manage', '/galaxy', '/sessions'])
        GoRoute(
          path: path,
          builder: (c, s) => Scaffold(body: Text('page:$path ${s.uri.query}')),
        ),
    ],
  );
  addTearDown(router.dispose);
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        bridgeApiProvider.overrideWithValue(api),
        uiPrefsProvider.overrideWith(() => _Prefs(prefs)),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        locale: locale,
        theme: dark ? darkTheme() : lightTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: previewKey, child: child!),
        ),
        routerConfig: router,
      ),
    ),
  );
  await _frames(t);
  return router;
}

/// Prefs held in memory, nothing read from or written to disk.
class _Prefs extends UiPrefsStore {
  _Prefs(this.initial);

  final UiPrefs initial;

  @override
  Future<UiPrefs> load() async => initial;

  @override
  Future<void> save(UiPrefs prefs) async {}
}

void _reset() => debugDefaultTargetPlatformOverride = null;

const _phone = Size(390, 844);
const _wide = Size(1440, 900);

void main() {
  setUpAll(() => loadPreviewFonts(always: true));
  setUp(AppSessionScreen.debugResetThreadMemory);

  group('destinations', () {
    testWidgets('history carries the current service on a phone', (t) async {
      await _mount(t, size: _phone, platform: TargetPlatform.iOS, api: _api());
      await t.tap(find.byKey(const Key('sidebar-open-btn')));
      await _frames(t);
      await t.tap(find.byKey(const Key('drawer-account-row')));
      await _frames(t);
      await t.tap(find.byKey(const Key('pocket-tile-/sessions')));
      await _frames(t);
      expect(
        find.textContaining('svc=pcx%3Amy-mac%3Aapp%3Adefault'),
        findsOneWidget,
      );
      _reset();
    });

    testWidgets('a phone with no host history offers no dead page', (t) async {
      await _mount(
        t,
        size: _phone,
        platform: TargetPlatform.iOS,
        // Self-hosted: session history rides an account's meta tunnel.
        api: _api(
          config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
        ),
      );
      await t.tap(find.byKey(const Key('sidebar-open-btn')));
      await _frames(t);
      await t.tap(find.byKey(const Key('drawer-account-row')));
      await _frames(t);
      expect(find.byKey(const Key('pocket-tile-/sessions')), findsNothing);
      expect(find.byKey(const Key('pocket-tile-/logs')), findsOneWidget);
      expect(find.byKey(const Key('pocket-tile-/settings')), findsOneWidget);
      _reset();
    });

    testWidgets('a computer reads its own service\'s history from disk', (
      t,
    ) async {
      final api = _api()
        ..serveHosts.add(
          const AppServeStatus(
            name: 'default',
            device: 'my-mac',
            alive: true,
            appServiceKey: _mac,
            appRegistered: true,
          ),
        );
      await _mount(t, size: _wide, platform: TargetPlatform.macOS, api: api);
      await t.tap(find.byKey(const Key('workspace-nav-/sessions')));
      await _frames(t);
      expect(find.text('page:/sessions '), findsOneWidget);
      _reset();
    });

    testWidgets('the rail leads everywhere and the shortcuts still work', (
      t,
    ) async {
      final router = await _mount(
        t,
        size: _wide,
        platform: TargetPlatform.macOS,
        api: _api(),
      );
      for (final section in [
        '/',
        '/manage',
        '/galaxy',
        '/sessions',
        '/logs',
        '/settings',
      ]) {
        expect(find.byKey(Key('workspace-nav-$section')), findsOneWidget);
      }
      await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.comma);
      await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await _frames(t);
      expect(find.byType(SettingsScreen), findsOneWidget);
      router.go('/');
      await _frames(t);
      _reset();
    });
  });

  group('phone', () {
    testWidgets('while reconnecting the title opens the link sheet, so Retry '
        'now stays reachable', (t) async {
      final api = _api();
      await _mount(t, size: _phone, platform: TargetPlatform.iOS, api: api);
      api
        ..appConnectError = StateError('relay down')
        ..connectStages[_mac] = ConnectStage.tunnel;
      await api.appDisconnect(_mac);
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('link-status-line')), findsOneWidget);
      await t.tap(find.byKey(const Key('session-context-btn')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('link-sheet')), findsOneWidget);
      expect(find.byKey(const Key('context-sheet')), findsNothing);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
      _reset();
    });

    testWidgets('the title opens the context, whose actions hold rename', (
      t,
    ) async {
      final api = _api();
      await _mount(
        t,
        size: _phone,
        platform: TargetPlatform.iOS,
        api: api,
        safe: const EdgeInsets.only(top: 47, bottom: 26),
      );
      expect(find.byKey(const Key('session-state-line')), findsOneWidget);
      await capturePreview(t, 'workspace-phone-chat');
      await t.tap(find.byKey(const Key('session-context-btn')));
      await _frames(t);
      expect(find.byKey(const Key('context-sheet')), findsOneWidget);
      for (final key in [
        'session-rename',
        'session-show-in-galaxy',
        'context-changes',
        'context-terminals',
        'context-connection',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      }
      await capturePreview(t, 'workspace-phone-context');
      // Rename, new on a phone, edits the title where it stands.
      await t.tap(find.byKey(const Key('session-rename')));
      await _frames(t);
      expect(find.byKey(const Key('bar-title-field')), findsOneWidget);
      _reset();
    });

    testWidgets('a process opens its details and can be stopped', (t) async {
      final api = _api();
      await _mount(t, size: _phone, platform: TargetPlatform.iOS, api: api);
      await t.tap(find.byKey(const Key('session-context-btn')));
      await _frames(t);
      await t.tap(find.byKey(const Key('context-terminals')));
      await _frames(t);
      await t.tap(find.byKey(const Key('context-terminal-p1')));
      await _frames(t);
      expect(find.text('4242'), findsOneWidget);
      await t.tap(find.byKey(const Key('background-process-terminate')));
      await _frames(t);
      await t.tap(find.widgetWithText(FilledButton, 'Terminate'));
      await _frames(t);
      expect(api.terminatedProcesses, ['p1']);
      _reset();
    });

    testWidgets('a fork from the sheet says it is under way on the top bar, '
        'lands in the fork, and the sheet leads back to its source', (t) async {
      final api = _api();
      final gate = Completer<void>();
      api.forkGate = gate;
      await _mount(t, size: _phone, platform: TargetPlatform.iOS, api: api);
      await t.tap(find.byKey(const Key('session-context-btn')));
      await _frames(t);
      await t.tap(find.byKey(const Key('session-fork')));
      await _frames(t);
      await t.tap(find.byKey(const Key('fork-confirm')));
      await _frames(t);
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(
        find.descendant(
          of: find.byKey(const Key('session-state-line')),
          matching: find.text(l10n.forkPending),
        ),
        findsOneWidget,
      );
      gate.complete();
      await _frames(t);
      final fork = api.forkedThreads.single;
      expect(api.lastResumed, fork.id);
      expect(find.byKey(const Key('strip-fork-mark')), findsOneWidget);
      await t.tap(find.byKey(const Key('session-context-btn')));
      await _frames(t);
      final source = find.byKey(const Key('context-fork-source'));
      expect(
        t.getTopLeft(source).dy,
        lessThan(t.getTopLeft(find.byKey(const Key('context-changes'))).dy),
      );
      await t.tap(source);
      await _frames(t);
      expect(api.lastResumed, 't1');
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
      _reset();
    });

    testWidgets('a host that cannot list processes hides the row', (t) async {
      final api = _api()..backgroundTerminalsError = StateError('old host');
      await _mount(t, size: _phone, platform: TargetPlatform.iOS, api: api);
      await t.tap(find.byKey(const Key('session-context-btn')));
      await _frames(t);
      expect(find.byKey(const Key('context-terminals')), findsNothing);
      _reset();
    });

    testWidgets('the drawer leaves the conversation in view, closes on a tap '
        'there, and reaches the Pocket', (t) async {
      await _mount(t, size: _phone, platform: TargetPlatform.iOS, api: _api());
      await t.tap(find.byKey(const Key('sidebar-open-btn')));
      await _frames(t);
      expect(
        t.getSize(find.byKey(const Key('phone-sidebar'))).width,
        _phone.width - LayeredNavigation.peek,
      );
      for (final key in [
        'sidebar-service-switcher',
        'host-capsule-$_box',
        'new-conversation-btn',
        'drawer-account-row',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      }
      // No brand row, close button, shortcuts or locate control.
      expect(find.byKey(const Key('sidebar-close-btn')), findsNothing);
      expect(find.byKey(const Key('locate-conversation-btn')), findsNothing);
      await capturePreview(t, 'workspace-phone-drawer');

      await t.tap(find.byKey(const Key('drawer-account-row')));
      await _frames(t);
      expect(find.byKey(const Key('pocket-sheet')), findsOneWidget);
      await capturePreview(t, 'workspace-phone-pocket');
      await t.tap(find.byKey(const Key('pocket-tile-/settings')));
      await _frames(t);
      expect(find.byType(SettingsScreen), findsOneWidget);
      _reset();
    });

    testWidgets('a tap on the sliver closes the drawer', (t) async {
      await _mount(t, size: _phone, platform: TargetPlatform.iOS, api: _api());
      await t.tap(find.byKey(const Key('sidebar-open-btn')));
      await _frames(t);
      await t.tapAt(Offset(_phone.width - 20, 400));
      await _frames(t);
      expect(find.byKey(const Key('drawer-account-row')), findsNothing);
      _reset();
    });

    testWidgets(
      'the new-conversation icon keeps its place with search hidden',
      (t) async {
        await _mount(
          t,
          size: _phone,
          platform: TargetPlatform.iOS,
          api: _api(),
        );
        await t.tap(find.byKey(const Key('sidebar-open-btn')));
        await _frames(t);
        expect(find.byKey(const Key('conv-search')), findsNothing);
        final compact = t.getSize(
          find.byKey(const Key('new-conversation-btn')),
        );
        expect(compact.width, lessThanOrEqualTo(48));
        expect(compact.height, greaterThanOrEqualTo(44));
        _reset();
      },
    );

    for (final (size, scale, locale) in const [
      (Size(320, 640), 2.0, Locale('zh')),
      (Size(320, 640), 2.0, Locale('en')),
      (Size(360, 780), 1.3, Locale('en')),
    ]) {
      testWidgets('every compact screen fits at $size ×$scale $locale', (
        t,
      ) async {
        // An overflow is a FlutterError, which fails the test by itself.
        final router = await _mount(
          t,
          size: size,
          platform: TargetPlatform.iOS,
          api: _api(),
          scale: scale,
          locale: locale,
        );
        await t.tap(find.byKey(const Key('session-context-btn')));
        await _frames(t);
        await t.tapAt(const Offset(10, 10));
        await _frames(t);
        await t.tap(find.byKey(const Key('sidebar-open-btn')));
        await _frames(t);
        await t.tap(find.byKey(const Key('drawer-account-row')));
        await _frames(t);
        await t.tapAt(const Offset(10, 10));
        await _frames(t);
        await t.tapAt(Offset(size.width - 20, size.height / 2));
        await _frames(t);
        router.push('/settings');
        await _frames(t);
        await t.tap(find.byKey(const Key('pocket-title')));
        await _frames(t);
        await t.tapAt(const Offset(10, 10));
        await _frames(t);
        router.push('/settings/connection');
        await _frames(t);
        _reset();
      });
    }
  });

  group('wide', () {
    testWidgets('the card stands open, remembers its toggle and gives way to '
        'the review', (t) async {
      await _mount(t, size: _wide, platform: TargetPlatform.macOS, api: _api());
      expect(find.byKey(const Key('context-card')), findsOneWidget);
      expect(find.byKey(const Key('context-terminal-p1')), findsOneWidget);
      expect(find.byKey(const Key('context-usage')), findsOneWidget);
      expect(find.byKey(const Key('theme-toggle-btn')), findsNothing);
      await capturePreview(t, 'workspace-desktop-chat');

      final container = ProviderScope.containerOf(
        t.element(find.byKey(const Key('context-card'))),
      );
      await t.tap(find.byKey(const Key('context-card-toggle')));
      await _frames(t);
      expect(find.byKey(const Key('context-card')), findsNothing);
      expect(
        container.read(uiPrefsProvider).valueOrNull?.contextCardOpen,
        isFalse,
      );
      // Its facts are still in reach: the status bar is back.
      expect(find.byKey(const Key('session-link-mark')), findsOneWidget);

      await t.tap(find.byKey(const Key('context-card-toggle')));
      await _frames(t);
      await t.tap(find.byKey(const Key('context-changes')));
      await _frames(t);
      expect(find.byKey(const Key('review-panel')), findsOneWidget);
      expect(find.byKey(const Key('context-card')), findsNothing);
      _reset();
    });

    testWidgets('a device names itself once; its agents sit one tap apart', (
      t,
    ) async {
      final api = _api();
      await _mount(t, size: _phone, platform: TargetPlatform.iOS, api: api);
      await t.tap(find.byKey(const Key('sidebar-open-btn')));
      await _frames(t);
      final capsules = find.byKey(const Key('host-capsules'));
      expect(
        find.descendant(of: capsules, matching: find.text('my-mac')),
        findsOneWidget,
      );
      final agents = find.byKey(const Key('host-agents'));
      expect(
        find.descendant(of: agents, matching: find.text('Codex')),
        findsOneWidget,
      );
      final other = find.byKey(const Key('host-capsule-$_acp'));
      expect(find.descendant(of: agents, matching: other), findsOneWidget);
      expect(t.getSize(other).height, greaterThanOrEqualTo(44));
      await capturePreview(t, 'workspace-phone-agents');
      _reset();
    });

    testWidgets('the Pocket\'s Appearance saves a theme after the Pocket has '
        'gone', (t) async {
      await _mount(t, size: _phone, platform: TargetPlatform.iOS, api: _api());
      await t.tap(find.byKey(const Key('sidebar-open-btn')));
      await _frames(t);
      final page = t.element(find.byKey(const Key('sidebar-open-btn')));
      await t.tap(find.byKey(const Key('drawer-account-row')));
      await _frames(t);
      await t.tap(find.byKey(const Key('pocket-tile-appearance')));
      await _frames(t);
      expect(find.byKey(const Key('pocket-sheet')), findsNothing);
      final l10n = lookupAppLocalizations(const Locale('en'));
      await t.tap(find.text(l10n.appearanceDark).last);
      await _frames(t);
      expect(t.takeException(), isNull);
      expect(
        ProviderScope.containerOf(
          page,
          listen: false,
        ).read(uiPrefsProvider).valueOrNull?.themeMode,
        'dark',
      );
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
      _reset();
    });

    testWidgets('a held conversation keeps its fork in the read-only foot, on '
        'one line at a finger\'s size on a phone', (t) async {
      FakeBridgeApi held() {
        final api = _api()
          ..appThreadResumeError = StateError(
            'thread already has an active writer',
          );
        api.liveness['t1'] = const SessionLiveness(
          threadId: 't1',
          turnState: 'completed',
          heldOpen: true,
          safety: 'ownedIdle',
          allowsResume: true,
          requiresTakeover: true,
          holders: [],
        );
        return api;
      }

      await _mount(t, size: _wide, platform: TargetPlatform.macOS, api: held());
      expect(find.byKey(const Key('chat-fork-action')), findsOneWidget);
      await capturePreview(t, 'workspace-held-desktop');
      await _mount(t, size: _phone, platform: TargetPlatform.iOS, api: held());
      final action = find.byKey(const Key('chat-fork-action'));
      final takeover = find.byKey(const Key('chat-takeover-action'));
      void oneLine() {
        expect(t.takeException(), isNull);
        expect(t.getCenter(action).dy, t.getCenter(takeover).dy);
        expect(t.getSize(action).height, greaterThanOrEqualTo(44));
        expect(t.getSize(action).width, greaterThanOrEqualTo(44));
      }

      oneLine();
      await capturePreview(t, 'workspace-held-phone');
      await _mount(
        t,
        size: _phone,
        platform: TargetPlatform.iOS,
        api: held(),
        dark: true,
      );
      await capturePreview(t, 'workspace-held-phone-dark');
      await _mount(
        t,
        size: const Size(320, 640),
        scale: 2,
        platform: TargetPlatform.iOS,
        api: held(),
      );
      oneLine();
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
      _reset();
    });

    testWidgets('a listed fork is found by asking the host: marked, under its '
        'source, in its card, and leading back', (t) async {
      final api = _api();
      final source = api.appThreads.first.id;
      final fork = api.appThreads.last.id;
      api.threadOrigins[fork] = source;
      await _mount(t, size: _wide, platform: TargetPlatform.macOS, api: api);
      await _frames(t);
      final mark = find.byKey(Key('fork-mark-$fork'));
      expect(mark, findsOneWidget);
      final under = t.getTopLeft(find.byKey(Key('activity-tile-$fork')));
      final above = t.getTopLeft(find.byKey(Key('activity-tile-$source')));
      expect(under.dy, greaterThan(above.dy));
      expect(
        under.dx,
        greaterThan(above.dx),
        reason: 'a fork indents under its source',
      );
      await t.tap(find.byKey(Key('context-fork-$fork')));
      await _frames(t);
      expect(api.lastResumed, fork);
      expect(find.byKey(const Key('strip-fork-mark')), findsOneWidget);
      expect(find.byKey(const Key('history-fork-source')), findsOneWidget);
      await t.tap(find.byKey(const Key('strip-fork-source')));
      await _frames(t);
      expect(api.lastResumed, source);
      expect(find.byKey(const Key('strip-fork-mark')), findsNothing);
      _reset();
    });

    testWidgets(
      'the card says a fork is under way, then leads with its source; '
      'the status line marks it only in the card\'s place',
      (t) async {
        final api = _api();
        final gate = Completer<void>();
        api.forkGate = gate;
        await _mount(t, size: _wide, platform: TargetPlatform.macOS, api: api);
        await t.tap(find.byKey(const Key('conversation-menu')));
        await _frames(t);
        await t.tap(find.byKey(const Key('session-fork')));
        await _frames(t);
        await t.tap(find.byKey(const Key('fork-confirm')));
        await _frames(t);
        expect(find.byKey(const Key('context-fork-pending')), findsOneWidget);
        gate.complete();
        await _frames(t);
        expect(find.byKey(const Key('context-fork-pending')), findsNothing);
        expect(
          t.getTopLeft(find.byKey(const Key('context-fork-source'))).dy,
          lessThan(t.getTopLeft(find.byKey(const Key('context-changes'))).dy),
        );
        expect(find.byKey(const Key('fork-source-mark')), findsNothing);
        await t.tap(find.byKey(const Key('context-card-toggle')));
        await _frames(t);
        expect(find.byKey(const Key('fork-source-mark')), findsOneWidget);
        _reset();
      },
    );

    testWidgets('a window with no room folds the card; its toggle opens a '
        'panel', (t) async {
      await _mount(
        t,
        size: const Size(1000, 800),
        platform: TargetPlatform.macOS,
        api: _api(),
      );
      expect(find.byKey(const Key('context-card')), findsNothing);
      expect(find.byKey(const Key('session-link-mark')), findsOneWidget);
      await t.tap(find.byKey(const Key('context-card-toggle')));
      await _frames(t);
      expect(find.byKey(const Key('context-sheet')), findsOneWidget);
      _reset();
    });

    testWidgets('a reconnect keeps the status bar over the card', (t) async {
      final api = _api();
      await _mount(t, size: _wide, platform: TargetPlatform.macOS, api: api);
      expect(find.byKey(const Key('link-status-line')), findsNothing);
      api
        ..appConnectError = StateError('relay down')
        ..connectStages[_mac] = ConnectStage.tunnel;
      await api.appDisconnect(_mac);
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('link-status-line')), findsOneWidget);
      await t.tap(find.byKey(const Key('link-status-line')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('link-sheet')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
      _reset();
    });

    testWidgets('the first heading regroups the list', (t) async {
      await _mount(t, size: _wide, platform: TargetPlatform.macOS, api: _api());
      expect(find.byKey(const Key('activity-tile-t1')), findsOneWidget);
      await t.tap(find.byKey(const Key('activity-view-btn')));
      await _frames(t);
      await t.tap(find.byKey(const Key('group-by-project')));
      await _frames(t);
      expect(find.byKey(const Key('conv-tile-t1')), findsOneWidget);
      _reset();
    });

    for (final size in const [Size(800, 700), Size(1100, 800)]) {
      testWidgets('every wide page fits at $size in both themes', (t) async {
        for (final dark in const [false, true]) {
          final router = await _mount(
            t,
            size: size,
            platform: TargetPlatform.windows,
            api: _api(),
            dark: dark,
          );
          router.push('/settings');
          await _frames(t);
          for (final section in SettingsSection.values) {
            await t.tap(find.byKey(Key('settings-section-${section.name}')));
            await _frames(t);
          }
          router.pushReplacement('/logs');
          await _frames(t);
          await t.pumpWidget(const SizedBox());
        }
        _reset();
      });
    }
  });

  group('settings', () {
    testWidgets('one model: a compact root leads to the sections a wide window '
        'lists', (t) async {
      final router = await _mount(
        t,
        size: _phone,
        platform: TargetPlatform.iOS,
        api: _api(),
        initial: '/settings',
      );
      expect(find.byKey(const Key('settings-identity')), findsOneWidget);
      expect(find.text('@fixture-user'), findsOneWidget);
      await capturePreview(t, 'workspace-settings-root');
      // Every root row states its value and leads somewhere.
      expect(find.text('Relay only'), findsOneWidget);
      await t.tap(find.byKey(const Key('settings-connection-path')));
      await _frames(t);
      expect(find.byKey(const Key('connection-path-settings')), findsOneWidget);
      await capturePreview(t, 'workspace-settings-connection');
      router.pop();
      await _frames(t);
      _reset();
    });

    testWidgets('self-host heads the page with its relay', (t) async {
      await _mount(
        t,
        size: _phone,
        platform: TargetPlatform.iOS,
        api: _api(
          config: const ConfigInfo(relay: 'relay.example:7666', hasKey: true),
        ),
        initial: '/settings',
      );
      expect(find.text('relay.example:7666'), findsOneWidget);
      expect(find.text('@fixture-user'), findsNothing);
      _reset();
    });

    testWidgets('a wide window lists the sections in the column', (t) async {
      await _mount(
        t,
        size: _wide,
        platform: TargetPlatform.macOS,
        api: _api(),
        initial: '/settings',
      );
      expect(find.byKey(const Key('theme-system')), findsOneWidget);
      await t.tap(find.byKey(const Key('settings-section-connection')));
      await _frames(t);
      expect(
        find.byKey(const Key('connection-window-settings')),
        findsOneWidget,
      );
      await capturePreview(t, 'workspace-settings-desktop');
      _reset();
    });
  });
}
