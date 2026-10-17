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
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/screens/account_onboarding_screen.dart';
import 'package:pocket_codex/src/screens/app_session_screen.dart';
import 'package:pocket_codex/src/screens/codex_setup_screen.dart';
import 'package:pocket_codex/src/screens/onboarding_screen.dart';
import 'package:pocket_codex/src/screens/settings_screen.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/loading.dart';

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

    testWidgets('unconfigured says why, and where each method is set', (
      t,
    ) async {
      final api = await pump(t, status: unconfigured);

      // The state card answers "is this working" before any method is offered.
      expect(find.text('尚未配置'), findsOneWidget); // codexSetupStatusNeedSetup
      expect(find.text('使用中'), findsNothing);
      // No global provider form: a provider is set per host.
      expect(find.byKey(const Key('codex-base-url')), findsNothing);
      expect(find.byKey(const Key('codex-save-provider')), findsNothing);
      // What this page sets up is explained behind the section's info mark.
      expect(
        find.byWidgetPredicate(
          (w) => w is Tooltip && (w.message ?? '').contains('本页配置 Codex 本身'),
        ),
        findsOneWidget,
      );
      // This harness is a phone (android): there is no local Codex to sign
      // in on or host with, so both rows say where that happens instead.
      expect(find.byKey(const Key('codex-login-chatgpt')), findsNothing);
      expect(find.byKey(const Key('codex-login-desktop-only')), findsOneWidget);
      expect(find.byKey(const Key('codex-provider-hosts')), findsNothing);
      expect(
        find.byKey(const Key('codex-provider-desktop-only')),
        findsOneWidget,
      );
      expect(api.lastProvider, isNull);
    });

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

    testWidgets('an unreadable config.toml is not reported as working', (
      t,
    ) async {
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
    });

    testWidgets('a provider codex already selects is reported, not edited', (
      t,
    ) async {
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
    });

    testWidgets('the prompt switch lives under Advanced and persists', (
      t,
    ) async {
      final api = await pump(t, status: signedIn);
      expect(find.text('高级'), findsOneWidget); // codexSetupAdvanced

      await t.tap(find.byKey(const Key('codex-nondegraded-toggle')));
      await t.pumpAndSettle();

      expect(api.codexStatus.promptVariant, 'non_degraded');
    });
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
    expect(find.text('登录已过期'), findsOneWidget);
    expect(find.textContaining('请重新登录以恢复服务连接'), findsOneWidget);
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

  testWidgets('onboarding: sign in shows the code, then authorized opens the '
      'first-run guide', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: '', hasKey: false),
    )..accountPollStatus = 'authorized';
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
        overrides: [uiPrefsProvider.overrideWith(_MemoryPrefs.new)],
      ),
    );
    await t.pumpAndSettle(); // initial onboarding (no spinner yet)
    await t.tap(find.text('设备码登录')); // accountUseDeviceCode (zh): device flow
    // The polling spinner is a perpetual animation, so advance via bounded pumps
    // (pumpAndSettle would never settle while it spins).
    await t.pump(); // _startDevice: accountLoginStart resolves
    await t.pump(); // setState shows the code + spinner
    expect(find.text('ABCD-1234'), findsOneWidget); // user code shown
    expect(find.text('打开 GitHub'), findsOneWidget); // accountOpenGitHub (zh)
    await t.pump(const Duration(seconds: 6)); // fire the 5s poll interval
    await t.pump(); // accountLoginPoll resolves → go('/welcome')
    await t.pump(); // router rebuilds
    // First sign-in on this device → the focused welcome guide, not the home.
    expect(find.text('WELCOME-ROUTE'), findsOneWidget);
  });

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

  testWidgets('onboarding: a later sign-in on this device skips the guide', (
    t,
  ) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: '', hasKey: false),
    )..accountPollStatus = 'authorized';
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
        overrides: [
          // The guide was already seen on this device (e.g. sign-out → sign-in).
          uiPrefsProvider.overrideWith(
            () => _MemoryPrefs(const UiPrefs(guideSeen: true)),
          ),
        ],
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('设备码登录'));
    await t.pump();
    await t.pump();
    await t.pump(const Duration(seconds: 6)); // fire the 5s poll interval
    await t.pump();
    await t.pump();
    expect(find.text('HOME-ROUTE'), findsOneWidget); // straight to the chat
    expect(find.text('WELCOME-ROUTE'), findsNothing);
  });

  group(
    'onboarding: routing after sign-in waits for the saved preferences',
    () {
      /// Onboarding on a router, signed in through the device code once the
      /// test signs in, over [prefs].
      Future<void> mount(WidgetTester t, _MemoryPrefs prefs) async {
        final api = FakeBridgeApi(
          config: const ConfigInfo(relay: '', hasKey: false),
        )..accountPollStatus = 'authorized';
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
            overrides: [uiPrefsProvider.overrideWith(() => prefs)],
          ),
        );
        await t.pumpAndSettle();
      }

      Future<void> signIn(WidgetTester t) async {
        await t.tap(find.text('设备码登录'));
        await t.pump();
        await t.pump();
        await t.pump(const Duration(seconds: 6)); // the 5 s poll: authorized
        await t.pump();
        await t.pump();
      }

      testWidgets('the saved guide state decides, not an interim change', (
        t,
      ) async {
        final gate = Completer<void>();
        final prefs = _MemoryPrefs(const UiPrefs(guideSeen: true), gate);
        await mount(t, prefs);
        final container = ProviderScope.containerOf(
          t.element(find.byType(AccountOnboardingScreen)),
        );
        // A change made while the file is still being read lands on an
        // interim snapshot, which knows nothing of the guide.
        container.read(uiPrefsProvider.notifier).setLastService('pcx:d:app:x');
        expect(container.read(uiPrefsProvider).valueOrNull?.guideSeen, isFalse);

        await signIn(t);
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
        await mount(t, prefs);
        await signIn(t);
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

  testWidgets('onboarding: a cancelled browser sign-in guides to device code', (
    t,
  ) async {
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
        ],
        overrides: [
          webAuthenticatorProvider.overrideWithValue(
            FakeWebAuthenticator(
              '',
              error: PlatformException(code: 'CANCELED'),
            ),
          ),
        ],
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('使用 GitHub 登录'));
    await t.pumpAndSettle();
    // Cancelling the browser tab (e.g. after GitHub wouldn't load) does NOT
    // navigate; it surfaces guidance pointing at the reliable device-code path,
    // with that button still on screen.
    expect(find.text('HOME-ROUTE'), findsNothing);
    expect(
      find.textContaining('设备码'),
      findsWidgets,
    ); // guidance + button mention it
    expect(find.text('设备码登录'), findsOneWidget); // device-code fallback present
    expect(
      find.text('使用 GitHub 登录'),
      findsOneWidget,
    ); // can retry the browser too
  });

  testWidgets('onboarding: a browser sign-in that never returns also guides to '
      'the device code', (t) async {
    // Not every browser failure is a dismissal: the desktop loopback listener
    // can time out, and a redirect can land in a browser profile that isn't
    // signed in. Those used to surface as a raw transport error with no next
    // step, even though the remedy is the same as CANCELED's.
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
        ],
        overrides: [
          webAuthenticatorProvider.overrideWithValue(
            FakeWebAuthenticator('', error: StateError('listener timed out')),
          ),
        ],
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('使用 GitHub 登录'));
    await t.pumpAndSettle();

    expect(find.text('HOME-ROUTE'), findsNothing);
    // Leads with the remedy, and the device-code button is still reachable.
    expect(find.textContaining('设备码'), findsWidgets);
    expect(find.text('设备码登录'), findsOneWidget);
    // The cause is kept, so a real bug stays diagnosable from a screenshot.
    expect(find.textContaining('listener timed out'), findsOneWidget);
  });

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
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: '', hasKey: false),
    )..accountPollStatus = 'authorized';
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
          // Land on the real Settings screen: it is the visible symptom, and it
          // renders the identity only when the config says we're signed in.
          GoRoute(path: '/welcome', builder: (_, _) => const SettingsScreen()),
        ],
        overrides: [uiPrefsProvider.overrideWith(_MemoryPrefs.new)],
      ),
    );
    await t.pumpAndSettle();
    final container = ProviderScope.containerOf(
      t.element(find.byType(AccountOnboardingScreen)),
    );

    // Warm the config cache the way the real app does — reading it BEFORE the
    // login is what made the stale value stick.
    await container.read(configProvider.future);
    expect(container.read(configProvider).valueOrNull?.mode, 'unconfigured');

    await t.tap(find.text('设备码登录'));
    await t.pump();
    await t.pump();
    await t.pump(const Duration(seconds: 6));
    await t.pump();
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

    // Primary action = the FilledButton; the other stays available as a
    // TextButton, so neither platform loses a way in.
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
      expect(find.byType(TextButton), findsWidgets); // browser still offered
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }

    // The harness reports android, which is the mobile default.
    await mount();
    expect(primaryLabel(), '使用 GitHub 登录'); // accountSignInButton
  });

  testWidgets('List loading skeleton renders a shimmer', (t) async {
    await t.pumpWidget(
      const MaterialApp(home: Scaffold(body: ListLoadingSkeleton(rows: 2))),
    );
    await t.pump(); // shimmer animates forever — don't settle
    expect(find.byType(Shimmer), findsOneWidget);
    expect(find.byType(SkeletonBox), findsWidgets);
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
