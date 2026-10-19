import 'package:pocket_codex/src/bridge_api.dart';

/// Negotiated ACP capabilities; native-only controls remain unavailable.
AppCapabilities negotiatedAcpCapabilities({
  required String providerName,
  String profileId = '',
  int generation = 1,
  bool imageInput = false,
  bool steer = false,
  bool nativeHistory = false,
  bool commands = false,
}) => AppCapabilities(
  provider: 'acp',
  fast: false,
  permissionPresets: false,
  guardian: false,
  rateLimits: false,
  takeover: false,
  externalWriterMonitor: nativeHistory,
  localSessions: false,
  planMode: false,
  protocol: 'acp',
  providerName: providerName,
  profileId: profileId,
  negotiated: true,
  generation: generation,
  imageInput: imageInput,
  steer: steer,
  sessionConfig: true,
  permissionOptions: true,
  sessionReopen: 'load',
  sessionList: 'agent',
  runningInventory: 'engine',
  commands: commands,
);

/// A connected native OpenCode host's capabilities, as the bridge reports
/// them: a model catalog together with per-session and draft options (the
/// options carry the model, so the composer shows them, not a model menu).
/// A local host's bridge also reports [localSessions] (its native history
/// on this device).
AppCapabilities negotiatedOpenCodeCapabilities({
  int generation = 1,
  bool imageInput = false,
  bool steer = true,
  bool commands = true,
  bool modelCatalog = true,
  bool localSessions = false,
}) => AppCapabilities(
  provider: 'opencode',
  fast: false,
  permissionPresets: false,
  guardian: false,
  rateLimits: false,
  takeover: false,
  externalWriterMonitor: false,
  localSessions: localSessions,
  planMode: false,
  protocol: 'opencode-http',
  providerName: 'OpenCode',
  profileId: 'opencode',
  negotiated: true,
  generation: generation,
  imageInput: imageInput,
  steer: steer,
  rename: true,
  sessionConfig: true,
  permissionOptions: true,
  sessionReopen: 'native',
  sessionList: 'native',
  historyScope: 'full',
  runningInventory: 'engine',
  commands: commands,
  modelCatalog: modelCatalog,
  draftOptions: true,
  questionMultiple: true,
);
