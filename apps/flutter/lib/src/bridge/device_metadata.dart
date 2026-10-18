part of '../bridge_api.dart';

/// Metadata supplied by the process that owns a registered service.
class DeviceMetadata {
  /// Creates publisher metadata.
  const DeviceMetadata({
    required this.os,
    required this.arch,
    required this.hostname,
    required this.instanceId,
    this.environment,
    this.hostId,
    this.sourceName,
  });

  /// Publisher OS, independent of the controller's OS.
  final String os;

  /// Publisher executable architecture.
  final String arch;

  /// Runtime environment, currently `wsl`.
  final String? environment;

  /// Display hostname; never an ownership check. May be empty.
  final String hostname;

  /// Stable hosting installation identity, independent of process restarts.
  final String? hostId;

  /// OS distribution or WSL distribution name reported by the publisher.
  final String? sourceName;

  /// Opaque process identity, renewed on restart.
  final String instanceId;

  /// Human-readable platform, including WSL where the host reports it.
  String get platform => [
    osLabel(os),
    if (environment case final environment?) osLabel(environment),
    ?sourceName,
    arch,
  ].where((part) => part.isNotEmpty).join(' · ');

  /// [platform] plus a short stable ID, to tell same-name installations apart.
  String get instanceLabel => switch (hostId) {
    final id? when id.isNotEmpty => '$platform · ${shortId(id)}',
    _ => platform,
  };

  @override
  bool operator ==(Object other) =>
      other is DeviceMetadata &&
      other.os == os &&
      other.arch == arch &&
      other.environment == environment &&
      other.hostname == hostname &&
      other.hostId == hostId &&
      other.sourceName == sourceName &&
      other.instanceId == instanceId;

  @override
  int get hashCode => Object.hash(
    os,
    arch,
    environment,
    hostname,
    hostId,
    sourceName,
    instanceId,
  );
}
