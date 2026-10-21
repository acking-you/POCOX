import 'dart:async';
import 'dart:typed_data';
import 'package:pocox/src/lru_cache.dart';
import 'package:pocox/src/rust/api/bridge/text_render.dart' as native;

typedef HighlightSource = ({String code, String language});
typedef HighlightLoader =
    Future<List<Uint32List>> Function(List<HighlightSource> inputs);

/// A view's interest in a parse; disposal removes work not yet dispatched.
class HighlightLease {
  HighlightLease(this.result, this._release);
  final Future<Uint32List> result;
  final void Function() _release;
  bool _released = false;
  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

class _Request {
  _Request(this.source);
  final HighlightSource source;
  final done = Completer<Uint32List>();
  int readers = 0;
  bool started = false;
  int get bytes => source.code.length * 2 + 64;
}

/// Coalesces visible code into native batches with bounded admission and cache.
/// Theme/font changes reuse tokens; old streamed prefixes lose their queue slot.
class SyntaxHighlighter {
  SyntaxHighlighter({HighlightLoader? loader}) : _loader = loader ?? _native;
  static SyntaxHighlighter shared = SyntaxHighlighter();
  final HighlightLoader _loader;
  final _cache = LruCache<HighlightSource, Uint32List>(
    maxWeight: 2 << 20,
    weigh: (key, value) => key.code.length * 2 + value.lengthInBytes + 64,
  );
  final _pending = <HighlightSource, _Request>{};
  int _bytes = 0, _running = 0;
  bool _scheduled = false;

  static Future<List<Uint32List>> _native(List<HighlightSource> inputs) async =>
      [
        for (final result in await native.highlightBatch(
          inputs: [
            for (final input in inputs)
              native.HighlightInputDto(
                source: input.code,
                language: input.language,
              ),
          ],
        ))
          result.runs,
      ];

  Uint32List? peek(String code, String language) =>
      _cache.get((code: code, language: language));

  HighlightLease request(String code, String language) {
    final key = (code: code, language: language);
    final cached = _cache.get(key);
    if (cached != null) return HighlightLease(Future.value(cached), () {});
    if (code.isEmpty || code.length > 20000) return _plain();
    var request = _pending[key];
    if (request == null) {
      request = _Request(key);
      if (_pending.length >= 512 || _bytes + request.bytes > (2 << 20)) {
        return _plain();
      }
      _pending[key] = request;
      _bytes += request.bytes;
    }
    request.readers++;
    _schedule();
    final current = request;
    return HighlightLease(request.done.future, () {
      current.readers--;
      if (current.readers == 0 && !current.started) {
        _remove(current);
        if (!current.done.isCompleted) current.done.complete(Uint32List(0));
      }
    });
  }

  HighlightLease _plain() => HighlightLease(Future.value(Uint32List(0)), () {});
  void _remove(_Request request) {
    if (identical(_pending[request.source], request)) {
      _pending.remove(request.source);
      _bytes -= request.bytes;
    }
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      while (_running < 2) {
        final batch = _pending.values
            .where((r) => !r.started)
            .take(16)
            .toList();
        if (batch.isEmpty) break;
        for (final request in batch) {
          request.started = true;
        }
        _running++;
        unawaited(_run(batch));
      }
    });
  }

  Future<void> _run(List<_Request> batch) async {
    List<Uint32List>? tokens;
    try {
      tokens = await _loader([for (final r in batch) r.source]);
    } catch (_) {
      /* Readable plain text survives an unavailable native worker. */
    }
    for (var i = 0; i < batch.length; i++) {
      final request = batch[i];
      final result = tokens != null && tokens.length == batch.length
          ? tokens[i]
          : Uint32List(0);
      if (tokens != null &&
          tokens.length == batch.length &&
          request.readers > 0) {
        _cache.put(request.source, result);
      }
      _remove(request);
      request.done.complete(result);
    }
    _running--;
    _schedule();
  }
}
