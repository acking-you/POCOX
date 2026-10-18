/// What the user does with shares from any page: open one (connecting it to
/// this device first), copy its link, stop or keep it, answer an agent's
/// request.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/router.dart';
import 'package:pocket_codex/src/tools/share_ref.dart';
import 'package:pocket_codex/src/tools/tools_providers.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:url_launcher/url_launcher.dart';

export 'package:pocket_codex/src/tools/share_ref.dart';

/// The owner as the user reads it.
String ownerLabel(AppLocalizations l10n, ToolsOwner owner) =>
    owner.isAgent ? owner.label : l10n.toolsYou;

/// A port or share status in words.
String statusLabel(AppLocalizations l10n, String status) => switch (status) {
  'online' => l10n.toolsStatusOnline,
  'unreachable' => l10n.toolsStatusUnreachable,
  'refused' => l10n.toolsStatusRefused,
  'offline' => l10n.toolsStatusOffline,
  _ => l10n.toolsStatusStarting,
};

/// When a share ends, in words.
String endsLabel(AppLocalizations l10n, ToolsShare share) {
  final expires = share.expiresMs;
  if (expires == null) return l10n.toolsKept;
  final left = DateTime.fromMillisecondsSinceEpoch(
    expires,
  ).difference(DateTime.now());
  if (left.isNegative) return l10n.toolsEnded;
  final time = left.inHours >= 1
      ? l10n.toolsHours(left.inHours)
      : l10n.toolsMinutes(left.inMinutes);
  return l10n.toolsEndsIn(time);
}

/// Reads a provider (a [WidgetRef]'s or a container's `read`).
typedef ProviderRead = T Function<T>(ProviderListenable<T> provider);

/// Open a share: on this device directly, else connected here first. Phones
/// open it in the in-app browser, which keeps the tunnel alive; desktops use
/// the system browser.
Future<void> openShare(
  BuildContext context,
  WidgetRef ref,
  ShareRef share, {
  String? title,
}) => openShareWith(context, ref.read, share, title: title);

/// [openShare] for a caller holding a provider container rather than a ref.
Future<void> openShareWith(
  BuildContext context,
  ProviderRead read,
  ShareRef share, {
  String? title,
}) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ToastMessenger.of(context);
  final api = read(bridgeApiProvider);
  final overview = read(toolsOverviewProvider);
  final shared = overview.shareOfKey(share.service);
  try {
    int? port;
    if (share.device == overview.thisDevice) {
      port = share.port;
    } else {
      final connected = read(shareConnectionsProvider);
      var connection = overview.connectionTo(share.service);
      // An agent's connection ends with the agent: the user's own open takes
      // it over, so the page's tunnel lasts while it is open.
      if (connection == null || connection.owner.isAgent) {
        connection = await api.toolsConnect(share.service);
        connected[share.service] = share.device;
      }
      port = connection.localPort;
      if (!connection.samePort && share.port != null) {
        messenger.notice(
          l10n.toolsPortMoved(share.port.toString(), connection.local),
        );
      }
      // The page's other ports (its API) come along, at their own numbers,
      // before it opens: its first request may already need them.
      final failed = <String>[];
      Future<void> companion(ToolsPort other) async {
        try {
          final made = await api.toolsConnect(other.key);
          connected[other.key] = share.device;
          // At another number here, the page's absolute requests miss it.
          if (!made.samePort) failed.add(other.port.toString());
        } catch (_) {
          failed.add(other.port.toString());
        }
      }

      await Future.wait([
        for (final other in shared?.share.ports ?? const <ToolsPort>[])
          if (other.key != share.service &&
              overview.connectionTo(other.key)?.owner.isAgent != false)
            companion(other),
      ]);
      if (failed.isNotEmpty) {
        messenger.notice(l10n.toolsPortsNotConnected(failed.join(', ')));
      }
    }
    if (port == null) throw StateError('no local port');
    final url = '${share.scheme}://localhost:$port${share.path}';
    final name = title ?? shared?.share.title ?? share.title ?? url;
    if (isDesktop) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } else {
      pushRoute(
        Uri(
          path: '/preview',
          queryParameters: {'url': url, 'title': name, 'svc': share.service},
        ).toString(),
      );
    }
  } catch (error) {
    messenger.error(l10n.toolsOpenFailed(friendlyError(error)));
  }
}

/// Copy a share's `pocox://open` link.
Future<void> copyShareLink(BuildContext context, ShareRef share) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ToastMessenger.of(context);
  final link = Uri(
    scheme: 'pocox',
    host: 'open',
    queryParameters: {
      'service': share.service,
      'path': share.path,
      if (share.secure) 'scheme': 'https',
    },
  ).toString();
  await Clipboard.setData(ClipboardData(text: link));
  messenger.ok(l10n.toolsLinkCopied);
}

/// Stop a share, as the user.
Future<void> stopShare(
  BuildContext context,
  WidgetRef ref,
  String device,
  ToolsShare share,
) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ToastMessenger.of(context);
  try {
    await ref.read(bridgeApiProvider).toolsStopShare(device, share.id);
    messenger.ok(l10n.toolsStoppedToast(share.title));
  } catch (error) {
    messenger.error(friendlyError(error));
  }
}

/// Keep a share until the user stops it.
Future<void> keepShare(
  BuildContext context,
  WidgetRef ref,
  String device,
  ToolsShare share,
) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ToastMessenger.of(context);
  try {
    await ref.read(bridgeApiProvider).toolsKeepShare(device, share.id);
    messenger.ok(l10n.toolsKeptToast);
  } catch (error) {
    messenger.error(friendlyError(error));
  }
}

/// Answer an agent's request to share: `allow_once`, `allow_conversation`
/// or `deny`.
Future<bool> answerConsent(
  BuildContext context,
  WidgetRef ref,
  String device,
  ToolsConsent consent,
  String decision,
) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ToastMessenger.of(context);
  try {
    await ref.read(bridgeApiProvider).toolsAnswer(device, consent.id, decision);
    return true;
  } catch (error) {
    messenger.error(l10n.toolsAnswerFailed(friendlyError(error)));
    return false;
  }
}
