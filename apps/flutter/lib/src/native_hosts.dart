/// Which of this device's running hosts continues a provider-native session
/// read from local history.
library;

import 'package:pocket_codex/src/bridge_api.dart';

/// The running host of [hosts] that serves native [provider] sessions
/// (`opencode`: the OpenCode host on OpenCode's default database, not one
/// with a history of its own; `claude`: a Claude ACP host), preferring
/// [preferred] (the host last chatted on); null when none runs. Opening a
/// session there resolves its access through that host; nothing is forked or
/// copied.
AppServeStatus? nativeContinueHost(
  List<AppServeStatus> hosts,
  String provider, {
  String? preferred,
}) {
  bool serves(AppServeStatus host) =>
      host.alive &&
      host.appServiceKey.isNotEmpty &&
      switch (provider) {
        'opencode' => host.servesOpenCodeHistory,
        'claude' => host.isAcp && host.profileId == 'claude',
        _ => false,
      };
  final matching = hosts.where(serves).toList();
  return matching.where((h) => h.appServiceKey == preferred).firstOrNull ??
      matching.firstOrNull;
}
