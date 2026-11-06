import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/error_format.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/app_dialog.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/widgets/icon_badge.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Full-size pills: these pages exist for their actions.
const pairingCta = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size.fromHeight(46)),
);

/// A pairing code's face: monospaced and spaced, since people read it aloud.
TextStyle pairingMono(
  BuildContext context,
  double size, {
  double tracking = 1.5,
  Color? color,
}) => TextStyle(
  fontFamily: monoFontFamily,
  fontFamilyFallback: monoCjkFallback,
  fontSize: size,
  letterSpacing: tracking,
  fontWeight: FontWeight.w600,
  color: color ?? Theme.of(context).colorScheme.onSurface,
);

/// What a refused or failed pairing call means to the user. Matches on the
/// failure's code, never its message, which is for logs.
String pairingErrorText(AppLocalizations l10n, Object error) {
  if (error is! PairingFailure) return friendlyError(error);
  return switch (error.code) {
    'code_unknown' || 'invalid_request' => l10n.pairingErrUnknownCode,
    'code_retired' => l10n.pairingErrRetired,
    'linking_paused' => l10n.pairingErrPaused,
    'own_code' => l10n.pairingErrOwnCode,
    'rate_limited' => l10n.pairingErrTooMany(
      ((error.retryAfterSecs ?? 60) / 60).ceil(),
    ),
    'preview_stale' || 'stale' => l10n.pairingErrStale,
    'already_linked' => l10n.pairingErrAlreadyLinked,
    'group_full' => l10n.pairingErrGroupFull,
    'transition_pending' => l10n.pairingErrPending,
    'relay_capacity' => l10n.pairingNoRoom,
    'pairing_disabled' => l10n.pairingTooOld,
    'pairing_client_upgrade_required' => l10n.pairingErrUpgrade,
    'relay_unavailable' ||
    'relay_state_lost' ||
    'relay_too_old' => l10n.pairingErrRelay,
    'device_superseded' || 'grace_restricted' => l10n.pairingSupersededTitle,
    'device_unknown' => l10n.pairingUnknownTitle,
    'device_not_activated' => l10n.pairingErrNotActivated,
    'not_found' => l10n.pairingErrNotFound,
    'operation_unknown' => l10n.pairingErrNotApplied,
    'restore_slots_full' => l10n.pairingErrSlotsFull,
    'signed_out' || 'no_device' => l10n.pairingErrNoDevice,
    _ => l10n.pairingErrUnreachable,
  };
}

/// Whether [error] says the backend could not be reached at all, as opposed
/// to refusing: the typed entry is kept and a retry offered.
bool pairingUnreachable(Object error) =>
    error is PairingFailure && error.code == 'failed';

/// A device's day of last activity, as people say it.
String pairingLastActive(AppLocalizations l10n, int day) {
  final today = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000;
  final days = today - day;
  if (days <= 0) return l10n.pairingToday;
  if (days == 1) return l10n.pairingYesterday;
  return l10n.pairingDaysAgo(days);
}

/// Whether a device was active today, which makes restoring onto it ask
/// again: it may be in use right now.
bool pairingActiveToday(int day) =>
    day >= DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000 - 1;

/// The picture for a device's platform label.
IconData pairingDeviceIcon(String? platform) => switch (platform) {
  'ios' || 'android' => AppIcons.smartphone,
  'macos' || 'windows' || 'linux' => AppIcons.computer_outlined,
  _ => AppIcons.laptop,
};

/// A small rounded label: this device, who joined, offline.
class PairingPill extends StatelessWidget {
  /// Creates a pill.
  const PairingPill(this.text, {super.key, this.tone});

  /// Its text.
  final String text;

  /// Its text color, when it says something urgent.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: tone ?? scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A pairing invitation as a QR code, always dark on white so every camera
/// reads it.
class PairingQr extends StatelessWidget {
  /// Creates the QR for [uri].
  const PairingQr({super.key, required this.uri, this.size = 88});

