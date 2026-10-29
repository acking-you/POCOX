import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session/transcript_model.dart';

/// Native ordering returns indices into these same objects. Bodies, resolved
/// images and widget state never make a round trip just to merge identities.
/// [incoming] owns the order of shared IDs; [current] owns their content.
Future<List<TranscriptItem>> mergeHistoryItems(
  BridgeApi api,
  List<TranscriptItem> current,
  List<TranscriptItem> incoming, {
  required Iterable<String> turnOrder,
  required bool olderPage,
}) async {
  final indices = await api.historyMerge(
    [for (final item in current) item.id],
    [for (final item in current) item.turnId],
    [for (final item in incoming) item.id],
    [for (final item in incoming) item.turnId],
    turnOrder.toList(),
    olderPage,
  );
  final source = [...current, ...incoming];
  return [for (final index in indices) source[index]];
}

/// Turns represented in both sources without any shared item to establish
/// their relative positions. Neither event arrival nor an ID's spelling is a
/// chronological position in a bounded history window.
Set<String> unanchoredLiveTurns(
  Iterable<ThreadItem> history,
  Iterable<TranscriptItem> live,
) {
  final byId = {for (final item in history) item.id: item.turnId};
  final turns = byId.values.where((turn) => turn.isNotEmpty).toSet();
  final pending = <String>{};
  final anchored = <String>{};
  for (final item in live) {
    final turn = byId[item.id];
    if (turn != null) {
      anchored.add(turn);
    } else if (turns.contains(item.turnId)) {
      pending.add(item.turnId);
    }
  }
  return pending.difference(anchored);
}
