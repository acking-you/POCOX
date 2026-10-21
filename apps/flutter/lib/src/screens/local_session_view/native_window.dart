import 'package:pocox/src/bridge_api.dart';

/// Bounded contiguous native pages. Gaps/replacements discard old windows
/// instead of joining unrelated snapshots into an apparently complete history.
class NativeHistoryWindow {
  static const maxTurns = 160;
  static const maxBytes = 32 * 1024 * 1024;
  String? sourceId, generation, revision, nextBefore;
  List<ThreadItem> items = const [];
  bool truncated = false;

  void clear() {
    sourceId = generation = revision = nextBefore = null;
    items = const [];
    truncated = false;
  }

  void tail(NativeSessionPage page) {
    final same = sourceId == page.sourceId && generation == page.generation;
    final first = page.items.isEmpty ? null : page.items.first.turnId;
    final index = same && first != null
        ? items.indexWhere((item) => item.turnId == first)
        : -1;
    final prefix = index > 0 ? items.take(index).toList() : <ThreadItem>[];
    final previousBefore = nextBefore;
    final previousTruncated = truncated;
    final missed = same && items.isNotEmpty && index < 0;
    sourceId = page.sourceId;
    generation = page.generation;
    revision = page.revision;
    items = [...prefix, ...page.items];
    nextBefore = prefix.isEmpty ? page.nextBefore : previousBefore;
    truncated =
        page.truncated || missed || (prefix.isNotEmpty && previousTruncated);
    _bound(dropOldest: true);
  }

  /// Returns false when an older page belongs to a changed generation.
  bool prepend(NativeSessionPage page) {
    if (page.sourceId != sourceId || page.generation != generation) {
      return false;
    }
    final known = items.map((item) => (item.turnId, item.id)).toSet();
    items = [
      ...page.items.where((item) => known.add((item.turnId, item.id))),
      ...items,
    ];
    nextBefore = page.nextBefore;
    truncated |= page.truncated;
    // Preserve the user's older reading window; the next tail refresh may
    // replace it if the retained windows no longer overlap.
    _bound(dropOldest: false);
    return true;
  }

  void _bound({required bool dropOldest}) {
    int size(ThreadItem item) =>
        2 *
        (item.id.length +
            item.title.length +
            item.text.length +
            item.images.fold<int>(0, (n, url) => n + url.length));
    var bytes = items.fold<int>(0, (n, item) => n + size(item));
    final turns = <String?, List<ThreadItem>>{};
    for (final item in items) {
      (turns[item.turnId] ??= []).add(item);
    }
    while (turns.isNotEmpty && (turns.length > maxTurns || bytes > maxBytes)) {
      final key = dropOldest ? turns.keys.first : turns.keys.last;
      final removed = turns.remove(key)!;
      bytes -= removed.fold<int>(0, (n, item) => n + size(item));
      truncated = true;
    }
    if (turns.length < items.map((i) => i.turnId).toSet().length) {
      items = turns.values.expand((v) => v).toList();
      if (dropOldest && items.isNotEmpty) {
        nextBefore = items.first.turnId;
      }
    }
  }
}
