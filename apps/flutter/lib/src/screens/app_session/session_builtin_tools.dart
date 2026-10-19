part of '../app_session_screen.dart';

/// The `+` menu's control, for hanging the tools panel from it.
final _attachAnchors = Expando<GlobalKey>('attach menu');

/// Built-in tools picked in the composer for the next message (see
/// `tools/builtin_tools.dart`): chips above the field, a block at the end of
/// the sent text, and a grant of the gated ones to the conversation.
extension _SessionBuiltinTools on _AppSessionState {
  List<String> get _tools => _draft.tools;

  GlobalKey get _attachAnchor => _attachAnchors[this] ??= GlobalKey();

  /// What this conversation's host offers (nothing while its tools are off
  /// or its catalog has not answered).
  List<ToolsBuiltinTool> _hostTools({bool watch = false}) => hostBuiltinTools(
    watch ? ref.watch(toolsOverviewProvider) : ref.read(toolsOverviewProvider),
    widget.serviceKey,
  );

  /// The host's words for its tools, by id, for the block the agent reads.
  Map<String, String> _hostToolSummaries() => {
    for (final tool in _hostTools()) tool.id: tool.summary,
  };

  Future<void> _pickBuiltinTools() async {
    final tools = _hostTools();
    if (tools.isEmpty) return;
    final draft = _draft;
    final box = _attachAnchor.currentContext?.findRenderObject() as RenderBox?;
    await showBuiltinToolsPanel(
      context: context,
      tools: tools,
      picked: draft.tools,
      anchor: box != null && box.attached
          ? box.localToGlobal(Offset.zero) & box.size
          : null,
      onChanged: (ids) {
        draft.tools
          ..clear()
          ..addAll(ids);
        _drafts.save(draft, changed: true);
      },
    );
  }

  Widget _builtinToolsStrip() => Align(
    alignment: AlignmentDirectional.centerStart,
    child: BuiltinToolChips(
      ids: _tools,
      titles: {for (final tool in _hostTools()) tool.id: tool.title},
      onRemove: (id) {
        _tools.remove(id);
        _drafts.save(_draft, changed: true);
      },
    ),
  );

  /// Hand the tools picked for a message to its conversation before its
  /// turn starts: a gated one then needs no consent prompt there. A failure
  /// (an older or unreachable host) leaves the agent's prompt in place.
  Future<void> _grantBuiltinTools(
    String service,
    String thread,
    List<String> tools,
  ) async {
    if (tools.isEmpty) return;
    try {
      await ref
          .read(bridgeApiProvider)
          .toolsGrant(service, thread, tools)
          .timeout(const Duration(seconds: 8));
    } catch (error) {
      debugPrint('built-in tools not granted: $error');
    }
  }
}
