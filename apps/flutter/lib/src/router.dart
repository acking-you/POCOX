import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:go_router/go_router.dart';
import 'package:pocox/src/screens/app_session_screen.dart';
import 'package:pocox/src/screens/codex_setup_screen.dart';
import 'package:pocox/src/screens/home_screen.dart';
import 'package:pocox/src/screens/local_session_view_screen.dart';
import 'package:pocox/src/screens/account_onboarding_screen.dart';
import 'package:pocox/src/screens/local_sessions_screen.dart';
import 'package:pocox/src/screens/log_view_screen.dart';
import 'package:pocox/src/screens/onboarding_screen.dart';
import 'package:pocox/src/screens/services_screen.dart';
import 'package:pocox/src/screens/settings_screen.dart';
import 'package:pocox/src/screens/welcome_guide_screen.dart';
import 'package:pocox/src/tools/galaxy/galaxy_screen.dart';
import 'package:pocox/src/tools/preview_browser.dart';

/// The live router instance, captured by [buildRouter] so code outside the
/// widget tree — namely the desktop tray's "Settings" item — can navigate. Null
/// until the app has built its router (so [openSettingsFromTray] is a no-op
/// before then).
GoRouter? _appRouter;

/// Test-only: point [openSettingsFromTray] at [router] (null to clear).
///
/// The tray reaches navigation through a module-level router because it fires
/// from outside the widget tree and has no BuildContext. That is exactly what
/// makes its decision — push over the chat, replace over a peer — otherwise
/// unreachable from a widget test.
@visibleForTesting
void debugSetAppRouterForTesting([GoRouter? router]) => _appRouter = router;

/// Open the settings screen from outside the widget tree (the desktop tray).
/// Safe to call before the router exists (no-op) and needs no BuildContext.
///
/// Uses `push`, not `go`, so compact layouts retain their conventional back
/// path. Wide desktop settings has its explicit Conversation origin button,
/// while mobile still relies on the pushed route's implied back button.
///
/// Pushing only ever happens over the conversation. Over ANOTHER utility page it
/// replaces instead, matching how the page menu swaps siblings: pushing there
/// left the tray route stacked on a peer, and the menu's next swap would replace
/// only the top one — so Logs → tray Settings → Logs kept two `LogViewScreen`
/// states alive, each with its own log-stream subscription.
void openSettingsFromTray() {
  final router = _appRouter;
  if (router == null) return;
  // The TOP of the stack, not `currentConfiguration.uri.path` — that reports the
  // base location and stays `/` after a push, so the guard below never fired and
  // repeated tray clicks did stack Settings.
  final matches = router.routerDelegate.currentConfiguration.matches;
  final top = matches.isEmpty ? '/' : matches.last.matchedLocation;
  if (top == '/settings') return;
  if (top == '/') {
    router.push('/settings');
  } else {
    // Over another utility page, take its slot rather than stacking on a peer:
    // the page menu's next sibling swap would replace only the top route, so
    // Logs → tray Settings → Logs left two `LogViewScreen`s alive, each holding
    // its own log-stream subscription.
    router.pushReplacement('/settings');
  }
}

/// Push [location] from outside a page's own context (the agent tools'
/// app-wide prompts open shares this way). A no-op before the router exists.
void pushRoute(String location) => _appRouter?.push(location);

/// Build the app router. [initialLocation] is `/onboarding` on first run
/// (no relay configured) and `/` otherwise.
GoRouter buildRouter({
  required String initialLocation,
}) => _appRouter = GoRouter(
  initialLocation: initialLocation,
  routes: [
    // Account login is the default onboarding; self-host is the advanced path.
    GoRoute(
      path: '/onboarding',
      builder: (c, s) => AccountOnboardingScreen(
        sessionExpired: s.uri.queryParameters['reason'] == 'session-expired',
      ),
    ),
    GoRoute(
      path: '/onboarding/self-host',
      builder: (c, s) => const OnboardingScreen(),
    ),
    // Chat-first home: resolves an app service + the latest conversation and
    // lands the user directly in the chat. All management moved to /manage.
    GoRoute(path: '/', builder: (c, s) => const HomeScreen()),
    // First-run welcome guide, shown once per device after the first sign-in.
    GoRoute(path: '/welcome', builder: (c, s) => const WelcomeGuideScreen()),
    GoRoute(path: '/manage', builder: (c, s) => const ServicesScreen()),
    // Every device and service as a living galaxy.
    GoRoute(path: '/galaxy', builder: (c, s) => const GalaxyScreen()),
    // A page another device shared, in the in-app browser (phones).
    GoRoute(
      path: '/preview',
      builder: (c, s) => PreviewBrowserScreen(
        url: s.uri.queryParameters['url'] ?? 'about:blank',
        title: s.uri.queryParameters['title'],
        serviceKey: s.uri.queryParameters['svc'],
      ),
    ),
    GoRoute(path: '/settings', builder: (c, s) => const SettingsScreen()),
    // External Codex setup: detect CODEX_HOME, configure login/provider and prompt.
    GoRoute(path: '/setup/codex', builder: (c, s) => const CodexSetupScreen()),
    GoRoute(path: '/logs', builder: (c, s) => const LogViewScreen()),
    // Session browser: no param = this machine's CODEX_HOME; ?svc=<key> = the
    // host behind that app service, read over its meta tunnel.
    GoRoute(
      path: '/sessions',
      builder: (c, s) {
        final svc = s.uri.queryParameters['svc'];
        return LocalSessionsScreen(
          source: (svc == null || svc.isEmpty)
              ? SessionSource.local(
                  provider: s.uri.queryParameters['provider'] ?? 'codex',
                )
              : SessionSource.remote(svc),
        );
      },
    ),
    GoRoute(
      path: '/sessions/view',
      builder: (c, s) => LocalSessionViewScreen(
        threadId: s.uri.queryParameters['tid']!,
        provider: s.uri.queryParameters['provider'] ?? 'codex',
        cwd: s.uri.queryParameters['cwd'],
        preview: s.uri.queryParameters['preview'],
        serviceKey: s.uri.queryParameters['svc'],
        guardian: s.uri.queryParameters['guardian'] == 'true',
        parentThreadId: s.uri.queryParameters['parent'],
      ),
    ),
    // A conversation on a specific service. Reached from the session browser's
    // resume; the chat-first home renders the same screen at `/` instead of
    // pushing here, and there is no longer a `/app/:key` project picker above
    // it — the home sidebar already lists every project and conversation.
    GoRoute(
      path: '/app/:key/session',
      builder: (c, s) => AppSessionScreen(
        serviceKey: s.pathParameters['key']!,
        threadId: s.uri.queryParameters['tid'],
        cwd: s.uri.queryParameters['cwd'],
      ),
    ),
  ],
);
