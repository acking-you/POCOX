/// Getting in and getting set up: account sign-in, codex setup, settings, and
/// self-host onboarding.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/account_onboarding_screen.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/screens/codex_setup_screen.dart';
import 'package:pocket_codex/src/screens/onboarding_screen.dart';
import 'package:pocket_codex/src/screens/settings_screen.dart';
import 'package:pocket_codex/src/ui_prefs.dart';

import '../fake_bridge_api.dart';
import '../support/screen_harness.dart';

/// UI preferences in memory: [saved] is the "file", whose initial read
/// waits for [gate] when given; [written] records every save. The app's
/// real store, with its readiness and replay, runs on top.
class _MemoryPrefs extends UiPrefsStore {
  _MemoryPrefs([this.saved = const UiPrefs(), this.gate]);

  final UiPrefs saved;
  final Completer<void>? gate;
  final List<UiPrefs> written = [];

  @override
  Future<UiPrefs> load() async {
    await gate?.future;
    return saved;
  }

  @override
  Future<void> save(UiPrefs prefs) async => written.add(prefs);
}

final _zh = lookupAppLocalizations(const Locale('zh'));

/// Account onboarding on a router with a stub home and a [welcome] page, over
/// [prefs]; the device code it hands out is authorized at the first poll.
Future<void> _mountOnboarding(
  WidgetTester t,
  _MemoryPrefs prefs, {
  Widget welcome = const Scaffold(body: Text('WELCOME-ROUTE')),
}) async {
  final api = FakeBridgeApi(config: const ConfigInfo(relay: '', hasKey: false))
    ..accountPollStatus = 'authorized';
  await t.pumpWidget(
    routerHost(
      api,
      initial: '/onboarding',
      routes: [
        GoRoute(
          path: '/onboarding',
          builder: (_, _) => const AccountOnboardingScreen(),
        ),
        stub('/', 'HOME-ROUTE'),
        GoRoute(path: '/welcome', builder: (_, _) => welcome),
      ],
      overrides: [uiPrefsProvider.overrideWith(() => prefs)],
    ),
  );
  await t.pumpAndSettle();
}

/// Sign in with the device code. The polling spinner is a perpetual
/// animation, so this advances by bounded pumps (pumpAndSettle would never
/// settle while it spins).
Future<void> _signInWithDeviceCode(WidgetTester t) async {
  await t.tap(find.text('设备码登录')); // accountUseDeviceCode (zh)
  await t.pump(); // accountLoginStart resolves
  await t.pump(); // the code and spinner show
  await t.pump(const Duration(seconds: 6)); // the 5 s poll: authorized
  await t.pump(); // accountLoginPoll resolves → go(...)
  await t.pump(); // router rebuilds
}

