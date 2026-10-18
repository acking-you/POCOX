import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/managed/default_project_tile.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/service_key.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/ui_prefs.dart';
import 'package:pocket_codex/src/widgets/brand_logo.dart';
import 'package:pocket_codex/src/widgets/links.dart';
import 'package:pocket_codex/src/widgets/local_host_dialog.dart';
import 'package:pocket_codex/src/widgets/status_dots.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';

/// First-run welcome guide, shown once per device right after the first
/// account sign-in (`/welcome`; gated by [UiPrefs.guideSeen]).
///
/// Desktop: a focused two-step setup — one-click local hosting (the prefilled
/// hosting dialog) and the optional project-folders configuration — so the
/// machine is chattable and phone-reachable before the user ever sees the
/// chat. Mobile: the three things to do on the computer, with a live "host
/// found" check so the user knows the moment their desktop comes online.
class WelcomeGuideScreen extends ConsumerStatefulWidget {
  /// Default constructor.
  const WelcomeGuideScreen({super.key});

  @override
  ConsumerState<WelcomeGuideScreen> createState() => _WelcomeGuideScreenState();
}

class _WelcomeGuideScreenState extends ConsumerState<WelcomeGuideScreen> {
  /// Mobile: re-discover this often so the "host found" check flips on its
  /// own the moment the desktop finishes its one-click setup.
  static const _detectInterval = Duration(seconds: 5);

  Timer? _detectTimer;

  @override
  void initState() {
    super.initState();
    // The guide is once-per-device: mark it seen as soon as it renders
    // (deferred — provider writes are not allowed while the tree builds).
    Future.microtask(() {
      if (mounted) ref.read(uiPrefsProvider.notifier).markGuideSeen();
    });
    if (!isDesktop) {
      _detectTimer = Timer.periodic(_detectInterval, (_) {
        if (mounted) ref.invalidate(servicesProvider);
      });
    }
  }

  @override
  void dispose() {
    _detectTimer?.cancel();
    super.dispose();
  }

  void _enterChat() => context.go('/');

  Future<void> _startHosting() async {
    await showHostingEditor(context);
    if (!mounted) return;
    ref.invalidate(localServeListProvider);
    ref.invalidate(servicesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              const Center(child: BrandLogo(size: 64)),
              const SizedBox(height: 16),
              BrandHeadline(
                l10n.welcomeTitle,
                key: const Key('welcome-title'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                isDesktop
                    ? l10n.welcomeSubtitleDesktop
                    : l10n.welcomeSubtitleMobile,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (isDesktop) ..._desktopSteps(l10n, scheme),
              if (!isDesktop) ..._mobileSteps(l10n, scheme),
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('welcome-enter-btn'),
                onPressed: _enterChat,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
                child: Text(l10n.welcomeEnterChat),
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  key: const Key('welcome-skip-btn'),
                  onPressed: _enterChat,
                  child: Text(l10n.welcomeSkip),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Desktop: one-click hosting + project folders -------------------------

  List<Widget> _desktopSteps(AppLocalizations l10n, ColorScheme scheme) {
    final hosts =
        ref.watch(localServeListProvider).valueOrNull ??
        const <AppServeStatus>[];
    final host = hosts.isEmpty ? null : hosts.first;
    return [
      _stepCard(
        scheme: scheme,
        number: 1,
        done: host != null,
        title: l10n.welcomeStepHost,
        description: l10n.welcomeStepHostDesc,
        child: host == null
            ? Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const Key('welcome-start-hosting-btn'),
                  onPressed: _startHosting,
                  icon: const Icon(AppIcons.rocket_launch_outlined, size: 18),
                  label: Text(l10n.startHosting),
                ),
              )
            : Row(
                children: [
                  StatusChip(
                    color: successColor(scheme),
                    label: l10n.welcomeHostRunning,
                    filled: true,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${deviceLabel(host.device)} · ${host.name}',
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
      ),
      const SizedBox(height: 12),
      _stepCard(
        scheme: scheme,
        number: 2,
        done: false,
        title: l10n.welcomeStepFolders,
        description: l10n.welcomeStepFoldersDesc,
        child: host == null
            ? Text(
                l10n.welcomeFoldersLocked,
                key: const Key('welcome-folders-locked'),
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              )
            : DefaultProjectTile(serviceKey: host.appServiceKey, local: true),
      ),
      const SizedBox(height: 12),
      // Step 3: 配置 codex 的模型访问 (provider / 官方登录) + 非降智 prompt。
      // 若 CODEX_HOME 缺少凭证或自定义 provider,codex 无法发起模型调用。
      _stepCard(
        scheme: scheme,
        number: 3,
        done: false,
        title: l10n.codexSetupStepTitle,
        description: l10n.codexSetupStepDesc,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('welcome-codex-setup-btn'),
            onPressed: () => context.push('/setup/codex'),
            icon: const Icon(AppIcons.tune, size: 18),
            label: Text(l10n.codexSetup),
          ),
        ),
      ),
    ];
  }

  // --- Mobile: what to do on the computer + live host detection -------------

  List<Widget> _mobileSteps(AppLocalizations l10n, ColorScheme scheme) {
    final services =
        ref.watch(servicesProvider).valueOrNull ?? const <ServiceEntry>[];
    final found = services.where((s) => isSessionKind(s.kind)).toList();
    return [
      _stepCard(
        scheme: scheme,
        number: 1,
        done: false,
        title: l10n.welcomeMobileStep1,
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('welcome-download-btn'),
            onPressed: () => openUrl(
              context,
              'https://github.com/acking-you/pocket-codex/releases/latest',
            ),
            icon: const Icon(AppIcons.download_outlined, size: 18),
            label: Text(l10n.welcomeDownloadDesktop),
          ),
        ),
      ),
      const SizedBox(height: 12),
      _stepCard(
        scheme: scheme,
        number: 2,
        done: false,
        title: l10n.welcomeMobileStep2,
      ),
      const SizedBox(height: 12),
      _stepCard(
        scheme: scheme,
        number: 3,
        done: found.isNotEmpty,
        title: l10n.welcomeMobileStep3,
        child: found.isEmpty
            ? Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.welcomeWaitingHost,
                      key: const Key('welcome-waiting-host'),
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              )
            : StatusChip(
                color: successColor(scheme),
                label: l10n.welcomeHostFound(serviceKeyLabel(found.first.key)),
                filled: true,
                wrap: true,
              ),
      ),
    ];
  }

  /// One numbered step card: circle number (✓ once [done]), title,
  /// optional description, optional body [child].
  Widget _stepCard({
    required ColorScheme scheme,
    required int number,
    required bool done,
    required String title,
    String? description,
    Widget? child,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      // A done step says so with its green check and a faint wash, not a
      // heavy outline.
      decoration: BoxDecoration(
        color: done
            ? Color.alphaBlend(
                successColor(scheme).withValues(alpha: 0.07),
                cardFill(scheme),
              )
            : cardFill(scheme),
        borderRadius: BorderRadius.circular(kCardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: done ? successColor(scheme) : scheme.primary,
                child: done
                    ? const Icon(AppIcons.check, size: 16, color: Colors.white)
                    : Text(
                        '$number',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onPrimary,
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: Text(description, style: helpTextStyle(Theme.of(context))),
            ),
          ],
          if (child != null) ...[
            const SizedBox(height: 10),
            Padding(padding: const EdgeInsets.only(left: 36), child: child),
          ],
        ],
      ),
    );
  }
}
