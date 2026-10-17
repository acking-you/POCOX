/// A turn an automation started rather than the user.
///
/// Codex Desktop's scheduled automations send their instructions as a user
/// message wrapped in a `<heartbeat>` envelope:
///
/// ```text
/// <heartbeat>
///   <automation_id>…</automation_id>
///   <current_time_iso>2026-10-12T11:13:22.109Z</current_time_iso>
///   <instructions>
/// …
///   </instructions>
/// </heartbeat>
/// ```
///
/// As Markdown that whole block is raw HTML, which renders as nothing, so a
/// transcript shows it as what it is: an automation's run and its task.
class AutomationPrompt {
  /// Creates a parsed prompt.
  const AutomationPrompt({
    required this.automation,
    required this.instructions,
    this.at,
  });

  /// The automation's id, as Codex Desktop names it.
  final String automation;

  /// What the automation asked for.
  final String instructions;

  /// When it ran, if the envelope says.
  final DateTime? at;

  static final _field = RegExp(
    r'<(automation_id|current_time_iso|instructions)>([\s\S]*?)</\1>',
  );

  /// The prompt [text] carries, or null when it is not an automation's.
  static AutomationPrompt? parse(String text) {
    final body = text.trim();
    if (!body.startsWith('<heartbeat>')) return null;
    final fields = {
      for (final m in _field.allMatches(body)) m.group(1)!: m.group(2)!.trim(),
    };
    final automation = fields['automation_id'];
    if (automation == null || automation.isEmpty) return null;
    final at = fields['current_time_iso'];
    return AutomationPrompt(
      automation: automation,
      instructions: fields['instructions'] ?? '',
      at: at == null ? null : DateTime.tryParse(at)?.toLocal(),
    );
  }
}
