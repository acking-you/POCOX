/// The wire form of built-in tools picked for a message: a block at the end
/// of its text that names them for the agent (`<pocox_tools ids="…">`), read
/// back by every transcript and list preview. Pure, so text helpers can use
/// it without the composer's widgets.
library;

/// The block the agent reads: `<pocox_tools ids="share,services">…`.
final _block = RegExp(
  r'\n*<pocox_tools ids="([A-Za-z0-9_,.\-]*)">[\s\S]*?</pocox_tools>\s*$',
);

/// What the agent is told to call for the tools this app knows.
String _call(String id) => switch (id) {
  'services' => 'pocox `services`',
  'share' => 'pocox `connect`, action `share`',
  'connect' => 'pocox `connect`, action `connect`',
  _ => 'pocox',
};

/// [text] with the built-in tools [ids] the user picked for it, for the
/// agent; [text] itself when none are.
String appendBuiltinTools(String text, List<String> ids) {
  if (ids.isEmpty) return text;
  final named = [for (final id in ids) '$id (${_call(id)})'].join('; ');
  return '$text\n\n<pocox_tools ids="${ids.join(',')}">\n'
      'The user picked these POCOX tools for this request and allows them '
      'to run without asking again: $named.\n'
      '</pocox_tools>';
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
