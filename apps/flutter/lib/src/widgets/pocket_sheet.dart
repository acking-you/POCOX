import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/network/connection_paths.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/service_key.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/theme_transition.dart';
import 'package:pocox/src/ui_prefs.dart';
import 'package:pocox/src/updates/update_controller.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';
import 'package:pocox/src/widgets/github_avatar.dart';
import 'package:pocox/src/widgets/icon_badge.dart';
import 'package:pocox/src/widgets/layered_navigation.dart';
import 'package:pocox/src/widgets/status_dots.dart';
import 'package:pocox/src/widgets/workspace_navigation.dart';

/// The name of an appearance choice: [mode] as `ui_prefs` keeps it.
String appearanceLabel(AppLocalizations l10n, String? mode) => switch (mode) {
  'light' => l10n.appearanceLight,
  'dark' => l10n.appearanceDark,
  _ => l10n.appearanceSystem,
};

/// Ask which appearance to use, then switch it from where the choice was made.
Future<void> pickAppearance(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context);
  final current = ref.read(uiPrefsProvider).valueOrNull?.themeMode ?? 'system';
  // Read now: [ref] may belong to a Pocket that closes before the choice is made.
  final prefs = ref.read(uiPrefsProvider.notifier);
  final choice = await showChoicePanel<String>(
    context: context,
    title: l10n.appearance,
    current: current,
    choices: [
      ('system', l10n.appearanceSystem),
      ('light', l10n.appearanceLight),
      ('dark', l10n.appearanceDark),
    ],
  );
  if (choice == null || choice == current || !context.mounted) return;
  // Let the panel finish closing, so the frame the switch reveals over is the
  // page itself.
  await Future<void>.delayed(const Duration(milliseconds: 260));
  if (!context.mounted) return;
  ThemeTransition.run(
    context,
    () => prefs.setThemeMode(choice == 'system' ? null : choice),
  );
}

/// Open the Pocket: on a compact window the one way to every secondary page.
/// [section] is the page it opens from.
Future<void> showPocket(BuildContext context, {required String section}) =>
    showAdaptivePanel<void>(
      context: context,
      insetTop: false,
      builder: (sheet) => _Pocket(
        section: section,
        page: context,
        close: () => Navigator.of(sheet).pop(),
      ),
    );

/// The account or relay this device is on.
class PocketIdentity extends ConsumerWidget {
  /// Creates the identity; [size] is the picture's side.
  const PocketIdentity({super.key, this.size = 40, this.subtitle = true});

  /// The picture's side.
  final double size;