  /// `pocox://pair?c=<code>`.
  final String uri;

  /// Its side.
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    padding: EdgeInsets.all(size * 0.05),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(kControlRadius),
    ),
    child: QrImageView(
      data: uri,
      padding: EdgeInsets.zero,
      backgroundColor: Colors.white,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Color(0xFF1D1D1F),
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Color(0xFF1D1D1F),
      ),
      semanticsLabel: AppLocalizations.of(context).pairingQrLabel,
    ),
  );
}

/// Copy [code] and say so.
void copyPairingCode(BuildContext context, String code) {
  Clipboard.setData(ClipboardData(text: code));
  showToastOk(context, AppLocalizations.of(context).pairingCopied);
}

/// This device's code: the whole card copies it, with a QR beside it where
/// there is room. With no code, [placeholder] says why in place of one.
class PairingCodeCard extends StatelessWidget {
  /// Creates the card.
  const PairingCodeCard({
    super.key,
    this.code,
    this.qr = false,
    this.badge,
    this.placeholder,
    this.size = 23,
  });

  /// The code as people read it, and the QR's link.
  final PairingCode? code;

  /// Whether to show the QR beside it.
  final bool qr;

  /// A short state beside the label: who joined, offline.
  final Widget? badge;

  /// Why there is no code yet.
  final String? placeholder;

  /// The code's text size.
  final double size;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final code = this.code;
    final text = Row(
      children: [
        Expanded(
          child: Text(
            code?.code ?? '····-····-····',
            key: const Key('pairing-own-code'),
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: pairingMono(
              context,
              size,
              color: code == null ? onSurfaceMuted(scheme) : scheme.onSurface,
            ),
          ),
        ),
        if (code != null) ...[
          const SizedBox(width: 6),
          Icon(
            AppIcons.copy_outlined,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ],
    );
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.pairingThisCode,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    ?badge,
                  ],
                ),
                const SizedBox(height: 6),
                text,
                if (placeholder != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    placeholder!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (qr && code != null) ...[
            const SizedBox(width: 12),
            PairingQr(uri: code.uri, size: 72),
          ],
        ],
      ),
    );
    return Material(
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kPanelRadius),
        side: BorderSide(color: scheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: code == null
          ? body
          : Tooltip(
              message: l10n.copy,
              child: InkWell(
                key: const Key('pairing-copy-code'),
                mouseCursor: clickable,
                onTap: () => copyPairingCode(context, code.code),
                child: body,
              ),
            ),
    );
  }
}

/// Another device's code, typed or scanned. Case, spaces and dashes do not
/// matter; the backend reads it the same.
class PairingCodeField extends StatelessWidget {
  /// Creates the field.
  const PairingCodeField({
    super.key,
    required this.controller,
    this.label,
    this.error,
    this.onScan,
    this.onSubmitted,
    this.enabled = true,
    this.autofocus = false,
  });

  /// Its text.
  final TextEditingController controller;

  /// Its label; another device's code by default.
  final String? label;

  /// What went wrong with the last try.
  final String? error;

  /// Opens the scanner, where there is a camera.
  final VoidCallback? onScan;

  /// Submits it.
  final ValueChanged<String>? onSubmitted;

  /// Whether it takes input.
  final bool enabled;

  /// Whether it takes focus at once.
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextField(
      key: const Key('pairing-code-field'),
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.characters,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z\- ]')),
        LengthLimitingTextInputFormatter(20),
      ],
      style: pairingMono(context, 19, tracking: 1),
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label ?? l10n.pairingOtherCode,
        errorText: error,
        errorMaxLines: 3,
        suffixIcon: onScan == null
            ? null
            : IconButton(
                key: const Key('pairing-scan'),
                tooltip: l10n.pairingScan,
                onPressed: enabled ? onScan : null,
                icon: const Icon(LucideIcons.scanLine300),
              ),
      ),
    );
  }
}

