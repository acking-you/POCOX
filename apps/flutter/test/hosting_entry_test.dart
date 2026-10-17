// The real entries into hosting and Codex sign-in (welcome guide, Settings →
// Codex setup) while an operation is held: the visible controls, the system
// back route, the page's own navigation and its keyboard shortcut all keep
// the page until it may be left, and a sign-in answered after its page
// closed is closed, not left running. Also the quit status banner.
//
// Settings, Codex setup and the chat's setup banner reach the one hosting
// editor: no host opens a new-host editor, running native and ACP hosts are
// picked by their own identity, and the chat opens exactly its own host.
// Opening, picking, cancelling and leaving start, stop, save and sign in
// nothing, and leave the originating page (and a chat draft) as it was.
// One entry runs at a time per page: activations while the host list is
// still being read open one picker or editor, and a read answered after the
// page was covered, closed or failed opens nothing and blocks no retry.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/host_editor_page.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/quit_status.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/screens/codex_setup_screen.dart';
import 'package:pocket_codex/src/screens/settings_screen.dart';
import 'package:pocket_codex/src/screens/welcome_guide_screen.dart';
import 'package:pocket_codex/src/widgets/utility_page.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

const _accountConfig = ConfigInfo(
  relay: null,
  hasKey: false,
  mode: 'account',
  accountLogin: 'octocat',
);

Future<void> _pump(
  WidgetTester t,
  FakeBridgeApi api, {
  required String initial,
}) async {
  final container = ProviderContainer(
    overrides: [bridgeApiProvider.overrideWithValue(api)],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/welcome', builder: (_, _) => const WelcomeGuideScreen()),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      GoRoute(
        path: '/setup/codex',
        builder: (_, _) => const CodexSetupScreen(),
      ),
      stub('/', 'HOME-ROUTE'),
      stub('/manage', 'MANAGE-ROUTE'),
      stub('/sessions', 'SESSIONS-ROUTE'),
      stub('/logs', 'LOGS-ROUTE'),
    ],
  );
  addTearDown(router.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
}

/// Bounded pumping: a held operation shows a progress bar that never
/// settles.
Future<void> _frames(WidgetTester t, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void _desktop(WidgetTester t) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  // Wide: the editor shows its workspace navigation rail.
  t.view.physicalSize = const Size(1300, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

const _codexHost = AppServeStatus(
  name: 'alpha',
  device: 'local',
  pid: 4242,
  alive: true,
  appListenAddr: '127.0.0.1:18080',
  appServiceKey: 'pcx:local:app:alpha',
  appRegistered: true,
  metaListenAddr: '127.0.0.1:18090',
  metaServiceKey: 'pcx:local:meta:alpha',
  metaRegistered: true,
  codexBinary: '/usr/local/bin/codex',
  provider: 'codex',
  configSource: 'inherited',
  configRevision: 0,
  incarnation: 'inc-alpha',
);

const _acpHost = AppServeStatus(
  name: 'tool',
  device: 'local',
  alive: true,
  appListenAddr: '127.0.0.1:18200',
  appServiceKey: 'pcx:local:acp:tool',
  appRegistered: true,
  metaListenAddr: '127.0.0.1:18201',
  metaServiceKey: 'pcx:local:meta:tool',
  metaRegistered: true,
  codexBinary: '/opt/tool/bin/tool-acp',
  provider: 'acp',
  protocol: 'acp',
  providerName: 'Tool',
  profileId: 'custom-tool-1a2b3c4d',
  agentPhase: 'ready',
  configSource: 'inherited',
  configRevision: 0,
  incarnation: 'inc-tool',
);

/// Opening, picking and leaving changed nothing: the same hosts run and no
/// start, save, apply, provider write or sign-in happened.
void _untouched(FakeBridgeApi api, List<String> hosts) {
  expect(
    api.serveHosts.map((h) => h.name),
    hosts,
    reason: 'nothing started or stopped',
  );
  expect(api.lastServePort, isNull);
  expect(api.startConfiguredCalls, isEmpty);
  expect(api.hostConfigSaves, isEmpty);
  expect(api.applyCalls, isEmpty);
  expect(api.lastProvider, isNull, reason: 'no global provider written');
  expect(api.localSessionBinaries, isEmpty, reason: 'no sign-in began');
  expect(api.signInSessions, isEmpty);
}

/// The hosting editor on screen, and which host it edits (null: a new one).
AppServeStatus? _edited(WidgetTester t) {
  expect(find.byType(HostingEditor), findsOneWidget);
  return t.widget<HostingEditor>(find.byType(HostingEditor)).existing;
}

Future<void> _tap(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(Key(key)));
  await t.tap(find.byKey(Key(key)));
  await _frames(t);
}

/// Leave the page on top through the system back route.
Future<void> _back(WidgetTester t) async {
  await t.binding.handlePopRoute();
  await _frames(t);
}

/// Activate the control [key] from the keyboard: focus it, then Enter.
Future<void> _press(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(Key(key)));
  final label = find
      .descendant(of: find.byKey(Key(key)), matching: find.byType(Text))
      .first;
  Focus.of(t.element(label)).requestFocus();
  await t.pump();
  await t.sendKeyEvent(LogicalKeyboardKey.enter);
  await _frames(t);
}