void main() {
  // AppSessionScreen keeps per-thread plan/effort memory in process-wide static
  // maps (so a reopened thread restores its mode before the persisted config
  // lands). Reset it between tests so memory from one test can't leak into
  // another that reuses a thread id.
  setUp(AppSessionScreen.debugResetThreadMemory);

  group('Codex setup', () {
    /// Mount the wizard with [status] seeded, wide enough for the desktop card
    /// layout.
    Future<FakeBridgeApi> pump(
      WidgetTester t, {
      required CodexSetupStatus status,
    }) async {
      final api = FakeBridgeApi(
        config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
      )..codexStatus = status;
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(1200, 1400);
      addTearDown(t.view.reset);
      await t.pumpWidget(host(const CodexSetupScreen(), api));
      await t.pumpAndSettle();
      return api;
    }

    const unconfigured = CodexSetupStatus(
      codexHome: r'C:\Users\test\.codex',
      hasConfig: false,
      hasAuth: false,
      hasCustomProvider: false,
      needsSetup: true,
      promptVariant: 'default',
    );
    const signedIn = CodexSetupStatus(
      codexHome: r'C:\Users\test\.codex',
      hasConfig: true,
      hasAuth: true,
      hasCustomProvider: false,
      authMode: 'chatgpt',
      needsSetup: false,
      promptVariant: 'default',
    );

    testWidgets(
      'unconfigured says why, and where each method is set',
      (t) async {
        final api = await pump(t, status: unconfigured);

        // The state card answers "is this working" before any method is offered.
        expect(api.codexSetupReads, 0);
        expect(find.byKey(const Key('codex-setup-state')), findsNothing);
        expect(find.byKey(const Key('codex-setup-error')), findsNothing);
        expect(find.byKey(const Key('codex-nondegraded-toggle')), findsNothing);
        expect(find.text('使用中'), findsNothing);
        // No global provider form: a provider is set per host.
        expect(find.byKey(const Key('codex-base-url')), findsNothing);
        expect(find.byKey(const Key('codex-save-provider')), findsNothing);
        // What this page sets up is explained behind the section's info mark.
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is Tooltip &&
                (w.message ?? '').contains(_zh.codexSetupProviderScope),
          ),
          findsOneWidget,
        );
        // This harness is a phone (android): there is no local Codex to sign
        // in on or host with, so both rows say where that happens instead.
        expect(find.byKey(const Key('codex-login-chatgpt')), findsNothing);
        expect(
          find.byKey(const Key('codex-login-desktop-only')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('codex-provider-hosts')), findsNothing);
        expect(
          find.byKey(const Key('codex-provider-desktop-only')),
          findsOneWidget,
        );
        expect(api.lastProvider, isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );

    testWidgets(
      'on a desktop each method has its control in its row',
      (t) async {
        await pump(t, status: signedIn);

        // The state names what codex signs in with, in words.
        expect(find.text('已通过 ChatGPT 登录'), findsOneWidget);
        expect(find.text('使用中'), findsOneWidget); // codexSetupInUse
        // Signed in: the row offers signing out, and the provider row the
        // way to a host's editor.
        expect(find.byKey(const Key('codex-logout-btn')), findsOneWidget);
        expect(find.byKey(const Key('codex-login-chatgpt')), findsNothing);
        expect(find.byKey(const Key('codex-provider-hosts')), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'an unreadable config.toml is not reported as working',
      (t) async {
        await pump(
          t,
          status: const CodexSetupStatus(
            codexHome: r'C:\Users\test\.codex',
            hasConfig: true,
            hasAuth: true,
            hasCustomProvider: false,
            authMode: 'chatgpt',
            needsSetup: false,
            promptVariant: 'default',
            configError: true,
            effectiveSource: 'invalid',
          ),
        );

        expect(find.text('无法读取 Codex 的 config.toml'), findsOneWidget);
        expect(find.text('使用中'), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'a provider codex already selects is reported, not edited',
      (t) async {
        final api = await pump(
          t,
          status: const CodexSetupStatus(
            codexHome: r'C:\Users\test\.codex',
            hasConfig: true,
            hasAuth: false,
            hasCustomProvider: true,
            needsSetup: false,
            promptVariant: 'default',
            effectiveSource: 'custom',
          ),
        );

        // codexSetupStatusProvider: the state card reads codex's own setup.
        expect(find.text('已配置自定义供应商'), findsOneWidget);
        expect(find.text('使用中'), findsOneWidget);
        expect(find.byKey(const Key('codex-global-provider')), findsOneWidget);
        expect(find.byKey(const Key('codex-base-url')), findsNothing);
        expect(find.byKey(const Key('codex-save-provider')), findsNothing);
        expect(api.lastProvider, isNull, reason: 'nothing is written');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'the prompt switch lives under Advanced and persists',
      (t) async {
        final api = await pump(t, status: signedIn);

        await t.tap(find.byKey(const Key('codex-nondegraded-toggle')));
        await t.pumpAndSettle();

        expect(api.codexStatus.promptVariant, 'non_degraded');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  });

  testWidgets('Onboarding explains why an expired account must sign in', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(
        relay: '',
        hasKey: false,
        mode: 'account',
        accountLogin: 'octocat',
      ),
    );
    await t.pumpWidget(
      host(const AccountOnboardingScreen(sessionExpired: true), api),
    );
    await t.pumpAndSettle();

    expect(find.byKey(const Key('account-session-expired')), findsOneWidget);
    expect(find.text('设备码登录'), findsOneWidget);
  });

  testWidgets('Settings shows masked key and relay', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await t.pumpWidget(host(const SettingsScreen(), api));
    await t.pumpAndSettle();
    expect(find.text('lb7666.top:7666'), findsOneWidget);
    expect(find.text('••••••••（已设置）'), findsOneWidget);
    expect(find.byKey(const Key('export-btn')), findsOneWidget);
  });

  testWidgets('compact Settings can reach the logs', (t) async {
    // The page menu that carries Logs is desktop-only, and the other compact
    // shortcut is in the chat drawer — unopenable for the user this matters to,
    // whose host is unreachable. Without a row here the logs explaining the
    // failure were only reachable after it was fixed.
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'lb7666.top:7666', hasKey: true),
    );
    await t.pumpWidget(
      routerHost(
        api,
        initial: '/settings',
        routes: [
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
          stub('/logs', 'logs-page'),
        ],
      ),
    );
    await t.pumpAndSettle();

    // The row is below the fold in a 600 px test viewport.
    await t.ensureVisible(find.byKey(const Key('diagnostics-btn')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('diagnostics-btn')));
    await t.pumpAndSettle();
    expect(find.text('logs-page'), findsOneWidget);
  });

  // A device-code sign-in routes by the saved guide state: the first on this
  // device opens the focused welcome guide, a later one (e.g. sign-out →
  // sign-in) goes straight to the chat.
  for (final (seen, opens, skips) in [
    (false, 'WELCOME-ROUTE', 'HOME-ROUTE'),
    (true, 'HOME-ROUTE', 'WELCOME-ROUTE'),
  ]) {
    testWidgets('onboarding: a device-code sign-in with guideSeen=$seen opens '
        '$opens', (t) async {
      await _mountOnboarding(t, _MemoryPrefs(UiPrefs(guideSeen: seen)));
      await _signInWithDeviceCode(t);
      expect(find.text(opens), findsOneWidget);
      expect(find.text(skips), findsNothing);
    });
  }

  testWidgets('onboarding: the device code copies itself and confirms', (
    t,
  ) async {
    final copied = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    // 'expired' lets the poll reach a terminal state, so no spinner or timer is
    // left pending at teardown (same reason as the expired-code test below).
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: '', hasKey: false),
    )..accountPollStatus = 'expired';
    await t.pumpWidget(host(const AccountOnboardingScreen(), api));
    await t.pumpAndSettle();
    await t.tap(find.text('设备码登录')); // accountUseDeviceCode (zh)
    await t.pump(); // accountLoginStart resolves
    await t.pump(); // the code renders
    expect(find.byKey(const Key('account-open-github')), findsOneWidget);

    // The code is the tap target: copying is the only reason it is on screen,
    // so it doesn't hide behind a separate button.
    await t.tap(find.byKey(const Key('account-code-copy')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));

    expect(copied.single, 'ABCD-1234');
    // And it says so — a silent clipboard write leaves the user unsure whether
    // to retype the code by hand.
    expect(find.text('已复制'), findsOneWidget); // copied (zh)

    await t.pump(const Duration(seconds: 6)); // poll fires → expired → stops
    await t.pumpAndSettle();
  });

  testWidgets('onboarding: an expired code clears and shows the expired '
      'message without navigating', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: '', hasKey: false),
    )..accountPollStatus = 'expired';
    await t.pumpWidget(
      routerHost(
        api,
        initial: '/onboarding',
        routes: [
          GoRoute(
            path: '/onboarding',
            builder: (_, _) => const AccountOnboardingScreen(),
          ),
          stub('/', 'HOME-ROUTE'),
        ],
      ),
    );
    await t.pumpAndSettle(); // initial onboarding (no spinner yet)
    await t.tap(find.text('设备码登录')); // device-code fallback
    await t.pump(); // start resolves
    await t.pump(); // code + spinner show
    expect(find.text('ABCD-1234'), findsOneWidget);
    await t.pump(
      const Duration(seconds: 6),
    ); // poll fires → 'expired' → setState
    // 'expired' clears _device, so the spinner is gone and we can settle.
    await t.pumpAndSettle();
    expect(find.text('代码已过期，请重试。'), findsOneWidget); // accountCodeExpired (zh)
    expect(find.text('ABCD-1234'), findsNothing); // cleared, back to sign-in
    expect(find.text('HOME-ROUTE'), findsNothing); // did NOT navigate
  });

  testWidgets('onboarding: browser sign-in (default) exchanges and navigates '
      'home', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: '', hasKey: false),
    );
    await t.pumpWidget(
      routerHost(
        api,
        initial: '/onboarding',
        routes: [
          GoRoute(
            path: '/onboarding',
            builder: (_, _) => const AccountOnboardingScreen(),
          ),
          stub('/', 'HOME-ROUTE'),
          stub('/welcome', 'WELCOME-ROUTE'),
        ],
        // The browser hand-off returns a redirect whose state matches the fake
        // bridge's started flow ('fake-state'), carrying a one-time code.
        overrides: [
          uiPrefsProvider.overrideWith(_MemoryPrefs.new),
          webAuthenticatorProvider.overrideWithValue(
            FakeWebAuthenticator(
              'pocketcodex://auth?exchange_code=xc1&state=fake-state',
            ),
          ),
        ],
      ),
    );
    await t.pumpAndSettle();
    // The PRIMARY button is the browser flow (the convenient default).
    await t.tap(find.text('使用 GitHub 登录'));
    // Flush the async chain (start → authenticate → exchange → toast + go) with
    // bounded pumps; pumpAndSettle would advance past the toast's 3s auto-dismiss.
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
    // First sign-in on this device → the focused welcome guide.
    expect(find.text('WELCOME-ROUTE'), findsOneWidget);
    expect(api.lastWebRedirectUri, isNotNull); // the web flow ran
    // Success toast (root ScaffoldMessenger) survives the navigation.
    expect(find.textContaining('octocat'), findsOneWidget);
    await t.pumpAndSettle(); // drain the SnackBar timer
  });

  group(
    'onboarding: routing after sign-in waits for the saved preferences',
    () {
      testWidgets('the saved guide state decides, not an interim change', (
        t,
      ) async {
        final gate = Completer<void>();
        final prefs = _MemoryPrefs(const UiPrefs(guideSeen: true), gate);
        await _mountOnboarding(t, prefs);
        final container = ProviderScope.containerOf(
          t.element(find.byType(AccountOnboardingScreen)),
        );
        // A change made while the file is still being read lands on an
        // interim snapshot, which knows nothing of the guide.
        container.read(uiPrefsProvider.notifier).setLastService('pcx:d:app:x');
        expect(container.read(uiPrefsProvider).valueOrNull?.guideSeen, isFalse);

        await _signInWithDeviceCode(t);
        expect(find.text('HOME-ROUTE'), findsNothing, reason: 'still waiting');
        expect(find.text('WELCOME-ROUTE'), findsNothing, reason: 'not interim');
        expect(find.byType(AccountOnboardingScreen), findsOneWidget);

        gate.complete();
        await t.pump();
        await t.pump();
        expect(find.text('HOME-ROUTE'), findsOneWidget);
        expect(find.text('WELCOME-ROUTE'), findsNothing);
        // The interim change was replayed onto the file, not over it.
        expect(prefs.written.last.guideSeen, isTrue);
        expect(prefs.written.last.lastServiceKey, 'pcx:d:app:x');
      });

      testWidgets('a screen gone while waiting routes nothing and reads '
          'nothing', (t) async {
        final gate = Completer<void>();
        final prefs = _MemoryPrefs(const UiPrefs(), gate);
        await _mountOnboarding(t, prefs);
        await _signInWithDeviceCode(t);
        expect(find.text('WELCOME-ROUTE'), findsNothing, reason: 'waiting');

        // The whole scope goes while the bounded wait is open.
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(seconds: 3)); // past the 2 s bound
        expect(t.takeException(), isNull);
        gate.complete();
        await t.pump();
        expect(t.takeException(), isNull);
        expect(
          prefs.written,
          isEmpty,
          reason: 'a disposed store writes nothing',
        );
      });
    },
  );

  for (final (how, error, cause) in [
    ('is cancelled', PlatformException(code: 'CANCELED'), null),
    // Not every browser failure is a dismissal: the desktop loopback listener
    // can time out, and a redirect can land in a browser profile that isn't
    // signed in. Those used to surface as a raw transport error with no next
    // step, even though the remedy is the same as CANCELED's.
    ('never returns', StateError('listener timed out'), 'listener timed out'),
  ]) {
    testWidgets('onboarding: a browser sign-in that $how guides to the device '
        'code', (t) async {
      await t.pumpWidget(
        routerHost(
          FakeBridgeApi(config: const ConfigInfo(relay: '', hasKey: false)),
          initial: '/onboarding',
          routes: [
            GoRoute(
              path: '/onboarding',
              builder: (_, _) => const AccountOnboardingScreen(),
            ),
            stub('/', 'HOME-ROUTE'),
          ],
          overrides: [
            webAuthenticatorProvider.overrideWithValue(
              FakeWebAuthenticator('', error: error),
            ),
          ],
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('使用 GitHub 登录'));
      await t.pumpAndSettle();

      // No navigation: the screen leads with the remedy, and both ways in
      // stay on screen — the device code and a browser retry.
      expect(find.text('HOME-ROUTE'), findsNothing);
      expect(find.textContaining(_zh.accountWebTrouble), findsOneWidget);
      expect(find.text('设备码登录'), findsOneWidget);
      expect(find.text('使用 GitHub 登录'), findsOneWidget);
      // The cause is kept, so a real bug stays diagnosable from a screenshot.
      if (cause != null) {
        expect(find.textContaining(cause), findsOneWidget);
      }
    });
  }

  testWidgets('settings: account sign-out clears the user and returns to '
      'onboarding', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(
        relay: '',
        hasKey: false,
        mode: 'account',
        accountLogin: 'octocat',
      ),
    )..accountUser = const AccountUser(login: 'octocat', accountId: '42');
    await t.pumpWidget(
      routerHost(
        api,
        initial: '/settings',
        routes: [
          GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
          stub('/onboarding', 'ONBOARDING-ROUTE'),
        ],
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('@octocat'), findsOneWidget); // signed-in identity
    // Centred: at the list's edge it would sit under the bottom navigation.
    await Scrollable.ensureVisible(
      t.element(find.byKey(const Key('sign-out-btn'))),
      alignment: 0.5,
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('sign-out-btn')));
    await t.pumpAndSettle();
    expect(api.accountUser, isNull); // accountLogout ran
    expect(find.text('ONBOARDING-ROUTE'), findsOneWidget); // back to onboarding
  });

  testWidgets('onboarding: signing in makes the app SEE the account', (
    t,
  ) async {
    // The bug this locks: config is a FutureProvider that had already resolved
    // (tokenless) before the login, and nothing invalidated it afterwards. The
    // token reached config.toml, but every `mode == 'account'` gate in the app
    // — Settings' account section, the home hosting CTA, the Sessions/Hosting
    // tabs — kept reading the pre-login snapshot and behaved as signed out.
    //
    // Land on the real Settings screen: it is the visible symptom, and it
    // renders the identity only when the config says we're signed in.
    await _mountOnboarding(t, _MemoryPrefs(), welcome: const SettingsScreen());
    final container = ProviderScope.containerOf(
      t.element(find.byType(AccountOnboardingScreen)),
    );

    // Warm the config cache the way the real app does — reading it BEFORE the
    // login is what made the stale value stick.
    await container.read(configProvider.future);
    expect(container.read(configProvider).valueOrNull?.mode, 'unconfigured');

    await _signInWithDeviceCode(t);
    await t.pumpAndSettle();

    // The provider re-read the post-login config, so the identity is on screen.
    expect(container.read(configProvider).valueOrNull?.mode, 'account');
    expect(find.text('@octocat'), findsOneWidget);
  });

  testWidgets('onboarding: desktop leads with the device code, mobile with the '
      'browser', (t) async {
    // The two idioms don't cost the same per platform: a desktop redirect comes
    // back through a loopback listener and usually opens whichever browser
    // profile is default — often not the one signed into GitHub — while the
    // device code has no redirect at all. On a phone the deep link returns
    // straight to the app, so tapping through is the shortest path.
    Future<void> mount() async {
      await t.pumpWidget(
        routerHost(
          FakeBridgeApi(config: const ConfigInfo(relay: '', hasKey: false)),
          initial: '/onboarding',
          routes: [
            GoRoute(
              path: '/onboarding',
              builder: (_, _) => const AccountOnboardingScreen(),
            ),
          ],
        ),
      );
      await t.pumpAndSettle();
    }

    // Primary action = the FilledButton; the other stays available as an
    // OutlinedButton, so neither platform loses a way in.
    String primaryLabel() => t
        .widget<Text>(
          find.descendant(
            of: find.byType(FilledButton),
            matching: find.byType(Text),
          ),
        )
        .data!;

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await mount();
      expect(primaryLabel(), '设备码登录'); // accountUseDeviceCode
      expect(
        find.widgetWithText(OutlinedButton, '使用 GitHub 登录'),
        findsOneWidget,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }

    // The harness reports android, which is the mobile default.
    await mount();
    expect(primaryLabel(), '使用 GitHub 登录'); // accountSignInButton
    expect(find.widgetWithText(OutlinedButton, '设备码登录'), findsOneWidget);
  });

  testWidgets('self-host setup can be left again', (t) async {
    // Reached from account onboarding with `go`, which REPLACES the stack — so
    // there is nothing to pop, and without an explicit way back the only exits
    // are finishing self-host setup or killing the app. A user who opened
    // "Advanced" to look at the relay fields was stranded.
    await t.pumpWidget(
      routerHost(
        FakeBridgeApi(config: const ConfigInfo(relay: '', hasKey: false)),
        initial: '/onboarding',
        routes: [
          GoRoute(
            path: '/onboarding',
            builder: (_, _) => const AccountOnboardingScreen(),
          ),
          GoRoute(
            path: '/onboarding/self-host',
            builder: (_, _) => const OnboardingScreen(),
          ),
        ],
      ),
    );
    await t.pumpAndSettle();

    await t.tap(find.text('高级 / 自部署')); // accountAdvanced
    await t.pumpAndSettle();
    await t.tap(find.text('改用自建 relay')); // accountAdvancedSelfHost
    await t.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);

    await t.tap(find.byKey(const Key('self-host-back')));
    await t.pumpAndSettle();
    expect(
      find.byType(AccountOnboardingScreen),
      findsOneWidget,
      reason: 'back must return to account onboarding, not strand the user',
    );
  });
}