/// Whether [text] could be a code, before asking the backend: 12 letters and
/// digits once dashes and spaces are gone.
bool pairingCodeComplete(String text) =>
    text.replaceAll(RegExp(r'[\s-]'), '').length == 12;

/// "or" between the pairing paths and the rest.
class PairingOr extends StatelessWidget {
  /// Creates the divider.
  const PairingOr({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(child: Divider(color: scheme.outlineVariant)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            AppLocalizations.of(context).pairingOr,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ),
        Expanded(child: Divider(color: scheme.outlineVariant)),
      ],
    );
  }
}

/// A state the page leads with: removed, restored elsewhere, a change under
/// way. Urgent ones use the error container, as the session-expired banner
/// does.
class PairingBanner extends StatelessWidget {
  /// Creates a banner.
  const PairingBanner({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.urgent = true,
    this.action,
  });

  /// Its icon.
  final IconData icon;

  /// What happened.
  final String title;

  /// What it means.
  final String body;

  /// Whether it is bad news.
  final bool urgent;

  /// One thing to do about it.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fill = urgent ? scheme.errorContainer : scheme.surfaceContainerHigh;
    final ink = urgent ? scheme.onErrorContainer : scheme.onSurface;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(kControlRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: ink),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(color: ink),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: theme.textTheme.bodySmall?.copyWith(color: ink),
                  ),
                  if (action != null) ...[
                    const SizedBox(height: 6),
                    Align(alignment: Alignment.centerRight, child: action),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One device in a list: its picture, name and one line of state.
class PairingDeviceRow extends StatelessWidget {
  /// Creates a row.
  const PairingDeviceRow({
    super.key,
    required this.name,
    required this.icon,
    this.line,
    this.lineColor,
    this.trailing,
    this.onTap,
    this.selected = false,
  });

  /// Its name.
  final String name;

  /// Its picture.
  final IconData icon;

  /// Its state: last active, not set up, asking to restore.
  final String? line;

  /// The state's color, when it asks for attention.
  final Color? lineColor;

  /// What sits at its end: this device, a menu, deny and allow.
  final Widget? trailing;

  /// Choosing it, in a list to pick from.
  final VoidCallback? onTap;

  /// Whether it is the one picked.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 58),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 8, 8),
        child: Row(
          children: [
            IconBadge(icon: icon, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (line != null)
                    Text(
                      line!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: lineColor ?? scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (selected)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  AppIcons.check_circle_outline,
                  size: 20,
                  color: scheme.primary,
                ),
              )
            else
              ?trailing,
          ],
        ),
      ),
    );
    if (onTap == null) return row;
    return InkWell(mouseCursor: clickable, onTap: onTap, child: row);
  }
}

/// Rows on one card, separated by hairlines: a `GroupCard` without a heading.
class PairingPlate extends StatelessWidget {
  /// Creates the plate.
  const PairingPlate(this.children, {super.key});

  /// Its rows.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kCardRadius),
        boxShadow: raisedCardShadows(scheme),
      ),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 16,
                  endIndent: 16,
                  color: scheme.outlineVariant,
                ),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Ask before something that changes membership or cannot be undone. True
/// only on the user's yes.
Future<bool> confirmPairing(
  BuildContext context, {
  required String title,
  required String body,
  required String yes,
  bool danger = false,
}) async {
  final answer = await showAppDialog<bool>(
    context: context,
    builder: (dialog) {
      final theme = Theme.of(dialog);
      final scheme = theme.colorScheme;
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('pairing-confirm-no'),
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(AppLocalizations.of(dialog).cancel),
          ),
          FilledButton(
            key: const Key('pairing-confirm-yes'),
            onPressed: () => Navigator.pop(dialog, true),
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  )
                : null,
            child: Text(yes),
          ),
        ],
      );
    },
  );
  return answer ?? false;
}

/// A small spinner for an action under way.
class PairingSpinner extends StatelessWidget {
  /// Creates a spinner.
  const PairingSpinner({super.key});

  @override
  Widget build(BuildContext context) => const Center(
    child: SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );
}