/// A fake whose next host list read can be held ([readGate]) or fail
/// ([readError]); [reads] counts them.
class _HeldReads extends FakeBridgeApi {
  _HeldReads() : super(config: _accountConfig);

  Completer<void>? readGate;
  Object? readError;
  int reads = 0;

  @override
  Future<List<AppServeStatus>> appServeStatus() async {
    reads++;
    final gate = readGate;
    readGate = null;
    if (gate != null) await gate.future;
    final error = readError;
    readError = null;
    if (error != null) throw error;
    return super.appServeStatus();
  }
}

final _picker = find.byKey(const Key('host-picker'));

void main() {
  testWidgets('a start held from the welcome guide keeps the editor through '
      'its controls, back, its navigation and Ctrl+,', (t) async {
    _desktop(t);
    final semantics = t.ensureSemantics();
    try {
      final api = FakeBridgeApi(config: _accountConfig);
      await _pump(t, api, initial: '/welcome');
      await _frames(t);
      await t.tap(find.byKey(const Key('welcome-start-hosting-btn')));
      await _frames(t);
      final start = find.byKey(const Key('start-hosting-btn'));
      expect(start, findsOneWidget);

      final held = Completer<void>();
      api.serveStartGate = held;
      await t.ensureVisible(start);
      await t.tap(start);
      await _frames(t);
      expect(api.lastServePort, isNull, reason: 'the start is still held');

      // The visible controls say so.
      expect(
        t.getSemantics(find.byKey(const Key('host-editor-close'))),
        isSemantics(isButton: true, hasEnabledState: true),
      );
      expect(
        t.getSemantics(find.byKey(const Key('host-editor-close'))),
        isNot(isSemantics(isEnabled: true)),
      );
      expect(
        t
            .widget<ButtonStyleButton>(
              find.byKey(const Key('start-hosting-btn')),
            )
            .onPressed,
        isNull,
      );

      // The page's own navigation is visible and asks the page first.
      await t.tap(find.byKey(const Key('workspace-nav-/settings')));
      await _frames(t);
      expect(start, findsOneWidget);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.byKey(const Key('host-leave-dialog')), findsNothing);

      // System back.
      await t.binding.handlePopRoute();
      await _frames(t);
      expect(start, findsOneWidget);

      // The page shortcut, from focus inside the page.
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await _frames(t, 2);
      final focus = FocusManager.instance.primaryFocus?.context;
      expect(
        focus?.findAncestorWidgetOfExactType<AppPageShortcuts>(),
        isNotNull,
        reason: 'the shortcut must reach the editor page',
      );
      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.comma);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _frames(t);
      expect(start, findsOneWidget);
      expect(find.byType(SettingsScreen), findsNothing);

      // Once the start completes, the editor closes by itself.
      held.complete();
      await _frames(t, 20);
      expect(api.lastServePort, 18080);
      expect(start, findsNothing);
      expect(find.byKey(const Key('welcome-title')), findsOneWidget);
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final (entry, initial, button) in [
    ('Settings', '/settings', 'codex-setup-btn'),
    ('the welcome guide', '/welcome', 'welcome-codex-setup-btn'),
  ]) {
    testWidgets('Codex setup from $entry: a sign-in still opening when the '
        'page closes is closed', (t) async {
      _desktop(t);
      try {
        final api = FakeBridgeApi(config: _accountConfig);
        await _pump(t, api, initial: initial);
        await _frames(t);
        await t.ensureVisible(find.byKey(Key(button)));
        await t.tap(find.byKey(Key(button)));
        await _frames(t);
        expect(find.byType(CodexSetupScreen), findsOneWidget);

        final open = Completer<void>();
        api.localSessionGate = open;
        await t.ensureVisible(find.byKey(const Key('codex-login-chatgpt')));
        await t.tap(find.byKey(const Key('codex-login-chatgpt')));
        await _frames(t);
        expect(
          api.localSessionBinaries,
          hasLength(1),
          reason: 'the open began',
        );

        // Leave while the private codex is still starting.
        await t.binding.handlePopRoute();
        await _frames(t);
        expect(find.byType(CodexSetupScreen), findsNothing);
        expect(find.byKey(Key(button)), findsOneWidget);

        open.complete();
        await _frames(t);
        expect(api.signInSessions, isEmpty, reason: 'nothing left open');
        expect(api.closedSignInSessions, ['local-0']);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  group('Settings and Codex setup reach the hosting editor', () {
    testWidgets('with no host, Settings opens a new host and back returns', (
      t,
    ) async {
      _desktop(t);
      try {
        final api = FakeBridgeApi(config: _accountConfig);
        await _pump(t, api, initial: '/settings');
        await _frames(t);
        await _tap(t, 'settings-hosting-btn');
        expect(find.byKey(const Key('host-picker')), findsNothing);
        expect(_edited(t), isNull, reason: 'a new host, not a running one');
        _untouched(api, const []);

        await _back(t);
        expect(find.byType(HostingEditor), findsNothing);
        expect(find.byKey(const Key('settings-hosting-btn')), findsOneWidget);
        _untouched(api, const []);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('running native and ACP hosts are picked by identity', (
      t,
    ) async {
      _desktop(t);
      try {
        final api = FakeBridgeApi(config: _accountConfig)
          ..serveHosts.addAll([_codexHost, _acpHost]);
        await _pump(t, api, initial: '/settings');
        await _frames(t);

        // Cancel: back on Settings, nothing opened.
        await _tap(t, 'settings-hosting-btn');
        expect(find.byKey(const Key('host-picker')), findsOneWidget);
        expect(
          find.byKey(const Key('host-pick-pcx:local:app:alpha')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('host-pick-pcx:local:acp:tool')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('host-pick-new')), findsOneWidget);
        await _tap(t, 'host-pick-cancel');
        expect(find.byKey(const Key('host-picker')), findsNothing);
        expect(find.byType(HostingEditor), findsNothing);
        expect(find.byKey(const Key('settings-hosting-btn')), findsOneWidget);

        for (final (pick, key) in [
          ('host-pick-pcx:local:acp:tool', 'pcx:local:acp:tool'),
          ('host-pick-pcx:local:app:alpha', 'pcx:local:app:alpha'),
          ('host-pick-new', null),
        ]) {
          await _tap(t, 'settings-hosting-btn');
          await _tap(t, pick);
          expect(find.byKey(const Key('host-picker')), findsNothing);
          expect(_edited(t)?.appServiceKey, key, reason: pick);
          await _back(t);
          expect(find.byType(HostingEditor), findsNothing);
          expect(find.byKey(const Key('settings-hosting-btn')), findsOneWidget);
        }
        _untouched(api, const ['alpha', 'tool']);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a compact desktop Settings offers the same entry', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      t.view.physicalSize = const Size(600, 1000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      try {
        final api = FakeBridgeApi(config: _accountConfig)
          ..serveHosts.add(_acpHost);
        await _pump(t, api, initial: '/settings');
        await _frames(t);
        expect(find.byType(ListTile), findsWidgets, reason: 'compact list');
        await _tap(t, 'settings-hosting-btn');
        await _tap(t, 'host-pick-pcx:local:acp:tool');
        expect(_edited(t)?.name, 'tool');
        await _back(t);
        expect(find.byKey(const Key('settings-hosting-btn')), findsOneWidget);
        _untouched(api, const ['tool']);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('mobile Settings offers no hosting entry', (t) async {
      final api = FakeBridgeApi(config: _accountConfig);
      await _pump(t, api, initial: '/settings');
      await _frames(t);
      expect(find.byKey(const Key('settings-hosting-btn')), findsNothing);
      expect(find.byKey(const Key('codex-setup-btn')), findsOneWidget);
    });

    testWidgets('Codex setup has no global provider form; its host entry '
        'returns to Codex setup', (t) async {
      _desktop(t);
      try {
        final api = FakeBridgeApi(config: _accountConfig)
          ..serveHosts.add(_codexHost);
        await _pump(t, api, initial: '/settings');
        await _frames(t);
        await _tap(t, 'codex-setup-btn');
        expect(find.byType(CodexSetupScreen), findsOneWidget);
        expect(find.byKey(const Key('codex-base-url')), findsNothing);
        expect(find.byKey(const Key('codex-api-key')), findsNothing);
        expect(find.byKey(const Key('codex-save-provider')), findsNothing);

        await _tap(t, 'codex-provider-hosts');
        await _tap(t, 'host-pick-pcx:local:app:alpha');
        expect(_edited(t)?.incarnation, 'inc-alpha');
        await _back(t);
        expect(find.byType(HostingEditor), findsNothing);
        expect(find.byType(CodexSetupScreen), findsOneWidget);
        _untouched(api, const ['alpha']);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('one hosting entry at a time per page', () {
    testWidgets('pointer and keyboard activations during a delayed read open '
        'one picker, and a double pick one editor', (t) async {
      _desktop(t);
      try {
        final api = _HeldReads()..serveHosts.add(_codexHost);
        await _pump(t, api, initial: '/settings');
        await _frames(t);
        final read = Completer<void>();
        api.readGate = read;
        final before = api.reads;
        await _tap(t, 'settings-hosting-btn');
        await _tap(t, 'settings-hosting-btn');
        await _press(t, 'settings-hosting-btn');
        expect(_picker, findsNothing, reason: 'still reading');
        expect(api.reads, before + 1, reason: 'one entry reads');

        read.complete();
        await _frames(t);
        expect(_picker, findsOneWidget);
        await _tap(t, 'host-pick-cancel');
        expect(_picker, findsNothing, reason: 'no second picker was queued');
        expect(find.byType(HostingEditor), findsNothing);

        // Released by the cancel: the keyboard opens it again.
        await _press(t, 'settings-hosting-btn');
        expect(_picker, findsOneWidget);
        // A second activation while the picker closes closes nothing else.
        final alpha = find.byKey(const Key('host-pick-pcx:local:app:alpha'));
        await t.tap(alpha);
        await t.tap(alpha, warnIfMissed: false);
        await _frames(t);
        expect(_picker, findsNothing);
        expect(_edited(t)?.appServiceKey, 'pcx:local:app:alpha');
        await _back(t);
        expect(find.byType(HostingEditor), findsNothing);
        expect(find.byKey(const Key('settings-hosting-btn')), findsOneWidget);
        _untouched(api, const ['alpha']);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('with no host, activations during a delayed read open one '
        'editor', (t) async {
      _desktop(t);
      try {
        final api = _HeldReads();
        await _pump(t, api, initial: '/settings');
        await _frames(t);
        final read = Completer<void>();
        api.readGate = read;
        await _tap(t, 'settings-hosting-btn');
        await _press(t, 'settings-hosting-btn');
        await _tap(t, 'settings-hosting-btn');
        expect(find.byType(HostingEditor), findsNothing, reason: 'reading');

        read.complete();
        await _frames(t);
        expect(_edited(t), isNull, reason: 'one new-host editor');
        await _back(t);
        expect(
          find.byType(HostingEditor),
          findsNothing,
          reason: 'no second editor beneath',
        );
        expect(find.byKey(const Key('settings-hosting-btn')), findsOneWidget);

        await _tap(t, 'settings-hosting-btn');
        expect(_edited(t), isNull, reason: 'released once the editor closed');
        await _back(t);
        expect(find.byType(HostingEditor), findsNothing);
        _untouched(api, const []);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    for (final (label, hosts) in [
      ('no host', const <AppServeStatus>[]),
      ('a running host', const [_codexHost]),
    ]) {
      testWidgets('$label: a read answered after another page opened over '
          'Settings opens nothing there', (t) async {
        _desktop(t);
        try {
          final api = _HeldReads()..serveHosts.addAll(hosts);
          await _pump(t, api, initial: '/settings');
          await _frames(t);
          final read = Completer<void>();
          api.readGate = read;
          await _tap(t, 'settings-hosting-btn');
          await _tap(t, 'codex-setup-btn');
          expect(find.byType(CodexSetupScreen), findsOneWidget);

          read.complete();
          await _frames(t);
          expect(_picker, findsNothing);
          expect(find.byType(HostingEditor), findsNothing);
          expect(find.byType(CodexSetupScreen), findsOneWidget);
          expect(
            find.byType(SettingsScreen, skipOffstage: false),
            findsOneWidget,
            reason: 'the caller stayed mounted beneath',
          );

          // Back on Settings, the entry works again.
          await _back(t);
          expect(find.byType(CodexSetupScreen), findsNothing);
          await _tap(t, 'settings-hosting-btn');
          if (hosts.isEmpty) {
            expect(_edited(t), isNull);
            await _back(t);
          } else {
            expect(_picker, findsOneWidget);
            await _tap(t, 'host-pick-cancel');
          }
          expect(_picker, findsNothing);
          expect(find.byType(HostingEditor), findsNothing);
          _untouched(api, [for (final h in hosts) h.name]);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    testWidgets('a read answered after Codex setup closed opens nothing', (
      t,
    ) async {
      _desktop(t);
      try {
        final api = _HeldReads()..serveHosts.add(_codexHost);
        await _pump(t, api, initial: '/settings');
        await _frames(t);
        await _tap(t, 'codex-setup-btn');
        final read = Completer<void>();
        api.readGate = read;
        await _tap(t, 'codex-provider-hosts');
        await _back(t);
        expect(
          find.byType(CodexSetupScreen, skipOffstage: false),
          findsNothing,
          reason: 'the origin is disposed',
        );

        read.complete();
        await _frames(t);
        expect(_picker, findsNothing);
        expect(find.byType(HostingEditor), findsNothing);
        expect(find.byKey(const Key('settings-hosting-btn')), findsOneWidget);

        // Settings' own entry is independent of the closed page.
        await _tap(t, 'settings-hosting-btn');
        await _tap(t, 'host-pick-pcx:local:app:alpha');
        expect(_edited(t)?.incarnation, 'inc-alpha');
        await _back(t);
        expect(find.byType(HostingEditor), findsNothing);
        _untouched(api, const ['alpha']);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a failed read offers a new host, and a retry reads again', (
      t,
    ) async {
      _desktop(t);
      try {
        final api = _HeldReads()..serveHosts.add(_codexHost);
        await _pump(t, api, initial: '/settings');
        await _frames(t);
        api.readError = StateError('bridge unavailable');
        final before = api.reads;
        final alpha = find.byKey(const Key('host-pick-pcx:local:app:alpha'));
        await _tap(t, 'settings-hosting-btn');
        expect(_picker, findsOneWidget);
        expect(find.byKey(const Key('host-pick-failed')), findsOneWidget);
        expect(find.byKey(const Key('host-pick-new')), findsOneWidget);
        expect(alpha, findsNothing);
        await _tap(t, 'host-pick-cancel');
        expect(_picker, findsNothing);
        expect(find.byType(HostingEditor), findsNothing);

        await _press(t, 'settings-hosting-btn');
        expect(api.reads, before + 2, reason: 'the failure was not kept');
        expect(_picker, findsOneWidget);
        expect(find.byKey(const Key('host-pick-failed')), findsNothing);
        await _tap(t, 'host-pick-pcx:local:app:alpha');
        expect(_edited(t)?.appServiceKey, 'pcx:local:app:alpha');
        await _back(t);
        expect(find.byType(HostingEditor), findsNothing);
        _untouched(api, const ['alpha']);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group("the chat's setup banner", () {
    Future<FakeBridgeApi> chat(WidgetTester t, AppServeStatus local) async {
      _desktop(t);
      final api = FakeBridgeApi()
        ..serveHosts.add(local)
        ..appThreads.add(
          const ThreadMeta(
            id: 'a',
            preview: 'Alpha',
            cwd: '/project',
            updatedAt: 0,
          ),
        );
      await api.appConnect(local.appServiceKey, 28080);
      await t.pumpWidget(
        ProviderScope(
          overrides: [bridgeApiProvider.overrideWithValue(api)],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AppSessionScreen(
              serviceKey: local.appServiceKey,
              threadId: 'a',
              home: true,
            ),
          ),
        ),
      );
      await _frames(t);
      return api;
    }

    testWidgets("opens exactly this host's editor and keeps the draft", (
      t,
    ) async {
      try {
        final api = await chat(t, _codexHost);
        expect(find.byKey(const Key('codex-chat-needs-setup')), findsOneWidget);
        final input = find.byKey(const Key('composer-input'));
        await t.enterText(input, 'Draft kept');
        await _frames(t);

        await _tap(t, 'codex-chat-setup-btn');
        final edited = _edited(t);
        expect(edited?.appServiceKey, 'pcx:local:app:alpha');
        expect(edited?.incarnation, 'inc-alpha');
        _untouched(api, const ['alpha']);

        await _back(t);
        expect(find.byType(HostingEditor), findsNothing);
        expect(t.widget<TextField>(input).controller?.text, 'Draft kept');
        expect(api.turnStartCount, 0, reason: 'nothing was sent');
        _untouched(api, const ['alpha']);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('a host launched with its own provider needs no Codex setup', (
      t,
    ) async {
      try {
        const custom = AppServeStatus(
          name: 'alpha',
          device: 'local',
          pid: 4242,
          alive: true,
          appListenAddr: '127.0.0.1:18080',
          appServiceKey: 'pcx:local:app:alpha',
          appRegistered: true,
          metaListenAddr: '127.0.0.1:18090',
          metaServiceKey: 'pcx:local:meta:alpha',
          metaRegistered: true,
          provider: 'codex',
          configSource: 'custom',
          configRevision: 1,
          incarnation: 'inc-alpha',
        );
        final api = await chat(t, custom);
        expect(api.codexStatus.needsSetup, isTrue, reason: 'Codex itself');
        expect(find.byKey(const Key('codex-chat-needs-setup')), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('quit', () {
    test(
      'a failed stop keeps the app and says why; a retry can succeed',
      () async {
        final status = ValueNotifier<QuitStatus?>(null);
        addTearDown(status.dispose);
        final seen = <bool?>[];
        status.addListener(() => seen.add(status.value?.stopping));
        final failed = await stopHostingForQuit(
          () async => throw StateError('still stopping: `alpha` did not exit'),
          status,
        );
        expect(failed, isFalse);
        expect(status.value?.stopping, isFalse);
        expect(status.value?.error, contains('alpha'));
        final done = await stopHostingForQuit(() async {}, status);
        expect(done, isTrue);
        expect(status.value, isNull);
        expect(seen, [true, false, true, null]);
      },
    );

    testWidgets('the banner shows progress, then the reason with Quit again', (
      t,
    ) async {
      final status = ValueNotifier<QuitStatus?>(null);
      addTearDown(status.dispose);
      var retries = 0;
      await t.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: QuitStatusBanner(status: status, onRetry: () => retries++),
          ),
        ),
      );
      expect(find.byKey(const Key('quit-status')), findsNothing);
      status.value = const QuitStatus.stopping();
      await t.pump();
      expect(find.byKey(const Key('quit-status')), findsOneWidget);
      expect(find.byKey(const Key('quit-retry')), findsNothing);
      status.value = const QuitStatus.blocked('`alpha` did not exit');
      await t.pump();
      expect(find.textContaining('`alpha` did not exit'), findsOneWidget);
      await t.tap(find.byKey(const Key('quit-retry')));
      expect(retries, 1);
    });
  });
}
