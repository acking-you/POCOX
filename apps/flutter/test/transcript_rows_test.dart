import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/src/screens/app_session/activity_cards.dart';
import 'package:pocox/src/screens/app_session/transcript_model.dart';
import 'package:pocox/src/screens/app_session/transcript_rows.dart';

void main() {
  test('a partial next turn cannot swallow the previous final answer', () {
    final reply = TranscriptItem(
      id: 'reply',
      type: 'agentMessage',
      text: 'done',
      turnId: 'old',
    );
    final rows = buildTranscriptRows([
      TranscriptItem(id: 'old-tool', type: 'commandExecution', turnId: 'old'),
      reply,
      TranscriptItem(id: 'new-tool', type: 'commandExecution', turnId: 'new'),
    ]);
    expect(rows, hasLength(3));
    expect(rows[1], same(reply));
    expect((rows.first as TurnWork).items.single.id, 'old-tool');
    expect((rows.last as TurnWork).items.single.id, 'new-tool');
  });

  test('a long preamble is grouped in one linear pass', () {
    final items = [
      TranscriptItem(id: 'user', type: 'userMessage'),
      for (var i = 0; i < 20000; i++)
        TranscriptItem(id: 'p$i', type: 'agentMessage', text: 'progress'),
      TranscriptItem(id: 'tool', type: 'commandExecution'),
      TranscriptItem(id: 'answer', type: 'agentMessage', text: 'done'),
    ];
    final timer = Stopwatch()..start();
    final rows = buildTranscriptRows(items);
    timer.stop();
    // Diagnostic only: correctness must not depend on the CI machine's speed.
    // ignore: avoid_print
    print('20,003 items grouped in ${timer.elapsedMicroseconds} μs');
    expect(rows, hasLength(3));
    expect((rows[1] as TurnWork).items, hasLength(20001));
    expect(identical(rows.last, items.last), isTrue);
  });

  test('final replies stay separate across known turn boundaries', () {
    final rows = buildTranscriptRows([
      TranscriptItem(id: 'a', type: 'agentMessage', text: 'a', turnId: 'one'),
      TranscriptItem(id: 'b', type: 'agentMessage', text: 'b', turnId: 'one'),
      TranscriptItem(id: 'c', type: 'agentMessage', text: 'c', turnId: 'two'),
    ]);
    expect(rows, hasLength(2));
    expect((rows.first as AgentTurn).items.map((item) => item.id), ['a', 'b']);
    expect((rows.last as TranscriptItem).id, 'c');
  });

  test('a reply with nothing in it leaves no row', () {
    // A quiet automation run: a preamble, its work, then an empty answer.
    final rows = buildTranscriptRows([
      TranscriptItem(id: 'run', type: 'userMessage', turnId: 'one'),
      TranscriptItem(
        id: 'say',
        type: 'agentMessage',
        text: 'checking',
        turnId: 'one',
      ),
      TranscriptItem(id: 'tool', type: 'commandExecution', turnId: 'one'),
      TranscriptItem(
        id: 'end',
        type: 'agentMessage',
        text: ' \n',
        turnId: 'one',
      ),
    ]);
    expect(rows, hasLength(2));
    expect((rows.last as TurnWork).items.map((item) => item.id), [
      'say',
      'tool',
    ]);
  });
}
