import 'package:flutter/foundation.dart' show listEquals;
import 'support/fake_composer_control.dart';
import 'support/native_diff_fixture.dart';
import 'support/history_projection_fixture.dart';
import 'package:pocox/src/screens/app_session/transcript_model.dart';
import 'package:pocox/src/git_diff.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/hosting/host_names.dart';
import 'package:pocox/src/service_key.dart';
import 'package:pocox/src/updates/update_api.dart';

part 'support/fake_bridge/state.dart';
part 'support/fake_bridge/connection.dart';
part 'support/fake_bridge/host_sessions.dart';
part 'support/fake_bridge/hosting.dart';
part 'support/fake_bridge/threads.dart';
part 'support/fake_bridge/management.dart';
part 'support/fake_bridge/tools.dart';
part 'support/fake_bridge/grok.dart';
part 'support/fake_bridge/updates.dart';

/// In-memory bridge with shared, inspectable state for widget tests.
class FakeBridgeApi extends _FakeBridgeState
    with
        _FakeConnection,
        _FakeHostSessions,
        _FakeHosting,
        _FakeThreads,
        _FakeManagement,
        _FakeTools,
        _FakeGrok,
        _FakeUpdates {
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
