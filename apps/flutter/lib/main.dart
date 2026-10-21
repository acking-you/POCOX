import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api_rust.dart';
import 'package:pocox/src/desktop_tray.dart';
import 'package:pocox/src/log_manager.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/quit_status.dart';
import 'package:pocox/src/router.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/theme_transition.dart';
import 'package:pocox/src/tools/tools_host.dart';
import 'package:pocox/src/ui_prefs.dart';
import 'package:pocox/src/updates/update_host.dart';
import 'package:pocox/src/widgets/popover.dart';
import 'package:pocox/src/rust/api/bridge.dart' as frb;
import 'package:pocox/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Popovers open from the control that was pressed (see popover.dart).
  PopoverAnchor.install();

  // A transient bridge error must never take down the whole app. Uncaught async
  // errors (e.g. a host dropping mid-session, or any stream-setup error that
  // flutter_rust_bridge delivers on an unawaited Future) reach the platform
  // dispatcher unhandled, which is fatal on desktop. Log and swallow them — the
  // affected screen already surfaces its own error / reconnect UI.
  PlatformDispatcher.instance.onError = (error, stack) {
    // Without the frames from our own code, a framework assertion logged here
    // cannot be traced back to the call that tripped it.
    final frames = stack.toString().split('\n');
    final mine = frames.where((l) => l.contains('package:pocox/'));
    // Framework-only stacks (a selection auto-scroll, say) still name the
    // widget that started it in their first frames.
    final ours = (mine.isEmpty ? frames : mine).take(6).join('\n');
    debugPrint(
      'Uncaught async error (ignored, app kept alive): $error'
      '${ours.isEmpty ? '' : '\n$ours'}',
    );
    return true;
  };

  // Web is unsupported: the browser sandbox has no path_provider support dir
  // and no raw TCP, so the bridge (config.toml persistence + pb-mapper
  // subscribe) cannot run. Render an explicit notice instead of crashing on
  // getApplicationSupportDirectory() or showing a blank page.
  if (kIsWeb) {
    runApp(const _UnsupportedPlatformApp());
    return;
  }

  await RustLib.init();
  final dir = await getApplicationSupportDirectory();
  await frb.initBridge(supportDir: dir.path);

  // Start buffering the bridge's runtime logs as early as possible (right after
  // init_bridge installs the tracing layer) so the in-app log viewer shows
  // history from boot even when opened later.
  LogManager.instance.initialize(const RustBridgeApi());

  // Framework errors also go to the exportable log. One failure can leave
  // framework state broken so that every later frame fails the same way; only
  // the first report names the cause, and an attached tool's structured
  // errors are the console's only other copy.
  final present = FlutterError.onError;
  FlutterError.onError = (details) {
    // The innermost frames say what failed, ours which widget got there.
    final frames = (details.stack?.toString() ?? '').split('\n');
    final mine = frames.skip(4).where((l) => l.contains('package:pocox/'));
    LogManager.instance.record(
      'flutter',
      [
        details.exceptionAsString().split('\n').first,
        ...frames.take(4),
        ...mine.take(6),
      ].join('\n'),
      level: 'ERROR',
    );
    present?.call(details);
  };

  // Desktop only: bring up the system tray and make the window close-to-tray.
  // No-op on mobile (DesktopTray.init guards on the platform). The menu labels
  // are filled in once the app builds (see the MaterialApp.router builder).
  await DesktopTray.instance.init(onOpenSettings: openSettingsFromTray);

  final cfg = await frb.getConfig();
  // Three-way boot: an account session or a self-host relay → home; neither
  // (first run) → the account onboarding screen.
  final start = cfg.mode == 'unconfigured' ? '/onboarding' : '/';
  // Seed the locale provider from the persisted config (read in this same
  // bridge call — no extra latency, no language flash). null = follow system.
  final locale = cfg.locale == null ? null : Locale(cfg.locale!);
  runApp(
    ProviderScope(
      overrides: [localeProvider.overrideWith((ref) => locale)],
      child: PocoxApp(initialLocation: start),
    ),
  );
}

/// Shown on the web target, which the engine does not support. Localized so
/// the notice respects the system language.
class _UnsupportedPlatformApp extends StatelessWidget {
  const _UnsupportedPlatformApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      theme: lightTheme(),
      darkTheme: darkTheme(),
      themeMode: ThemeMode.system,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) => Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                AppLocalizations.of(context).webUnsupported,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Root app: Material 3 light/dark (user-selectable in settings, following
/// the system by default), go_router nav, locale driven by [localeProvider].
class PocoxApp extends ConsumerStatefulWidget {
  /// [initialLocation] decides onboarding vs services on cold start.
  const PocoxApp({super.key, required this.initialLocation});

  /// Route to open on launch.
  final String initialLocation;

  @override
  ConsumerState<PocoxApp> createState() => _PocoxAppState();
}

class _PocoxAppState extends ConsumerState<PocoxApp>
    with WidgetsBindingObserver {
  // Built once so a locale change (which rebuilds this widget) does not
  // recreate the router and reset the navigation stack.
  late final _router = buildRouter(initialLocation: widget.initialLocation);

  // Built once too: a new ThemeData never equals the last one (its button
  // styles hold closures), and MaterialApp would re-theme the whole app on
  // every preference write — the sidebar toggling, a thread opening.
  ThemeData? _light;
  ThemeData? _dark;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void reassemble() {
    super.reassemble();
    _light = null;
    _dark = null;
  }

  @override
  void didChangePlatformBrightness() {
    final followsSystem =
        ref.read(uiPrefsProvider).valueOrNull?.themeMode == null;
    if (followsSystem) ThemeTransition.systemChange(context);
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(localeProvider);
    // Explicit light/dark from settings, follow-system by default. While the
    // prefs file is still loading, follow the system — a saved choice snaps in
    // one frame later, which beats blocking first paint on disk I/O.
    final themePref = ref.watch(uiPrefsProvider).valueOrNull?.themeMode;
    final themeMode = switch (themePref) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      theme: _light ??= lightTheme(),
      darkTheme: _dark ??= darkTheme(),
      themeMode: themeMode,
      // No lerp: ThemeTransition reveals the new theme over a frozen frame
      // of the old one, and a lerp underneath would flip brightness-chosen
      // colours halfway through it.
      themeAnimationDuration: Duration.zero,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // Keep the desktop tray menu in the active UI language. This builder runs
      // below Localizations, so AppLocalizations.of(context) resolves the
      // current locale; setMenu skips the platform call when nothing changed.
      builder: (context, child) {
        if (DesktopTray.supported) {
          final l10n = AppLocalizations.of(context);
          DesktopTray.instance.setMenu(
            TrayMenuLabels(
              show: l10n.trayShow,
              settings: l10n.settingsTitle,
              quit: l10n.trayQuit,
            ),
          );
        }
        // The light/dark switch captures this subtree; see ThemeTransition.
        // Agents' share requests and new shares appear above every page.
        // Updates are checked quietly and offered once per release.
        final page = ThemeTransitionHost(
          child: UpdateHost(
            child: ToolsHost(child: child ?? const SizedBox.shrink()),
          ),
        );
        if (!DesktopTray.supported) return page;
        // A quit in progress, or one that could not stop every hosted
        // service (the app then stays open), above every page.
        return Column(
          children: [
            QuitStatusBanner(
              status: DesktopTray.instance.quitStatus,
              onRetry: DesktopTray.instance.quit,
            ),
            Expanded(child: page),
          ],
        );
      },
      routerConfig: _router,
    );
  }
}
