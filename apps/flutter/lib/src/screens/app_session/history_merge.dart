import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/screens/app_session/transcript_model.dart';

/// Native ordering returns indices into these same objects. Bodies, resolved
/// images and widget state never make a round trip just to merge identities.
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
