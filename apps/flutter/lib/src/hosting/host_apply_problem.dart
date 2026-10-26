import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';

/// What an apply ([BridgeApi.appServeApply]) that did not apply tells the
/// user, with the bridge's safe reason in the user's words where they have
/// some; null when the host runs what it was restarted with.
String? hostApplyProblem(AppLocalizations l10n, HostApplyResult result) {
  if (result.applied) return null;
  String reason(String? raw) => raw == null
      ? ''
      : raw.contains('opencode_already_hosted')
      ? l10n.openCodeAlreadyHosted
      : raw;
  if (result.restoredPrevious) {
    return l10n.hostApplyRestored(reason(result.error));
  }
  if (result.restoreError != null) {
    return l10n.hostApplyStopped(
      reason(result.error),
      reason(result.restoreError),
    );
  }
  return l10n.hostApplyFailed(reason(result.error));
}
