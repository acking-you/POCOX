/// A least-recently-used memo bounded by a total weight (say, the
/// characters its values were made from), for work that is costly to redo
/// and keyed by the input that produced it.
class LruCache<K, V extends Object> {
  /// Creates a cache holding at most [maxWeight] of [weigh]ed entries.
  LruCache({required this.maxWeight, required this.weigh});

  /// The most the entries may weigh together.
  final int maxWeight;

  /// An entry's weight; at least 1.
  final int Function(K key, V value) weigh;

  // Insertion-ordered (a map literal is a LinkedHashMap): oldest first.
  final _entries = <K, V>{};
  int _weight = 0;

  /// The value for [key], now the most recently used, or null.
  V? get(K key) {
    final hit = _entries.remove(key);
    if (hit != null) _entries[key] = hit;
    return hit;
  }

  /// Keep [value] for [key]. An entry heavier than the whole budget is not
  /// kept.
  void put(K key, V value) {
    final old = _entries.remove(key);
    if (old != null) _weight -= _weightOf(key, old);
    final weight = _weightOf(key, value);
    if (weight > maxWeight) return;
    _entries[key] = value;
    _weight += weight;
    while (_weight > maxWeight && _entries.isNotEmpty) {
      final oldest = _entries.keys.first;
      _weight -= _weightOf(oldest, _entries.remove(oldest)!);
    }
  }

  /// The value for [key], computing and keeping it with [make] when absent.
  V putIfAbsent(K key, V Function() make) {
    final hit = get(key);
    if (hit != null) return hit;
    final value = make();
    put(key, value);
    return value;
  }

  int _weightOf(K key, V value) {
    final w = weigh(key, value);
    return w < 1 ? 1 : w;
  }
}
