import 'package:pocox/src/bridge_api.dart';

/// Where a sessions view reads from: this machine's `CODEX_HOME` directly
/// ([SessionSource.local]), or a (possibly remote) host's CODEX_HOME over its
/// meta tunnel, keyed by that host's app-server [serviceKey]
/// ([SessionSource.remote]). The remote source is what makes a desktop host's
/// sessions viewable + resumable from a phone (and, since a meta tunnel hosted
/// by this app is served over loopback, the same path covers local hosting).
class SessionSource {
  /// Read this machine's sessions directly.
  const SessionSource.local({this.provider = 'codex'}) : serviceKey = null;

  /// Read the host behind [key]'s sessions over its meta tunnel.
  const SessionSource.remote(String key) : serviceKey = key, provider = 'codex';

  final String provider;
  bool get isNative => !isRemote && provider != 'codex';

  /// The app-server service key whose host to read, or null for local.
  final String? serviceKey;

  /// Whether this reads a (possibly remote) host over the meta tunnel.
  bool get isRemote => serviceKey != null;

  /// List the source's sessions.
  Future<List<LocalSession>> list(BridgeApi b) => isNative
      ? Future.error(StateError('Use native inventory pages'))
      : serviceKey == null
      ? b.appLocalSessions()
      : b.metaSessions(serviceKey!);

  /// One session's liveness from the source.
  Future<SessionLiveness> liveness(BridgeApi b, String threadId) => isNative
      ? Future.error(StateError('Use native revision'))
      : serviceKey == null
      ? b.appSessionLiveness(threadId)
      : b.metaSessionLiveness(serviceKey!, threadId);

  /// One session's read-only transcript from the source.
  Future<List<ThreadItem>> transcript(BridgeApi b, String threadId) => isNative
      ? Future.error(StateError('Use native transcript pages'))
      : serviceKey == null
      ? b.appLocalSessionTranscript(threadId)
      : b.metaSessionTranscript(serviceKey!, threadId);
}
