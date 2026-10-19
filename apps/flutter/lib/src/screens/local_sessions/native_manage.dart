part of '../local_sessions_screen.dart';

/// What a row's menu does with a session of a manageable native source.
enum _NativeAction { rename, delete }

/// Renaming and deleting sessions of a manageable native source (Grok),
/// through the provider itself; it refuses while another client or a POCOX
/// host holds the session, and the reason is shown as is.
extension _NativeManage on _LocalSessionsState {
  Future<void> _manage(LocalSession session, _NativeAction action) async {
    final l10n = AppLocalizations.of(context);
    final toast = ToastMessenger.of(context);
    final api = ref.read(bridgeApiProvider);
    final provider = _source.provider;
    final sourceId = _sourceId;
    try {
      switch (action) {
        case _NativeAction.rename:
          final title = await _askTitle(session);
          if (title == null || !mounted) return;
          await api.appNativeSessionRename(
            provider,
            session.threadId,
            title,
            sourceId: sourceId,
          );
          toast.ok(l10n.nativeSessionRenamed);
        case _NativeAction.delete:
          if (!await _confirmDelete(session) || !mounted) return;
          await api.appNativeSessionDelete(
            provider,
            session.threadId,
            sourceId: sourceId,
          );
          toast.ok(l10n.nativeSessionDeleted);
      }
    } catch (e) {
      toast.error(friendlyError(e));
      return;
    }
    if (mounted) await _load();
  }

  Future<String?> _askTitle(LocalSession session) => showAppDialog<String>(
    context: context,
    builder: (_) => _RenameDialog(initial: session.preview.trim()),
  );

  Future<bool> _confirmDelete(LocalSession session) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l10n.nativeSessionDeleteTitle),
        content: Text(
          l10n.nativeSessionDeleteBody(nativeProviderName(_source.provider)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('native-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: Text(l10n.nativeSessionDelete),
          ),
        ],
      ),
    );
    return confirmed == true;
  }
}

/// A row's rename/delete menu.
class _NativeManageMenu extends StatelessWidget {
  const _NativeManageMenu({required this.session, required this.onSelected});

  final LocalSession session;
  final void Function(_NativeAction) onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<_NativeAction>(
      key: Key('native-manage-${session.threadId}'),
      tooltip: l10n.moreActions,
      icon: Icon(AppIcons.more_horiz, size: 18, color: scheme.onSurfaceVariant),
      style: IconButton.styleFrom(
        minimumSize: const Size(30, 30),
        fixedSize: const Size(30, 30),
        padding: EdgeInsets.zero,
      ),
      onSelected: onSelected,
      itemBuilder: (_) => [
        PopupMenuItem(
          key: const Key('native-rename'),
          value: _NativeAction.rename,
          child: Text(l10n.renameConversation),
        ),
        PopupMenuItem(
          key: const Key('native-delete'),
          value: _NativeAction.delete,
          child: Text(
            l10n.nativeSessionDelete,
            style: TextStyle(color: scheme.error),
          ),
        ),
      ],
    );
  }
}

/// Asks for a session's new title; answers it, or null when cancelled.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _title = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    Navigator.pop(context, title.isEmpty ? null : title);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.nativeSessionRenameTitle),
      content: TextField(
        key: const Key('native-rename-field'),
        controller: _title,
        autofocus: true,
        maxLength: 512,
        decoration: InputDecoration(
          labelText: l10n.renameConversationHint,
          counterText: '',
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('native-rename-save'),
          onPressed: _save,
          child: Text(l10n.save),
        ),
      ],
    );
  }
}