  /// Show what kind of identity it is under its name.
  final bool subtitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final config = ref.watch(configProvider).valueOrNull;
    final account = config?.mode == 'account';
    final relay = config?.relay?.trim() ?? '';
    final name = account
        ? '@${config?.accountLogin ?? ''}'
        : relay.isEmpty
        ? l10n.notConfigured
        : relay;
    return Row(
      children: [
        if (account)
          GitHubAvatar(
            accountId: config?.accountId,
            fallbackIcon: AppIcons.person_outline,
            size: size,
          )
        else
          IconBadge(icon: AppIcons.server, size: size),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: subtitle
                    ? theme.textTheme.titleMedium
                    : theme.textTheme.bodyMedium,
              ),
              if (subtitle)
                Text(
                  account ? l10n.githubAccount : l10n.settingsRelay,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Pocket extends ConsumerWidget {
  const _Pocket({
    required this.section,
    required this.page,
    required this.close,
  });

  final String section;

  /// The page behind the sheet, which navigates once it has closed.
  final BuildContext page;
  final VoidCallback close;

  void _open(String route) {
    close();
    if (!page.mounted) return;
    final nav = LayeredNavigation.maybeOf(page);
    if (nav?.isOpen ?? false) nav!.close();
    openWorkspaceRoute(page, section, route);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final tiles = <Widget>[
      for (final destination in currentDestinations(ref, l10n))
        if (destination.section != '/')
          _PocketTile(
            key: Key('pocket-tile-${destination.section}'),
            icon: destination.icon,
            label: destination.label,
            state: switch (destination.section) {
              '/manage' => const _DevicesOnline(),
              '/galaxy' => const _LiveLinks(),
              '/sessions' => _CurrentHost(route: destination.route),
              '/settings' => const _UpdateAvailable(),
              _ => null,
            },
            onTap: () => _open(destination.route),
          ),
      _PocketTile(
        key: const Key('pocket-tile-appearance'),
        icon: AppIcons.dark_mode_outlined,
        label: l10n.appearance,
        state: Text(
          appearanceLabel(
            l10n,
            ref.watch(
              uiPrefsProvider.select((prefs) => prefs.valueOrNull?.themeMode),
            ),
          ),
        ),
        onTap: () {
          close();
          // Over the page, once the sheet has gone: the switch reveals it.
          if (page.mounted) pickAppearance(page, ref);
        },
      ),
    ];
    return Padding(
      key: const Key('pocket-sheet'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 14),
            child: PocketIdentity(),
          ),
          LayoutBuilder(
            builder: (context, box) {
              // One column when large text would crowd two beside each other.
              final textScale = MediaQuery.textScalerOf(context).scale(1);
              final columns = box.maxWidth / textScale >= 300 ? 2 : 1;
              const gap = 10.0;
              return Column(
                children: [
                  for (var i = 0; i < tiles.length; i += columns)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : gap),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: tiles[i]),
                            if (columns == 2) ...[
                              const SizedBox(width: gap),
                              Expanded(
                                // An odd tile out keeps its share of the row.
                                child: i + 1 < tiles.length
                                    ? tiles[i + 1]
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// One destination of the Pocket: its glyph at the top, its name at the foot,
/// and a state line under the name only while there is state to report.
class _PocketTile extends StatelessWidget {
  const _PocketTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.state,
  });

  final IconData icon;
  final String label;
  final Widget? state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const radius = BorderRadius.all(Radius.circular(kCardRadius));
    return Material(
      color: floatingTile(scheme),
      borderRadius: radius,
      child: InkWell(
        mouseCursor: clickable,
        borderRadius: radius,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 96),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, size: 22, color: scheme.onSurface),
                const SizedBox(height: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (state case final state?)
                      DefaultTextStyle.merge(
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurfaceVariant,
                        ),
                        child: state,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A state line led by a dot.
class _DotLine extends StatelessWidget {
  const _DotLine({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      StatusDot(color: color, size: 7),
      const SizedBox(width: 6),
      Expanded(child: Text(text)),
    ],
  );
}

/// How many devices the relay lists. Nothing until it has listed some: a
/// count of devices is never made up.
class _DevicesOnline extends ConsumerWidget {
  const _DevicesOnline();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final services = ref.watch(discoveredServicesProvider);
    if (services == null || services.isEmpty) return const SizedBox.shrink();
    final devices = {
      for (final service in services) serviceDeviceIdentity(service.key),
    };
    return _DotLine(
      color: successColor(Theme.of(context).colorScheme),
      text: AppLocalizations.of(context).pocketDevicesOnline(devices.length),
    );
  }
}

/// How many subscriptions are up on this device right now.
class _LiveLinks extends ConsumerWidget {
  const _LiveLinks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alive = ref.watch(
      liveSubscriptionsProvider.select(
        (subs) => subs.valueOrNull?.where((sub) => sub.alive).length ?? 0,
      ),
    );
    if (alive == 0) return const SizedBox.shrink();
    return Text(AppLocalizations.of(context).pocketLiveLinks(alive));
  }
}

/// The host whose history the destination opens; none for this computer's own.
class _CurrentHost extends StatelessWidget {
  const _CurrentHost({required this.route});

  final String route;

  @override
  Widget build(BuildContext context) {
    final service = Uri.parse(route).queryParameters['svc'];
    if (service == null) return const SizedBox.shrink();
    return Text(deviceLabel(serviceKeyDevice(service)));
  }
}

/// A newer release is on offer. Ink rather than the signal: blue is for what
/// is live.
class _UpdateAvailable extends ConsumerWidget {
  const _UpdateAvailable();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(updateStateProvider).valueOrNull ??
        ref.read(updateApiProvider).updateState();
    if (!state.newer) return const SizedBox.shrink();
    return _DotLine(
      color: Theme.of(context).colorScheme.onSurface,
      text: AppLocalizations.of(context).pocketUpdateAvailable,
    );
  }
}

/// The compact bar's title: its name and a chevron, opening the Pocket.
class PocketTitle extends StatelessWidget {
  /// Creates the title of the page in [section].
  const PocketTitle({super.key, required this.section, required this.title});

  /// The section it opens from.
  final String section;

  /// The page's name.
  final String title;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '$title, ${l10n.utilitySwitchPage}',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const Key('pocket-title'),
          mouseCursor: clickable,
          borderRadius: BorderRadius.circular(kControlRadius),
          onTap: () => showPocket(context, section: section),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  AppIcons.expand_more,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An icon that opens the Pocket, for a bar with no page title to carry it.
class PocketButton extends StatelessWidget {
  /// Creates the button for the page in [section].
  const PocketButton({super.key, required this.section});

  /// The section it opens from.
  final String section;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('pocket-btn'),
    tooltip: AppLocalizations.of(context).utilitySwitchPage,
    icon: const Icon(AppIcons.layout_grid),
    onPressed: () => showPocket(context, section: section),
  );
}
