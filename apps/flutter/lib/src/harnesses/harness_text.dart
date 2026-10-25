/// Words for a device's harnesses, their updates and their failures.
library;

import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/managed/management_failure.dart';

/// The product name of harness [kind].
String harnessName(String kind) => switch (kind) {
  'codex' => 'Codex',
  'opencode' => 'OpenCode',
  'claude' => 'Claude Code',
  'grok' => 'Grok Build',
  _ => kind,
};

/// Its installed version and how it updates (`0.46.0 · npm`).
String harnessVersionLine(AppLocalizations l10n, HarnessInfo harness) {
  if (!harness.installed) return l10n.harnessNotInstalled;
  final method = switch (harness.method) {
    'brew' => l10n.harnessMethodBrew,
    'standalone' => l10n.harnessMethodStandalone,
    // Its own updater needs no mention.
    'own' || null => null,
    final other => other,
  };
  return [harness.version ?? l10n.harnessVersionUnknown, ?method].join(' · ');
}

/// Why [harness] cannot be checked or updated, when it cannot.
String? harnessProblemText(AppLocalizations l10n, HarnessInfo harness) =>
    switch (harness.problem) {
      null => null,
      'unmanaged' => l10n.harnessProblemUnmanaged,
      'winget' => l10n.harnessProblemWinget,
      'bundled' => l10n.harnessProblemBundled,
      'version_unknown' => l10n.harnessProblemVersion,
      _ => l10n.harnessProblemCheck,
    };

/// What a running update is doing.
String harnessStageText(AppLocalizations l10n, HarnessJob job) =>
    switch (job.stage) {
      'stopping' => l10n.harnessStageStopping,
      'restarting' => l10n.harnessStageRestarting,
      _ => l10n.harnessStageUpdating,
    };

/// How a finished update went, with what it restarted: `(text, failed)`.
(String, bool) harnessOutcome(AppLocalizations l10n, HarnessJob job) {
  final lines = <String>[];
  final failed = job.state == 'failed';
  final version = job.toVersion;
  if (failed) {
    lines.add(switch (job.failure) {
      'tool_missing' => l10n.harnessFailedToolMissing,
      'in_use' => l10n.harnessFailedInUse,
      'permission' => l10n.harnessFailedPermission,
      'timed_out' => l10n.harnessFailedTimeout,
      'unavailable' => l10n.harnessUpdateUnavailable,
      _ => l10n.harnessFailed,
    });
  } else if (version != null && version == job.fromVersion) {
    lines.add(l10n.harnessUnchanged(version));
  } else if (version != null) {
    lines.add(
      job.automatic
          ? l10n.harnessUpdatedAutomatically(version)
          : l10n.harnessUpdated(version),
    );
  }
  if (job.restarted.isNotEmpty) {
    lines.add(l10n.harnessRestarted(job.restarted.join(', ')));
  }
  if (job.notRestarted.isNotEmpty) {
    final items = [
      for (final skip in job.notRestarted)
        '${skip.name} (${_skipReason(l10n, skip.reason)})',
    ];
    lines.add(l10n.harnessNotRestarted(items.join(', ')));
  }
  return (lines.join(' '), failed);
}

String _skipReason(AppLocalizations l10n, String reason) => switch (reason) {
  'disabled' => l10n.harnessSkipDisabled,
  'adopted' => l10n.harnessSkipAdopted,
  'shared_server' => l10n.harnessSkipShared,
  'changed' => l10n.harnessSkipChanged,
  'busy' => l10n.harnessSkipBusy,
  _ => l10n.harnessSkipFailed,
};

/// The text for a failed harness call. A managed computer's lost answer is
/// unknown, as for every management call; this device's own error is shown
/// as it is.
String harnessFailureText(
  AppLocalizations l10n,
  Object error, {
  required bool local,
}) {
  final failure = ManagementFailure.of(error);
  return switch (failure.code) {
    'update_running' => l10n.harnessUpdateRunning,
    'update_unavailable' => l10n.harnessUpdateUnavailable,
    null when local => failure.message,
    _ => managedFailureText(l10n, failure),
  };
}
