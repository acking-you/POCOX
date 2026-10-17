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
  });

  /// Publisher OS, independent of the controller's OS.
  final String os;

  /// Publisher executable architecture.
  final String arch;

  /// Runtime environment, currently `wsl`.
  final String? environment;

  /// Display hostname; never an ownership check.
  final String hostname;

  /// Opaque process identity, renewed on restart.
  final String instanceId;

  /// Human-readable platform, including WSL where the host reports it.
  String get platform => [
    switch (os) {
      'windows' => 'Windows',
      'macos' => 'macOS',
      'linux' => 'Linux',
      'android' => 'Android',
      'ios' => 'iOS',
      _ => os,
    },
    if (environment == 'wsl') 'WSL',
    arch,
  ].where((part) => part.isNotEmpty).join(' · ');
}
