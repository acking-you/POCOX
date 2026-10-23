/// The text convention for document/file attachments.
///
/// codex's input protocol carries only text and images inline; its native
/// document workflow is a FILE PATH in the prompt text that the agent reads
/// with its own tools (exactly what the TUI's `@file` mention inserts — a bare
/// path, double-quoted only when it contains whitespace). POCOX uploads
/// the controller-side file to the HOST first (over the meta tunnel), then
/// appends a reference block in that same convention:
///
/// ```text
/// <the user's message>
///
/// ## Attached files (read them from this machine's filesystem):
/// - "C:\Users\u\.codex\pocox-uploads\...-report with space.pdf"
/// - /home/u/.codex/pocox-uploads/...-notes.md
/// ```
///
/// The block is part of the sent text — it echoes back verbatim in history and
/// on other devices, so [splitFileRefs] can always rebuild the chips. The
/// header line is wire format: changing it orphans chips in old transcripts.
library;

import 'package:pocox/src/automation_prompt.dart';
import 'package:pocox/src/ide_context.dart';
import 'package:pocox/src/realtime_delegation.dart';
import 'package:pocox/src/tools/builtin_tags.dart';

/// Header line introducing the attached-files block (English on purpose — it
/// is model-facing wire text, like codex's own `<image>` markers).
const String kAttachedFilesHeader =
    "## Attached files (read them from this machine's filesystem):";

/// Header line introducing the attached-images block. Images also travel
/// inline as data URLs; this block only records where the HOST stored the
/// bytes for the agent's available image tools. It never assumes a particular
/// skill is installed. English on purpose — it is model-facing wire text.
const String kAttachedImagesHeader =
    "## Attached images (saved on the host; inspect with your available image tools):";

/// The most files one message may carry (UI guard).
const int kMaxFilesPerMessage = 4;

/// Per-file upload cap. Below the host's 64 MB request-body limit with
/// headroom, and tunnel-friendly on a mobile uplink.
const int kMaxFileBytes = 32 * 1024 * 1024;

/// Quote [path] like the codex TUI quotes an `@file` mention: double quotes
/// only when the path contains whitespace (and no quote of its own).
String quotePathLikeCodex(String path) {
  final hasWhitespace = path.contains(RegExp(r'\s'));
  if (hasWhitespace && !path.contains('"')) return '"$path"';
  return path;
}

/// Append the attached-files block for [hostPaths] to [text]. Returns [text]
/// unchanged when there is nothing to attach; the block alone when [text] is
/// empty (a files-only message).
String appendFileRefs(String text, List<String> hostPaths) {
  if (hostPaths.isEmpty) return text;
  final block = StringBuffer(kAttachedFilesHeader);
  for (final p in hostPaths) {
    block.write('\n- ${quotePathLikeCodex(p)}');
  }
  if (text.isEmpty) return block.toString();
  return '$text\n\n$block';
}

/// Append the trailing attachment blocks for [filePaths] and [imagePaths].
/// Files are written first and images second; [splitAttachmentRefs] strips
/// them in reverse order.
String appendAttachmentRefs(
  String text, {
  List<String> filePaths = const [],
  List<String> imagePaths = const [],
}) {
  var out = appendFileRefs(text, filePaths);
  if (imagePaths.isEmpty) return out;
  final block = StringBuffer(kAttachedImagesHeader);
  for (final p in imagePaths) {
    block.write('\n- ${quotePathLikeCodex(p)}');
  }
  if (out.isEmpty) return block.toString();
  return '$out\n\n$block';
}

/// One trailing `- path` block, or the input unchanged when it does not end in
/// a well-formed block for [header].
({String text, List<String> paths}) _splitTrailingBlock(
  String text,
  String header,
) {
  final at = text.lastIndexOf(header);
  if (at < 0) return (text: text, paths: const []);
  // The header must start its own line.
  if (at > 0 && text[at - 1] != '\n') return (text: text, paths: const []);
  final after = text.substring(at + header.length);
  final lines = after.split('\n');
  // First split element is the remainder of the header line — must be empty.
  if (lines.first.trim().isNotEmpty) return (text: text, paths: const []);
  final paths = <String>[];
  for (final line in lines.skip(1)) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (!t.startsWith('- ')) return (text: text, paths: const []);
    var p = t.substring(2).trim();
    if (p.length >= 2 && p.startsWith('"') && p.endsWith('"')) {
      p = p.substring(1, p.length - 1);
    }
    if (p.isNotEmpty) paths.add(p);
  }
  if (paths.isEmpty) return (text: text, paths: const []);
  return (text: text.substring(0, at).trimRight(), paths: paths);
}

/// Split a message's trailing attachment blocks back into display text and
/// host paths. Images are stripped first because [appendAttachmentRefs]
/// writes that block last.
({String text, List<String> filePaths, List<String> imagePaths})
splitAttachmentRefs(String text) {
  final images = _splitTrailingBlock(text, kAttachedImagesHeader);
  final files = _splitTrailingBlock(images.text, kAttachedFilesHeader);
  return (text: files.text, filePaths: files.paths, imagePaths: images.paths);
}

/// Back-compat view of [splitAttachmentRefs]: every stripped path, files
/// first. Callers that render chips should use [splitAttachmentRefs] so image
/// paths are not drawn twice next to their inline thumbnails.
({String text, List<String> paths}) splitFileRefs(String text) {
  final split = splitAttachmentRefs(text);
  return (text: split.text, paths: [...split.filePaths, ...split.imagePaths]);
}

/// Basename of a host path (either separator style), for chip labels.
String hostPathBasename(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 ? path : path.substring(cut + 1);
}

/// The folder name a project path is known by: its last non-empty segment
/// (a trailing separator ignored), or [path] itself when it has none.
String folderName(String path) {
  final segs = path.split(RegExp(r'[\\/]'))..removeWhere((s) => s.isEmpty);
  return segs.isEmpty ? path : segs.last;
}

/// Display form of a session/thread PREVIEW that may carry wire text. Server
/// previews are the first user message verbatim (possibly truncated), so
/// without this a list title reads as the raw attached-files header or the
/// serialized IDE context instead of what the user typed.
///
/// A preview that is nothing but an attachment block shows [placeholder];
/// otherwise the wrappers are stripped the same way the transcript strips
/// them. `startsWith` (not a full parse) is what catches server-truncated
/// blocks.
///
/// Returns EMPTY when the preview is an injected context fragment: a session
/// opened from an IDE begins with codex's own `<recommended_plugins>` message,
/// and calling that a title labelled every such session identically. There is
/// no title to derive from machinery, so callers fall back to "untitled".
String previewWithoutFileRefs(String preview, String placeholder) {
  if (preview.trimLeft().startsWith(kAttachedFilesHeader)) return placeholder;
  if (preview.trimLeft().startsWith(kAttachedImagesHeader)) return placeholder;
  if (isContextFragment(preview)) return '';
  if (isTruncatedIdeContext(preview)) return placeholder;
  // A voice handoff is the user's own turn, wrapped — show what they said.
  final spoken = parseRealtimeDelegation(preview)?.input;
  if (spoken != null && spoken.isNotEmpty) return spoken;
  // An automation's run reads as the task it set.
  final automation = AutomationPrompt.parse(preview);
  if (automation != null) return automation.instructions;
  final text = previewWithoutBuiltinTools(splitIdeContext(preview).text);
  final split = splitAttachmentRefs(text);
  return split.filePaths.isEmpty && split.imagePaths.isEmpty
      ? text
      : split.text;
}
