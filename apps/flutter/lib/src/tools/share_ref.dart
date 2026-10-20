/// How a share is named outside the catalog: by an agent's tool call, or by
/// a `pocox://open` link in any text. Pure data, so the transcript model can
/// recognize a share without depending on any widget.
library;

import 'dart:convert';

import 'package:pocket_codex/src/service_key.dart';

/// A share as an agent's tool call or a link names it.
class ShareRef {
  /// Creates a reference.
  const ShareRef({
    required this.service,
    this.path = '/',
    this.title,
    this.ports = const [],
    this.secure = false,
    this.shareId,
  });

  /// The first port's relay key.
  final String service;

  /// The share's id on its device, when known (an agent's tool result): a
  /// later share of the same port is another share.
  final String? shareId;

  /// Path to open.
  final String path;

  /// Whether the page is served over TLS (an `https://localhost` link).
  final bool secure;

  /// The scheme the page opens with.
  String get scheme => secure ? 'https' : 'http';

  /// Title, when the tool call carried it.
  final String? title;

  /// Every port of the share, when known.
  final List<int> ports;

  /// The sharing device.
  String get device => parseServiceKey(service).device;

  /// The first port number.
  int? get port => int.tryParse(parseServiceKey(service).name);
}

// A link ends where a URL could not go on, including a backslash: one
// quoted in a JSON tool output is followed by its escapes (`\n`).
final _openLink = RegExp(r'pocox://open\?[^\s)\]"<>`\\]+');

/// The share a `pocox://open?service=…&path=…[&scheme=https]` link names.
ShareRef? parseOpenLink(String link) {
  final uri = Uri.tryParse(link.trim());
  if (uri == null || uri.scheme != 'pocox' || uri.host != 'open') return null;
  final service = uri.queryParameters['service'];
  if (service == null || parseServiceKey(service).kind != 'port') return null;
  final path = uri.queryParameters['path'];
  return ShareRef(
    service: service,
    path: (path == null || !path.startsWith('/')) ? '/' : path,
    secure: uri.queryParameters['scheme'] == 'https',
  );
}

/// The share a finished tool call announced: Codex's `pocox.connect` result,
/// or any tool output carrying a `pocox://open` link (ACP agents, OpenCode).
ShareRef? shareOfToolCall({
  required String type,
  required String title,
  required String text,
}) {
  if (!text.contains('pocox://open?')) return null;
  if (type == 'mcpToolCall' && title.endsWith('.connect')) {
    final shared = _structuredShare(text);
    if (shared != null) return shared;
  }
  final match = _openLink.firstMatch(text);
  return match == null ? null : parseOpenLink(match.group(0)!);
}

ShareRef? _structuredShare(String text) {
  try {
    final value = jsonDecode(text);
    final result = value is Map ? value['result'] : null;
    final structured = result is Map ? result['structuredContent'] : null;
    if (structured is! Map || structured['status'] != 'shared') return null;
    final service = structured['service'];
    if (service is! String || parseServiceKey(service).kind != 'port') {
      return null;
    }
    final share = structured['share'];
    if (share is! Map) return ShareRef(service: service);
    final ports = share['ports'];
    final path = share['path'];
    final title = share['title'];
    final id = share['id'];
    return ShareRef(
      service: service,
      shareId: id is String ? id : null,
      path: path is String && path.startsWith('/') ? path : '/',
      title: title is String ? title : null,
      secure: share['secure'] == true,
      ports: [
        if (ports is List)
          for (final port in ports)
            if (port is Map && port['port'] is int) port['port'] as int,
      ],
    );
  } catch (_) {
    return null;
  }
}
