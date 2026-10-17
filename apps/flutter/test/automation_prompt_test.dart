import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/attachment_refs.dart';
import 'package:pocket_codex/src/automation_prompt.dart';

void main() {
  const heartbeat =
      '<heartbeat>\n'
      '  <automation_id>clickhouse-pr-ci</automation_id>\n'
      '  <current_time_iso>2026-10-12T11:13:22.109Z</current_time_iso>\n'
      '  <instructions>\n'
      'Check the new CI of PR #114335.\n'
      '  </instructions>\n'
      '</heartbeat>';

  test('an automation run reads as its automation and task', () {
    final prompt = AutomationPrompt.parse(heartbeat)!;
    expect(prompt.automation, 'clickhouse-pr-ci');
    expect(prompt.instructions, 'Check the new CI of PR #114335.');
    expect(prompt.at, DateTime.utc(2026, 10, 12, 11, 13, 22, 109).toLocal());
    // Previews (sidebar, rail) name the task rather than the envelope.
    expect(
      previewWithoutFileRefs(heartbeat, '[file]'),
      'Check the new CI of PR #114335.',
    );
    // A message that merely mentions the tag is the user's own.
    expect(AutomationPrompt.parse('what is <heartbeat>?'), isNull);
  });
}
