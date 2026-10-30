// Fixture projection for fake-bridge widget scenarios; native ordering is tested in Rust.
import 'package:pocox/src/screens/app_session/transcript_model.dart';

typedef _TurnKey = ({String turn, String? item});

/// Merge a chronological page with previously loaded, possibly disjoint turns.
/// Shared item IDs anchor overlapping pages without replacing live snapshots.
List<TranscriptItem> fakeMergeHistoryItems(
  List<TranscriptItem> current,
  List<TranscriptItem> incoming, {
  required Iterable<String> turnOrder,
  required bool olderPage,
}) {
  Map<_TurnKey, List<TranscriptItem>> group(List<TranscriptItem> items) {
    final groups = <_TurnKey, List<TranscriptItem>>{};
    for (final item in items) {
      // Optimistic user rows may not have a server turn ID yet. Keep each in
      // place rather than grouping unrelated anonymous rows into one turn.
      final key = (
        turn: item.turnId,
        item: item.turnId.isEmpty ? item.id : null,
      );
      (groups[key] ??= []).add(item);
    }
    return groups;
  }

  final old = group(current);
  final pages = group(incoming);
  final knownTurns = turnOrder
      .map((turn) => (turn: turn, item: null as String?))
      .toSet();
  final existingOrder = old.keys.toList();
  final firstKnown = existingOrder.indexWhere(knownTurns.contains);
  final order = <_TurnKey>{
    if (firstKnown >= 0) ...existingOrder.take(firstKnown),
    ...knownTurns,
    ...existingOrder,
  }.toList();
  final missing = pages.keys.where((id) => !order.contains(id)).toList();
  order.insertAll(olderPage ? 0 : order.length, missing);
  return [
    for (final turn in order)
      ..._mergeTurn(old[turn] ?? [], pages[turn] ?? [], olderPage),
  ];
}

List<TranscriptItem> _mergeTurn(
  List<TranscriptItem> current,
  List<TranscriptItem> incoming,
  bool olderPage,
) {
  final byId = {for (final item in current) item.id: item};
  final incomingIds = incoming.map((item) => item.id).toSet();
  final before = <String, List<TranscriptItem>>{};
  var retained = <TranscriptItem>[];
  for (final item in current) {
    if (incomingIds.contains(item.id)) {
      before[item.id] = retained;
      retained = [];
    } else {
      retained.add(item);
    }
  }
  final anchored = before.isNotEmpty;
  final out = <TranscriptItem>[if (!anchored && !olderPage) ...current];
  final seen = <String>{};
  final pending = <TranscriptItem>[];
  for (final item in incoming) {
    if (!seen.add(item.id)) continue;
    final existing = byId[item.id];
    if (existing == null) {
      pending.add(item);
    } else {
      out
        ..addAll(pending)
        ..addAll(before[item.id] ?? [])
        ..add(existing);
      pending.clear();
    }
  }
  out.addAll(pending);
  if (anchored || olderPage) out.addAll(retained);
  return out;
}
