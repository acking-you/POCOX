import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/hosting/host_names.dart';
import 'package:pocox/src/ui_prefs.dart';

/// Which saved hosting to bring back on a desktop cold start.
///
/// The bridge's restore overrides ([BridgeApi.hostRestoreOverrides]) are the
/// authority: an override names the runtime to restore, or (runtime null)
/// that the host was stopped, locally or from another device. The UI
/// preferences only still count for a name with no override at all.
class HostRestorePlan {
  /// Creates a plan.
  const HostRestorePlan({
    this.codex = const [],
    this.acp = const [],
    this.opencode,
    this.overrides = const [],
  });

  /// Legacy Codex records to restore (names without an override).
  final List<AutoHostPrefs> codex;

  /// Legacy ACP records to restore (names without an override).
  final List<AutoHostAcpPrefs> acp;

  /// The legacy native OpenCode record to restore, if any.
  final AutoHostOpenCodePrefs? opencode;

  /// Authoritative choices to restore, each with a runtime.
  final List<HostRestoreOverride> overrides;

  /// Whether nothing needs restoring.
  bool get isEmpty =>
      codex.isEmpty && acp.isEmpty && opencode == null && overrides.isEmpty;

  /// Every instance name the plan touches, by attempt set: Codex names, and
  /// the names shared by ACP and OpenCode hosts.
  ({Set<String> codex, Set<String> acp}) get names => (
    codex: {
      for (final saved in codex) saved.name,
      for (final o in overrides)
        if (o.runtime!.isCodex) o.name,
    },
    acp: {
      for (final saved in acp) saved.name,
      ?opencode?.name,
      for (final o in overrides)
        if (!o.runtime!.isCodex) o.name,
    },
  );
}

/// Plan the restore: each name at most once per run (callers track the
/// attempts by instance name, per provider), and only names this device does
/// not host already. Names are shared by every provider on a device, so a
/// name taken by any running host is not restored over it. Instance names
/// compare as the bridge canonicalizes them ([canonicalHostName]). One host
/// at a time serves OpenCode's default database: no second one is restored
/// beside it, while hosts with a history of their own all are.
///
/// An override for a name, even one that only says "stopped", replaces that
/// name's UI record, so a stopped host is never brought back from stale
/// preferences.
HostRestorePlan planHostRestore(
  UiPrefs prefs,
  List<AppServeStatus> local, {
  required Set<String> codexAttempted,
  required Set<String> acpAttempted,
  required bool acpSupported,
  List<HostRestoreOverride> overrides = const [],
}) {
  // Identities only; the bridge still receives each record's original name.
  Set<String> ids(Iterable<String> names) => {
    for (final n in names) canonicalHostName(n),
  };
  final hosted = ids(local.map((h) => h.name));
  final overridden = ids(overrides.map((o) => o.name));
  final codexTried = ids(codexAttempted);
  final acpTried = ids(acpAttempted);
  // Names this plan already restores: an alias is planned once.
  final planned = <String>{};
  bool open(String name, Set<String> tried) {
    final id = canonicalHostName(name);
    return !tried.contains(id) &&
        !hosted.contains(id) &&
        !overridden.contains(id) &&
        planned.add(id);
  }

  var sharedHistoryTaken = local.any((h) => h.servesOpenCodeHistory);

  final chosen = <HostRestoreOverride>[];
  for (final o in overrides) {
    final runtime = o.runtime;
    if (runtime == null) continue;
    final id = canonicalHostName(o.name);
    final tried = runtime.isCodex ? codexTried : acpTried;
    if (tried.contains(id) || hosted.contains(id) || planned.contains(id)) {
      continue;
    }
    if (!runtime.isCodex && !acpSupported) continue;
    if (runtime.isOpenCode && !runtime.separateHistory) {
      if (sharedHistoryTaken) continue;
      sharedHistoryTaken = true;
    }
    planned.add(id);
    chosen.add(o);
  }

  final codex = [
    for (final saved in prefs.autoHostCodex)
      if (open(saved.name, codexTried)) saved,
  ];
  final acp = !acpSupported
      ? const <AutoHostAcpPrefs>[]
      : [
          for (final saved in prefs.autoHostAcp)
            if (open(saved.name, acpTried)) saved,
        ];
  // The legacy record predates separate histories: OpenCode's default one.
  final saved = prefs.autoHostOpenCode;
  final opencode =
      saved == null ||
          !acpSupported ||
          sharedHistoryTaken ||
          !open(saved.name, acpTried)
      ? null
      : saved;
  return HostRestorePlan(
    codex: codex,
    acp: acp,
    opencode: opencode,
    overrides: chosen,
  );
}

/// Run [plan]. Every restore goes through [BridgeApi.hostRestoreService],
/// which revalidates the choice under the host's lifecycle lease (a stop
/// from another device after the plan was made wins) and starts with what is
/// saved for the name. Only a legacy record carries its runtime. A failed
/// restore is left to the start-hosting fallback. Returns whether anything
/// was restored (discovery is then stale).
Future<bool> runHostRestore(BridgeApi api, HostRestorePlan plan) async {
  var restored = false;
  Future<void> restore(
    String name, {
    int? revision,
    HostRuntime? legacyRuntime,
  }) async {
    try {
      await api.hostRestoreService(
        name,
        expectedRevision: revision,
        legacyRuntime: legacyRuntime,
      );
      restored = true;
    } catch (_) {
      // Uninstalled, changed or stopped meanwhile: nothing is forced, and
      // the hero (with its start-hosting action) is the fallback.
    }
  }

  for (final o in plan.overrides) {
    await restore(o.name, revision: o.revision);
  }
  for (final saved in plan.codex) {
    await restore(
      saved.name,
      // Legacy built-in hosts are restored through the external binary.
      legacyRuntime: HostRuntime.codex(
        binary: saved.binaryOverride,
        port: saved.port,
        proxy: saved.proxy,
      ),
    );
  }
  for (final saved in plan.acp) {
    await restore(saved.name, legacyRuntime: HostRuntime.acp(saved.spec));
  }
  if (plan.opencode case final saved?) {
    await restore(
      saved.name,
      legacyRuntime: HostRuntime.opencode(binary: saved.binary),
    );
  }
  return restored;
}
