import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/glass.dart';
import 'package:pocket_codex/src/widgets/markdown_view.dart';
import 'package:pocket_codex/src/widgets/window_title_bar.dart';

/// What the expanded editor shows: the source, the rendered draft, or both
/// side by side.
enum _EditorView { write, split, preview }

/// A full-screen editing surface sharing the compact composer's draft, with a
/// live Markdown preview: beside the source on a wide window, a tab away on
/// a narrow one. The preview renders the draft the way its message will
/// read in the conversation, line breaks included.
class ExpandedComposer extends StatefulWidget {
  /// Opens an editor using the caller's controller and focus node.
  const ExpandedComposer({
    super.key,
    required this.controller,
    required this.focusNode,
  });

  /// The shared draft, including its current selection.
  final TextEditingController controller;

  /// Focus owned and disposed by the session screen.
  final FocusNode focusNode;

  /// Windows at least this wide open with the preview beside the source.
  static const double splitWidth = 900;

  @override
  State<ExpandedComposer> createState() => _ExpandedComposerState();
}

class _ExpandedComposerState extends State<ExpandedComposer> {
  /// The view the user picked; null follows the window's width.
  _EditorView? _picked;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final wide =
        MediaQuery.sizeOf(context).width >= ExpandedComposer.splitWidth;
    var view = _picked ?? (wide ? _EditorView.split : _EditorView.write);
    if (!wide && view == _EditorView.split) view = _EditorView.write;
    final editor = _editor(context, l10n);
    final preview = _MarkdownPreview(
      controller: widget.controller,
      emptyHint: view == _EditorView.split
          ? l10n.composerPreviewEmpty
          : l10n.composerPreviewEmptyTab,
    );
    return Dialog.fullscreen(
      backgroundColor: sheetColor(scheme),
      child: SafeArea(
        child: Column(
          children: [
            _header(context, l10n, view, wide: wide),
            Divider(height: 1, color: scheme.outlineVariant),
            Expanded(
              child: switch (view) {
                _EditorView.write => editor,
                _EditorView.preview => preview,
                _EditorView.split => Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: editor),
                    VerticalDivider(width: 1, color: scheme.outlineVariant),
                    // On the conversation's own surface, so code plates and
                    // quotes read exactly as they will there.
                    Expanded(child: preview),
                  ],
                ),
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The editor fills the window, so its header is the window's strip:
  /// clear of the traffic lights, centred on their line, and draggable
  /// where it is empty. It holds the view switcher and Done.
  Widget _header(
    BuildContext context,
    AppLocalizations l10n,
    _EditorView view, {
    required bool wide,
  }) {
    final controlHeight = isDesktop ? 34.0 : 40.0;
    return SizedBox(
      height: isFramelessDesktop ? WindowChrome.barHeight : 64,
      child: Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [
          const Positioned.fill(child: WindowDragArea()),
          Padding(
            padding: EdgeInsets.fromLTRB(
              20 + WindowChrome.leadingInset,
              0,
              16,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.editMessage,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                GlassSegmented<_EditorView>(
                  key: const Key('composer-editor-view'),
                  expand: false,
                  height: controlHeight,
                  selected: view,
                  onChanged: (v) => setState(() => _picked = v),
                  segments: [
                    GlassSegment(
                      key: const Key('composer-editor-write'),
                      value: _EditorView.write,
                      label: l10n.composerWrite,
                    ),
                    if (wide)
                      GlassSegment(
                        key: const Key('composer-editor-split'),
                        value: _EditorView.split,
                        label: l10n.composerSplit,
                      ),
                    GlassSegment(
                      key: const Key('composer-editor-preview'),
                      value: _EditorView.preview,
                      label: l10n.composerPreview,
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                FilledButton(
                  key: const Key('composer-editor-done'),
                  // On touch, drawn at the switcher's height inside a full
                  // touch target.
                  style: isDesktop
                      ? null
                      : FilledButton.styleFrom(
                          minimumSize: Size(64, controlHeight),
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          tapTargetSize: MaterialTapTargetSize.padded,
                        ),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.done),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _editor(BuildContext context, AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
    child: TextField(
      key: const Key('composer-expanded-input'),
      controller: widget.controller,
      focusNode: widget.focusNode,
      autofocus: true,
      expands: true,
      minLines: null,
      maxLines: null,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: InputDecoration(
        hintText: l10n.messageHint,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
        contentPadding: EdgeInsets.zero,
      ),
    ),
  );
}

/// The draft rendered as its message will read, following every keystroke.
class _MarkdownPreview extends StatelessWidget {
  const _MarkdownPreview({required this.controller, required this.emptyHint});

  final TextEditingController controller;
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final text = controller.text;
        if (text.trim().isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                emptyHint,
                key: const Key('composer-preview-empty'),
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
          );
        }
        return SelectionArea(
          child: SingleChildScrollView(
            key: const Key('composer-preview'),
            padding: const EdgeInsets.fromLTRB(28, 22, 28, 28),
            // A reading column, as the conversation sets it.
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: SizedBox(
                  width: double.infinity,
                  child: MarkdownView(data: text, keepLineBreaks: true),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
