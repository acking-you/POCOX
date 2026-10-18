import 'dart:async';
import 'dart:typed_data';

import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/host_names.dart';
import 'package:pocket_codex/src/service_key.dart';

part 'support/fake_bridge/state.dart';
part 'support/fake_bridge/connection.dart';
part 'support/fake_bridge/host_sessions.dart';
part 'support/fake_bridge/hosting.dart';
part 'support/fake_bridge/threads.dart';
part 'support/fake_bridge/management.dart';
part 'support/fake_bridge/tools.dart';

/// In-memory bridge with shared, inspectable state for widget tests.
class FakeBridgeApi extends _FakeBridgeState
    with
        _FakeConnection,
        _FakeHostSessions,
        _FakeHosting,
        _FakeThreads,
        _FakeManagement,
        _FakeTools {
  /// Creates a fake seeded with optional configuration and services.
  FakeBridgeApi({super.config, super.services});

  /// A running native OpenCode host named [name].
  static AppServeStatus openCodeHost(
    String name, {
    String? binary,
    bool separateHistory = false,
    OpenCodeHostStatus? status,
  }) => AppServeStatus(
    name: name,
    device: 'local',
    alive: true,
    appListenAddr: '127.0.0.1:18300',
    appServiceKey: 'pcx:local:opencode:$name',
    appRegistered: true,
    metaListenAddr: '127.0.0.1:18301',
    metaServiceKey: 'pcx:local:meta:$name',
    metaRegistered: true,
    codexBinary: binary ?? '/Users/me/.opencode/bin/opencode',
    provider: 'opencode',
    protocol: 'opencode-http',
    providerName: 'OpenCode',
    opencode:
        status ??
        OpenCodeHostStatus(
          version: '1.19.0',
          providersConnected: 1,
          models: 2,
          defaultModel: 'fixture/test',
          agents: const ['build', 'plan'],
          separateHistory: separateHistory,
        ),
  );
}
