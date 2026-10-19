/// The wire form of built-in tools picked for a message: a block at the end
/// of its text that names them for the agent (`<pocox_tools ids="…">`), read
/// back by every transcript and list preview. Pure, so text helpers can use
/// it without the composer's widgets.
library;

const _open = '<pocox_tools';
const _close = '</pocox_tools>';

/// The block the agent reads: `<pocox_tools ids="share,services">…`.
final _block = RegExp(
  r'\n*<pocox_tools ids="([A-Za-z0-9_,.\-]*)">[\s\S]*?</pocox_tools>\s*$',
);

/// The mark a truncated list preview ends with.
final _ellipsis = RegExp(r'(…|\.\.\.)$');

/// What the agent is told to call for the tools this app knows, and the
/// host's own summary of one it does not.
String _describe(String id, Map<String, String> summaries) => switch (id) {
  'services' => 'pocox `services`',
  'share' => 'pocox `connect`, action `share`',
  'connect' => 'pocox `connect`, action `connect`',
  _ => switch (summaries[id]?.replaceAll(RegExp(r'\s+'), ' ').trim()) {
    final summary? when summary.isNotEmpty => 'pocox: $summary',
    _ => 'pocox',
  },
};

/// [text] with the built-in tools [ids] the user picked for it, for the
/// agent; [text] itself when none are. [summaries] are the host's words for
/// its tools, by id: a tool newer than this app is described by them.
String appendBuiltinTools(
  String text,
  List<String> ids, {
  Map<String, String> summaries = const {},
}) {
  if (ids.isEmpty) return text;
  final named = [
    for (final id in ids) '$id (${_describe(id, summaries)})',
  ].join('; ');
  return '$text\n\n<pocox_tools ids="${ids.join(',')}">\n'
      'The user picked these POCOX tools for this request and allows them '
      'to run without asking again: $named.\n'
      '$_close';
}

/// [text] without the built-in tools block at its end, and the tools it
/// named.
({String text, List<String> ids}) splitBuiltinTools(String text) {
  final match = _block.firstMatch(text);
  if (match == null) return (text: text, ids: const <String>[]);
  return (
    text: text.substring(0, match.start).trimRight(),
    ids: [
      for (final id in match.group(1)!.split(','))
        if (id.trim().isNotEmpty) id.trim(),
    ],
  );
}

/// A list [preview] without the built-in tools block at its end, whole or
/// cut short: previews are the first message truncated (often with a closing
/// `…`), which can end inside the block or its opening tag.
String previewWithoutBuiltinTools(String preview) {
  if (_block.hasMatch(preview)) return splitBuiltinTools(preview).text;
  final open = preview.lastIndexOf(_open);
  if (open >= 0 &&
      (open == 0 || preview[open - 1].trim().isEmpty) &&
      !preview.contains(_close, open)) {
    return preview.substring(0, open).trimRight();
  }
  final at = preview.lastIndexOf('\n\n<');
  if (at >= 0 &&
      _open.startsWith(preview.substring(at + 2).replaceFirst(_ellipsis, ''))) {
    return preview.substring(0, at).trimRight();
  }
  return preview;
}
