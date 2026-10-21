import assert from 'node:assert/strict';
import { test } from 'node:test';
import { projectPage } from './claude_reader.mjs';

const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const message = (n, type, content) => ({ uuid: id(n), type, message: { content } });

test('turn cursors keep prompts, tool results and stable item identities', () => {
  const messages = [
    message(1, 'user', 'first'),
    message(2, 'assistant', [{ type: 'tool_use', id: 'tool1', name: 'Read', input: { path: 'fixture' } }]),
    message(3, 'user', [{ type: 'tool_result', tool_use_id: 'tool1', content: 'result' }]),
    message(4, 'assistant', 'done'),
    message(5, 'user', 'second'), message(6, 'assistant', 'next'),
  ];
  const tail = projectPage(messages, null, 1);
  assert.equal(tail.turns.length, 1);
  assert.equal(tail.turns[0].id, `native:${id(5)}`);
  assert.equal(tail.hasOlder, true);
  const older = projectPage(messages, tail.nextBefore, 1);
  assert.equal(older.hasOlder, false);
  assert.equal(older.turns[0].items[1].tool.status, 'completed');
  assert.equal(older.turns[0].items[1].text, 'result');
  assert.equal(older.turns[0].items.length, 3);
  const appended = projectPage([...messages, message(7, 'assistant', 'append')], tail.nextBefore, 1);
  assert.deepEqual(appended, { ...older, totalTurns: 2 });
  assert.throws(() => projectPage(messages, 'missing', 1), (error) => error.readerCode === 'invalid_cursor');
});

test('hidden reasoning and arbitrary system messages never reach the view', () => {
  const page = projectPage([
    message(1, 'user', 'prompt'),
    message(2, 'system', 'private instructions'),
    message(3, 'assistant', [
      { type: 'thinking', thinking: 'private thought', signature: 'secret signature' },
      { type: 'redacted_thinking', data: 'private bytes' },
      { type: 'text', text: 'public reply' },
    ]),
  ], null, 20);
  const json = JSON.stringify(page);
  assert.equal(page.turns[0].items.length, 2);
  assert.match(json, /public reply/);
  assert.doesNotMatch(json, /private|signature/);
});

test('attachments keep inline bytes and explicitly mark unavailable documents', () => {
  const page = projectPage([message(1, 'user', [
    { type: 'text', text: 'look' },
    { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'YWJj' } },
    { type: 'document', title: 'report', source: { type: 'base64', data: 'not displayed' } },
  ])], null, 20);
  assert.deepEqual(page.turns[0].items[1].images, ['data:image/png;base64,YWJj']);
  assert.equal(page.turns[0].items[2].truncated, true);
  assert.equal(page.truncated, true);
});

test('large pages and UTF-8 text remain bounded with visible omissions', () => {
  const messages = Array.from({ length: 100 }, (_, n) => message(n + 1, 'user', '文'.repeat(300000)));
  const page = projectPage(messages, null, 100);
  assert.equal(page.turns.length, 100);
  assert.ok(Buffer.byteLength(JSON.stringify(page)) < 9 * 1024 * 1024);
  assert.equal(page.truncated, true);
  assert.doesNotMatch(JSON.stringify(page), /�/);
});
