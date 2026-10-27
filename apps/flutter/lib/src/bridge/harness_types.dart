part of '../bridge_api.dart';

/// Harness versions and updates of this device or of a managed computer.
/// A null `serviceKey` is this device; otherwise it is the other computer's
/// `host:` management key. Each device checks, updates and keeps its own
/// settings.
abstract interface class HarnessBridgeApi {
  /// The device's harnesses as last checked; a stale check starts one there.
  /// Null when the other computer's POCOX has no harness management.
  Future<HarnessOverview?> harnessOverview(String? serviceKey);

  /// Look up installed and newest versions on the device now.
  Future<HarnessOverview> harnessCheck(String? serviceKey);

  /// Start updating [kind] on the device; its progress is read with
  /// [harnessOverview]. A lost answer is never sent again by itself.
  Future<HarnessOverview> harnessUpdate(String? serviceKey, String kind);

  /// Change the device's own settings: [kind]'s automatic update and/or
  /// restarting services after an update.
  Future<HarnessOverview> harnessSettings(
    String? serviceKey, {
    String? kind,
    bool? autoUpdate,
    bool? restartServices,
  });
}

/// One harness of a device, from [HarnessBridgeApi.harnessOverview].
class HarnessInfo {
  /// Creates a harness row.
  const HarnessInfo({
    required this.kind,
    this.installed = false,
    this.version,
    this.latest,
    this.updateAvailable = false,
    this.method,
    this.canUpdate = false,
    this.problem,
    this.autoUpdate = false,
    this.services = const [],
  });

  /// `codex`, `opencode`, `claude` or `grok`.
  final String kind;

  /// Its executable was found on the device.
  final bool installed;

  /// The installed version.
  final String? version;

  /// The newest version its vendor publishes for this installation.
  final String? latest;

  /// [latest] is newer than [version].
  final bool updateAvailable;

  /// `npm`, `bun`, `pnpm`, `brew`, `standalone` or `own`.
  final String? method;

  /// An update can be started.
  final bool canUpdate;

  /// `unmanaged`, `winget`, `bundled`, `version_unknown` or `check_failed`.
  final String? problem;

  /// The device updates it by itself.
  final bool autoUpdate;

  /// Running services of the device that use it.
  final List<String> services;
}

/// A service an update did not restart.
class HarnessSkip {
  /// Creates a skipped service.
  const HarnessSkip({required this.name, required this.reason});

  /// Instance name.
  final String name;

  /// `disabled`, `adopted`, `shared_server`, `other_install`, `changed`,
  /// `busy` or `failed`.
  final String reason;
}

/// Measurements for the current download, when the installer reports them.
class HarnessDownload {
  /// Creates installer-reported measurements; absent values are unknown.
  const HarnessDownload({
    this.downloadedBytes,
    this.totalBytes,
    this.bytesPerSecond,
    this.percent,
  });

  /// Bytes received for the current file.
  final int? downloadedBytes;

  /// Size of the current file, when known.
  final int? totalBytes;

  /// Current download speed reported by the installer.
  final int? bytesPerSecond;

  /// Download percentage, not overall installation progress.
  final int? percent;
}

/// The running or most recent update on a device.
class HarnessJob {
  /// Creates an update.
  const HarnessJob({
    required this.run,
    required this.kind,
    required this.state,
    this.stage,
    this.download,
    this.elapsedMs,
    this.automatic = false,
    this.fromVersion,
    this.toVersion,
    this.failure,
    this.restarted = const [],
    this.notRestarted = const [],
    this.startedAtMs = 0,
    this.finishedAtMs,
  });

  /// Its number on the device.
  final int run;

  /// The harness it updates.
  final String kind;

  /// `running`, `done` or `failed`.
  final String state;

  /// `stopping`, `updating`, `downloading`, `installing`, `verifying` or
  /// `restarting` while running.
  final String? stage;

  /// Measurements reported by the installer; silent installers omit them.
  final HarnessDownload? download;

  /// Elapsed milliseconds measured on the host, absent on older hosts.
  final int? elapsedMs;

  /// Started by the device's automatic update.
  final bool automatic;

  /// The version before it.
  final String? fromVersion;

  /// The version after it.
  final String? toVersion;

  /// `unavailable`, `tool_missing`, `in_use`, `permission`, `timed_out` or
  /// `failed`.
  final String? failure;

  /// Services restarted on the installed version.
  final List<String> restarted;

  /// Services not restarted, and why.
  final List<HarnessSkip> notRestarted;

  /// Unix milliseconds.
  final int startedAtMs;

  /// Unix milliseconds.
  final int? finishedAtMs;

  /// Whether it is still running.
  bool get running => state == 'running';
}

/// Every harness a device can host, with its update settings.
class HarnessOverview {
  /// Creates an overview.
  const HarnessOverview({
    this.harnesses = const [],
    this.checkedAtMs,
    this.checking = false,
    this.restartServices = true,
    this.job,
  });

  /// In display order; none before the device first checked.
  final List<HarnessInfo> harnesses;

  /// When the newest versions were last looked up (Unix milliseconds).
  final int? checkedAtMs;

  /// A lookup is running.
  final bool checking;

  /// Services that use an updated harness restart on the new version.
  final bool restartServices;

  /// The running or most recent update.
  final HarnessJob? job;

  /// Whether the device is busy with a lookup or an update.
  bool get busy => checking || (job?.running ?? false);
}
