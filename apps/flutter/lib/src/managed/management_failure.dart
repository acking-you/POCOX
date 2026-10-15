import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/error_format.dart';

/// A classified device-management failure.
///
/// The bridge formats host refusals as `code (status): message`. Anything else
/// (a lost response, a dropped tunnel) carries no code: its outcome is
/// unknown, so the caller refreshes the real state instead of resending.
class ManagementFailure {
  const ManagementFailure._(this.code, this.message);

  /// Parses [error] as thrown by a management call.
  factory ManagementFailure.of(Object error) {
    var text = friendlyError(error);
    // A Dart `Exception` wraps the bridge's text in its own prefix.
    if (error is Exception && text.startsWith('Exception: ')) {
      text = text.substring('Exception: '.length);
    }
    final match = RegExp(r'^([a-z_]+) \((\d{3})\): ').firstMatch(text);
    if (match == null) return ManagementFailure._(null, text);
    return ManagementFailure._(match[1], text.substring(match.end));
  }

  /// Stable server code, null when the request's outcome is unknown.
  final String? code;

  /// Display text from the host (English) or the local error.
  final String message;

  /// Whether the mutation may have happened: refresh before acting again.
  bool get uncertain =>
      code == null ||
      code == 'connection_changed' ||
      code == 'host_operation_failed';

  /// Another device saved the configuration since it was read.
  bool get conflict =>
      code == 'configuration_changed' || code == 'project_changed';
}

/// The text to show for [failure]: a localized explanation for the codes a
/// person can act on, the host's own safe message otherwise.
String managedFailureText(AppLocalizations l10n, ManagementFailure failure) =>
    switch (failure.code) {
      null ||
      'connection_changed' ||
      'host_operation_failed' => l10n.managedOutcomeUnknown,
      'host_busy' => l10n.managedHostBusy,
      'already_running' => l10n.managedAlreadyRunning,
      'host_stopped' => l10n.managedHostStopped,
      'host_changed' => l10n.managedHostChanged,
      'host_login_required' => l10n.managedLoginRequired,
      'prepare_required' => l10n.managedPrepareRequired,
      'invalid_configuration' => l10n.managedInvalidConfiguration,
      'configuration_changed' => l10n.managedConfigurationChanged,
      'outside_project_roots' => l10n.managedOutsideRoots,
      'project_changed' => l10n.defaultProjectConflict,
      'project_missing' => l10n.defaultProjectMissing,
      _ => failure.message,
    };
