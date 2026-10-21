import 'package:flutter/material.dart';
import 'package:pocox/src/widgets/field_help.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';

/// Edits a historical prompt without modifying history or the current draft.
class MessageEditor extends StatefulWidget {
  /// Returns edited text only when the user explicitly adds it to the draft.
  const MessageEditor({super.key, required this.text, required this.hasDraft});

  /// The original user-visible prompt, without attachment metadata.
  final String text;

  /// Explains appending when there is already text or an attachment in draft.
  final bool hasDraft;

  @override
  State<MessageEditor> createState() => _MessageEditorState();
}

class _MessageEditorState extends State<MessageEditor> {
  late final _controller = TextEditingController(text: widget.text);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          leading: CloseButton(onPressed: () => Navigator.of(context).pop()),
          // What adding the text does (and does not do) is behind the
          // title's info mark.
          title: InfoTitle(
            title: Text(
              l10n.editMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            info: widget.hasDraft
                ? l10n.editMessageDraftHint
                : l10n.editMessageHint,
          ),
          actions: [
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, _) => TextButton(
                key: const Key('message-editor-add'),
                onPressed: value.text.trim().isEmpty
                    ? null
                    : () => Navigator.of(context).pop(_controller.text),
                child: Text(l10n.addToDraft),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: TextField(
              key: const Key('message-editor-input'),
              controller: _controller,
              autofocus: true,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
