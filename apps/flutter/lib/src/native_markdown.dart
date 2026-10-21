import 'dart:convert';
import 'dart:async';
import 'dart:collection';
import 'package:markdown/markdown.dart' as md;
import 'package:pocox/src/rust/api/bridge/text_render.dart' as native;

/// Parse on a native CPU worker, adapting its bounded tree to the UI renderer.
Future<List<md.Node>> parseNativeMarkdown(String source) =>
    _queue.parse(source);

/// Injectable parser boundary; production always uses the native CPU worker.
abstract final class MarkdownParsing {
  static FutureOr<List<md.Node>> Function(String) parse = parseNativeMarkdown;
}

final _queue = _ParseQueue();

class _ParseQueue {
  final _waiting = Queue<(String, Completer<List<md.Node>>)>();
  int _running = 0, _bytes = 0;
  Future<List<md.Node>> parse(String source) {
    if (_waiting.length >= 64 || _bytes + source.length * 2 > (4 << 20)) {
      return Future.error(StateError('Markdown queue is full'));
    }
    final done = Completer<List<md.Node>>();
    _waiting.add((source, done));
    _bytes += source.length * 2;
    _drain();
    return done.future;
  }

  void _drain() {
    while (_running < 2 && _waiting.isNotEmpty) {
      final (source, done) = _waiting.removeFirst();
      _running++;
      unawaited(() async {
        try {
          done.complete(
            decodeMarkdownTree(await native.parseMarkdown(source: source)),
          );
        } catch (error, stack) {
          done.completeError(error, stack);
        } finally {
          _running--;
          _bytes -= source.length * 2;
          _drain();
        }
      }());
    }
  }
}

/// Materialize the flat native tree without parsing Markdown or HTML again.
List<md.Node> decodeMarkdownTree(String encoded) {
  final input = jsonDecode(encoded) as List;
  final roots = <md.Node>[], nodes = <md.Node>[];
  for (final row in input.cast<List>()) {
    final parent = row[0] as int, tag = row[1] as String;
    final md.Node node;
    if (tag.isEmpty) {
      node = md.Text(row[2] as String);
    } else {
      final element = md.Element(tag, <md.Node>[]);
      final attrs = row[3] as List;
      for (var i = 0; i < attrs.length; i += 2) {
        element.attributes[attrs[i] as String] = attrs[i + 1] as String;
      }
      node = element;
    }
    if (parent < 0) {
      roots.add(node);
    } else {
      (nodes[parent] as md.Element).children!.add(node);
    }
    nodes.add(node);
  }
  return roots;
}
