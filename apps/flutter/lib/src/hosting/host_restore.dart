import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/ui_prefs.dart';

/// Which saved hosting to bring back on a desktop cold start.
class HostRestorePlan {
  /// Creates a plan.
  const HostRestorePlan({
    this.codex = const [],
    this.acp = const [],
    this.opencode,
  });

  /// Codex hosts to restore, each under its own instance name.
  final List<AutoHostPrefs> codex;

  /// ACP agents to restore, each under its own instance name.
  final List<AutoHostAcpPrefs> acp;

  /// The native OpenCode host to restore, if any.
  final AutoHostOpenCodePrefs? opencode;

  /// Whether nothing needs restoring.
  bool get isEmpty => codex.isEmpty && acp.isEmpty && opencode == null;
}

/// Plan the restore: each saved record at most once per run (callers track
/// the attempts by instance name, per provider), and only names this device
/// does not host already. Names are shared by every provider on a device,
/// so a name taken by any running host is not restored over it.
HostRestorePlan planHostRestore(
  UiPrefs prefs,
  List<AppServeStatus> local, {
  required Set<String> codexAttempted,
  required Set<String> acpAttempted,
  required bool acpSupported,
}) {
  final hostedNames = {for (final h in local) h.name};
  final codex = [
    for (final saved in prefs.autoHostCodex)
      if (!codexAttempted.contains(saved.name) &&
          !hostedNames.contains(saved.name))
        saved,
  ];
  final acp = !acpSupported
      ? const <AutoHostAcpPrefs>[]
      : [
          for (final saved in prefs.autoHostAcp)
            if (!acpAttempted.contains(saved.name) &&
                !hostedNames.contains(saved.name))
              saved,
        ];
  final saved = prefs.autoHostOpenCode;
  // One OpenCode host per device: none is restored beside a running one.
  final opencode =
      saved == null ||
          !acpSupported ||
          acpAttempted.contains(saved.name) ||
          hostedNames.contains(saved.name) ||
          local.any((h) => h.isOpenCode)
      ? null
      : saved;
  return HostRestorePlan(codex: codex, acp: acp, opencode: opencode);
}

/// Run [plan]; a failed restore is left to the start-hosting fallback.
/// Returns whether anything was restored (discovery is then stale).
Future<bool> runHostRestore(BridgeApi api, HostRestorePlan plan) async {
  var restored = false;
  for (final codex in plan.codex) {
    try {
      await api.appServeStart(
        port: codex.port,
        binaryOverride: codex.binaryOverride,
        name: codex.name,
        proxy: codex.proxy,
        // Legacy built-in hosts are restored through the external binary.
        embedded: false,
      );
      restored = true;
    } catch (_) {
      // The hero (with its start-hosting action) is the fallback.
    }
  }
  for (final saved in plan.acp) {
    try {
      await api.appServeStartAcp(name: saved.name, spec: saved.spec);
      restored = true;
    } catch (_) {
      // The agent may have been uninstalled; its record stays for next time.
    }
  }
  if (plan.opencode case final saved?) {
    try {
      // Started again with what is saved for it: its model service (its own
      // configuration or a custom provider, whose stored key is kept) and
      // its desired runtime. A start saves what it is given, so nothing
      // starts from a configuration that is unreadable, reported damaged
      // (its fields are then only defaults) or saved for another engine:
      // the record and that configuration stay for the editor to resolve.
      final config = await api.hostConfigGet(saved.name);
      final desired = config.runtime;
      if (config.problem != null || (desired != null && !desired.isOpenCode)) {
        return restored;
      }
      await api.appServeStartConfigured(
        name: saved.name,
        runtime: desired ?? HostRuntime.opencode(binary: saved.binary),
        input: HostConfigInput(
          source: config.source,
          protocol: config.protocol,
          baseUrl: config.baseUrl,
          model: config.model,
        ),
        keyAction: HostKeyAction.keep,
      );
      restored = true;
    } catch (_) {
      // OpenCode may have been uninstalled; its record stays for next time.
    }
  }
  return restored;
}
