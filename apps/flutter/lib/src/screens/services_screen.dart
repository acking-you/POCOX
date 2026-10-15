import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/managed/device_management_switch.dart';
import 'package:pocket_codex/src/managed/managed_device_panel.dart';
import 'package:pocket_codex/src/managed/managed_providers.dart';
import 'package:pocket_codex/src/dismissed_services.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/text_measure.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/api_service_panel.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:pocket_codex/src/widgets/github_avatar.dart';
import 'package:pocket_codex/src/widgets/group_card.dart';
import 'package:pocket_codex/src/widgets/icon_badge.dart';
import 'package:pocket_codex/src/widgets/loading.dart';
import 'package:pocket_codex/src/widgets/local_host_dialog.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';
import 'package:pocket_codex/src/widgets/provider_badge.dart';
import 'package:pocket_codex/src/widgets/status_dots.dart';
import 'package:pocket_codex/src/widgets/utility_page.dart';

part 'services/capability_actions.dart';
part 'services/device_browser.dart';
part 'services/device_widgets.dart';
part 'services/local_hosts.dart';

/// Management hub (`/manage`): lists discovered services on the configured
/// relay, plus the Sessions browser and desktop local hosting. The chat-first
/// [HomeScreen] replaced it at `/`; everything here is one tap away from the
/// chat sidebar.
class ServicesScreen extends ConsumerStatefulWidget {
  /// Default constructor.
  const ServicesScreen({super.key});

  @override
  ConsumerState<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends ConsumerState<ServicesScreen>
    with WidgetsBindingObserver {
  /// Cadence for re-probing every app-server's reachability so a server that
  /// came back online flips from "unreachable" to "online" on its own — the
  /// manual refresh button stays as a fallback. Kept in the same order of
  /// magnitude as the session keepalive while staying gentle enough to avoid
  /// probe churn against the remote app-server.
  static const _reprobeInterval = Duration(seconds: 15);

  Timer? _reprobeTimer;
  String? _selectedDevice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reprobeTimer = Timer.periodic(_reprobeInterval, (_) {
      // Re-run discovery AND re-probe each service's reachability. Discovery
      // (a single /v1/services call) is refreshed too because the desktop
      // auto-hosts on startup — the initial listing is fetched before the
      // host finishes registering, so without a periodic re-fetch the page
      // stays empty even though the services are live on the relay.
      if (mounted) _refreshServices();
    });
    // Discovery may be cached stale (fetched before the desktop finished
    // auto-hosting), so refresh it once immediately on open instead of waiting
    // for the first periodic tick.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(servicesProvider);
    });
  }

  @override
  void dispose() {
    _reprobeTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the foreground: re-probe once immediately so a server that
    // recovered while we were backgrounded shows online without waiting a tick.
    if (state == AppLifecycleState.resumed && mounted) {
      _refreshServices();
    }
  }

  void _refreshServices({bool subscriptions = false}) {
    ref.invalidate(servicesProvider);
    if (subscriptions) ref.invalidate(subscriptionsProvider);
    ref.invalidate(appReachableProvider);
    ref.invalidate(apiReachableProvider);
    ref.invalidate(appReachableLocalProvider);
    ref.invalidate(apiReachableLocalProvider);
    ref.invalidate(localServeListProvider);
    // Reads only: a stopped service is never restarted by a refresh.
    ref.invalidate(managedDeviceProvider);
    ref.invalidate(deviceManagementProvider);
    ref.invalidate(hostRestoreProblemProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final servicesAsync = ref.watch(servicesProvider);
    final config = ref.watch(configProvider).valueOrNull;
    final account = config?.mode == 'account';

    return UtilityPage(
      route: '/manage',
      title: l10n.manageServices,
      actions: [
        IconButton(
          key: const Key('refresh-btn'),
          icon: const Icon(Icons.refresh),
          tooltip: l10n.refreshServices,
          // Re-discover services, re-read subscription health, and re-probe
          // every app-server's backend reachability, then rebuild so each
          // status re-evaluates.
          onPressed: () => _refreshServices(subscriptions: true),
        ),
      ],
      // Always on desktop, whatever is selected, loading or failed: hosting
      // must never hide behind selecting this machine's device tile (with a
      // remote peer selected, or discovery down, the local hosting card is
      // not on screen). Hosting publishes the same way in self-host and
      // account mode, so only the platform gates it.
      primaryAction: _hostingSupported
          ? UtilityPrimaryAction(
              key: const Key('host-this-device-btn'),
              icon: Icons.add,
              label: l10n.servicesHostThisDevice,
              onPressed: () => showHostingEditor(context),
            )
          : null,
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: servicesAsync.when(
          loading: () =>
              const ListLoadingSkeleton(key: ValueKey('svc-loading')),
          error: (e, _) {
            final detail = friendlyError(e);
            final sessionExpired = isAccountSessionExpired(detail);
            return KeyedSubtree(
              key: const ValueKey('svc-error'),
              child: _ErrorState(
                detail: detail,
                sessionExpired: sessionExpired,
                onRetry: () => ref.invalidate(servicesProvider),
                onSignIn: sessionExpired
                    ? () => context.go('/onboarding?reason=session-expired')
                    : null,
              ),
            );
          },
          data: (services) => KeyedSubtree(
            key: const ValueKey('svc-data'),
            child: _DeviceFirstServices(
              services: services,
              relay: config?.relay,
              accountLogin: account ? config?.accountLogin : null,
              accountId: account ? config?.accountId : null,
              selectedDevice: _selectedDevice,
              onSelectDevice: (device) {
                if (_selectedDevice != device) {
                  setState(() => _selectedDevice = device);
                }
              },
              onClearDevice: () {
                if (_selectedDevice != null) {
                  setState(() => _selectedDevice = null);
                }
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.detail,
    required this.sessionExpired,
    required this.onRetry,
    this.onSignIn,
  });

  /// Raw engine error string, shown only for retryable failures.
  final String detail;
  final bool sessionExpired;
  final VoidCallback onRetry;
  final VoidCallback? onSignIn;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            sessionExpired
                ? l10n.accountSessionExpiredTitle
                : l10n.discoverFailed,
            key: const Key('services-error'),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              sessionExpired ? l10n.accountSessionExpiredMessage : detail,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 12),
          if (sessionExpired)
            FilledButton.icon(
              key: const Key('services-sign-in-again'),
              onPressed: onSignIn,
              icon: const Icon(Icons.login),
              label: Text(l10n.accountSignInAgain),
            )
          else
            FilledButton(onPressed: onRetry, child: Text(l10n.retry)),
        ],
      ),
    );
  }
}
