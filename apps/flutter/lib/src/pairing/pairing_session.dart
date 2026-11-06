import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/pairing/pairing_widgets.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/ui_prefs.dart';
import 'package:pocox/src/widgets/app_toast.dart';

/// A pairing invitation to preview, handed from a link or a scan to the page
/// that opens it. Kept in memory, never in a route, so a code reaches no
/// navigation log.
final pairingInvitationProvider = StateProvider<String?>((ref) => null);

/// Land a user who just signed in, by any route: re-read what the sign-in
/// changed, then the welcome guide the first time and the app every later
/// time. Waits briefly for the preferences file, degrading to "not seen".
Future<void> landAfterSignIn(BuildContext context, WidgetRef ref) async {
  // Rust has just written config.toml; the cached reading predates it.
  ref.invalidate(configProvider);
  try {
    await ref.read(configProvider.future).timeout(const Duration(seconds: 2));
  } catch (_) {
    // The destination reads config again itself.
  }
  if (!context.mounted) return;
  ref.invalidate(servicesProvider);
  bool seen;
  try {
    final prefs = await ref
        .read(uiPrefsProvider.notifier)
        .ready
        .timeout(const Duration(seconds: 2));
    seen = prefs.guideSeen;
  } on TimeoutException {
    if (!context.mounted) return;
    seen = ref.read(uiPrefsProvider).valueOrNull?.guideSeen ?? false;
  }
  if (context.mounted) context.go(seen ? '/' : '/welcome');
}

/// Carry a membership change through: done lands the user, still under way
/// opens the page that waits for it, failed says why. Never repeats it.
Future<void> followPairingOperation(
  BuildContext context,
  WidgetRef ref,
  PairingOperation operation, {
  String? backend,
}) async {
  final l10n = AppLocalizations.of(context);
  switch (operation.status) {
    case 'completed':
      if (!operation.caughtUp) {
        showToast(context, l10n.pairingNotCaughtUp);
      }
      await landAfterSignIn(context, ref);
    case 'pending':
      context.go('/pair/pending', extra: (operation, backend));
    default:
      showToastError(
        context,
        operation.error == null
            ? l10n.pairingErrUnreachable
            : pairingErrorText(
                l10n,
                PairingFailure(code: operation.error!, message: ''),
              ),
      );
  }
}

/// Settle what this device has under way, quietly: a page that is about to
/// read the device's state needs nothing else from it.
Future<void> settleQuietly(BridgeApi api, {String? backend}) async {
  try {
    await api.pairingSettle(backend: backend);
  } catch (_) {
    // The reading that follows reports what matters.
  }
}

/// A refusal because another change of this device is still under way: wait
/// for that one on its own page instead of saying "try again". True when
/// [error] was one and the page opened.
bool followTransitionPending(
  BuildContext context,
  Object error, {
  String? backend,
}) {
  if (error is! PairingFailure || error.code != 'transition_pending') {
    return false;
  }
  final id = error.operationId;
  if (id == null) return false;
  context.go(
    '/pair/pending',
    extra: (PairingOperation(id: id, kind: '', status: 'pending'), backend),
  );
  return true;
}

/// The failed changes already explained in this run, so each is told once.
final _explainedFailures = <String>{};

/// Say why each of [failed] did not happen, once per change per run: a
/// change whose answer came while no page waited for it would otherwise go
/// unexplained.
void explainFailedOperations(
  BuildContext context,
  List<PairingOperation> failed,
) {
  final l10n = AppLocalizations.of(context);
  for (final operation in failed) {
    if (!_explainedFailures.add(operation.id)) continue;
    showToastError(
      context,
      pairingErrorText(
        l10n,
        PairingFailure(code: operation.error ?? 'failed', message: ''),
      ),
    );
  }
}
