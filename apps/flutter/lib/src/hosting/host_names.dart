/// Instance names as the bridge compares them.
library;

/// The canonical identity of an instance name, as the bridge computes it
/// (`pocket_codex_core::service::sanitize_component`): lowercase, keep
/// `a-z0-9_.`, turn every other run into one `-`, trim dashes, else
/// `default`. Two names with one identity are one service on the relay.
String canonicalHostName(String name) {
  final id = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_.]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return id.isEmpty ? 'default' : id;
}

/// The name in [taken] that [name] would collide with, or null: a blank
/// name collides with nothing (the bridge then picks its default).
String? hostNameClash(String name, Iterable<String> taken) {
  if (name.trim().isEmpty) return null;
  final id = canonicalHostName(name);
  for (final other in taken) {
    if (canonicalHostName(other) == id) return other;
  }
  return null;
}

/// [base] when no name in [taken] has its identity, else the first free
/// `base-2`, `base-3`, …. Names are shared by every provider on a device.
String uniqueHostName(String base, Iterable<String> taken) {
  final used = {for (final name in taken) canonicalHostName(name)};
  if (!used.contains(canonicalHostName(base))) return base;
  for (var n = 2; ; n++) {
    final candidate = '$base-$n';
    if (!used.contains(canonicalHostName(candidate))) return candidate;
  }
}
