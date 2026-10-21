// Only the official SDK's read-only exports are used. Never query or resume.
import { realpath, readdir, lstat, open } from 'node:fs/promises';
import { join, relative, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

const MAX_FILE = 64 * 1024 * 1024;
const MAX_TEXT = 512 * 1024;
const MAX_PAGE = 8 * 1024 * 1024;
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const fail = (code) => { throw { readerCode: code }; };
const hash = (value) => createHash('sha256').update(value).digest('hex');

function clipped(value, bytes) {
  const text = typeof value === 'string' ? value : '';
  const buffer = Buffer.from(text);
  if (buffer.length <= bytes) return { text, cut: false };
  let end = bytes;
  while ((buffer[end] & 0xc0) === 0x80) end--;
  return { text: buffer.subarray(0, end).toString() + '\n[… truncated]', cut: true };
}

function blocks(message) {
  const content = message.message?.content;
  if (typeof content === 'string') return [{ type: 'text', text: content }];
  return Array.isArray(content) ? content : [];
}

function isPrompt(message) {
  return message.type === 'user' && blocks(message).some((block) =>
    ['text', 'image', 'document'].includes(block.type));
}

function item(id, kind, text = '') {
  const value = clipped(text, MAX_TEXT);
  return { id, kind, title: '', text: value.text, images: [],
    truncated: value.cut, textFull: value.cut, omitted: [] };
}

function omit(target, reason) {
  target.truncated = true;
  if (!target.omitted.includes(reason)) target.omitted.push(reason);
}

function appendText(target, text) {
  if (target.textFull) return;
  const value = clipped(target.text + text, MAX_TEXT);
  target.text = value.text;
  target.textFull = value.cut;
  target.truncated ||= value.cut;
}

function publicContent(target, content) {
  if (typeof content === 'string') { appendText(target, content); return; }
  for (const block of Array.isArray(content) ? content : []) {
    if (block.type === 'text') appendText(target, block.text || '');
    else if (block.type === 'image') {
      const source = block.source;
      const image = source?.type === 'base64' && /^image\/(png|jpeg|gif|webp)$/.test(source.media_type)
        ? `data:${source.media_type};base64,${source.data}` : null;
      const used = target.images.reduce((size, image) => size + image.length, 0);
      if (image && target.images.length < 8 && used + image.length <= 2 * 1024 * 1024)
        target.images.push(image);
      else omit(target, 'images');
    } else if (block.type === 'document') {
      appendText(target, `\n[${clipped(block.title || 'Document', 1024).text}]\n`);
      if (block.source?.type === 'text') appendText(target, block.source.data || '');
      else omit(target, 'document preview');
    }
    // Thinking, redacted thinking and signatures are never projected.
  }
}

function projectTurn(messages) {
  const turn = { id: `native:${messages[0].uuid}`, items: [], outcome: null,
    replayed: true, nextItem: 0, omitted: 0 };
  const tools = new Map();
  for (const message of messages) {
    if (message.type === 'system') {
      // System payloads can contain internal instructions. Display only a
      // compaction boundary marker, not arbitrary system content.
      if (message.message?.subtype === 'compact_boundary')
        turn.items.push(item(`native:${message.uuid}`, 'agent_message', '[Earlier context compacted]'));
      continue;
    }
    let ordinal = 0;
    for (const block of blocks(message)) {
      const id = `native:${message.uuid}:${ordinal++}`;
      if (turn.items.length >= 4000) { turn.omitted++; continue; }
      if (block.type === 'tool_use') {
        const target = item(id, 'tool_call');
        target.title = clipped(block.name || 'Tool', 4096).text;
        const input = JSON.stringify(block.input ?? null);
        target.tool = { callId: String(block.id || id), kind: 'other', status: 'pending',
          name: target.title, locations: [], diffs: [], terminals: 0,
          rawInput: Buffer.byteLength(input) <= 64 * 1024 ? block.input : null };
        if (Buffer.byteLength(input) > 64 * 1024) omit(target, 'input');
        tools.set(block.id, target);
        turn.items.push(target);
      } else if (block.type === 'tool_result') {
        let target = tools.get(block.tool_use_id);
        if (!target) {
          target = item(id, 'tool_call');
          target.title = 'Tool result';
          target.tool = { callId: String(block.tool_use_id || id), kind: 'other',
            name: null, locations: [], diffs: [], rawInput: null, terminals: 0 };
          turn.items.push(target);
        }
        target.tool.status = block.is_error ? 'failed' : 'completed';
        publicContent(target, block.content);
      } else if (['text', 'image', 'document'].includes(block.type)) {
        const target = item(id, message.type === 'user' ? 'user_message' : 'agent_message');
        publicContent(target, [block]);
        turn.items.push(target);
      }
    }
  }
  turn.nextItem = turn.items.length + turn.omitted;
  return turn;
}

// Kept separate for fixtures: canonical branch selection remains the SDK's job.
export function projectPage(messages, before, limit) {
  const groups = [];
  for (const message of messages) {
    if (!uuid.test(message.uuid || '')) continue;
    if (isPrompt(message) || groups.length === 0) groups.push([]);
    groups.at(-1).push(message);
  }
  const end = before == null ? groups.length
    : groups.findIndex((group) => `native:${group[0].uuid}` === before);
  if (end < 0) fail('invalid_cursor');
  const start = Math.max(0, end - limit);
  const turns = groups.slice(start, end).map(projectTurn);
  // Keep the requested turn boundaries and explicit omissions, rather than
  // pretending a shortened page is the start of history.
  let size = Buffer.byteLength(JSON.stringify(turns));
  for (const turn of turns) {
    while (size > MAX_PAGE && turn.items.length > 1) {
      const index = turn.items[0].kind === 'user_message' ? 1 : 0;
      size -= Buffer.byteLength(JSON.stringify(turn.items[index]));
      turn.items.splice(index, 1);
      turn.omitted++;
    }
    if (size <= MAX_PAGE) break;
    for (const target of turn.items) {
      const previous = Buffer.byteLength(JSON.stringify(target));
      target.text = clipped(target.text, 4096).text;
      target.images = [];
      if (target.tool) target.tool.rawInput = null;
      omit(target, 'page size limit');
      size -= previous - Buffer.byteLength(JSON.stringify(target));
    }
  }
  return { turns, hasOlder: start > 0,
    nextBefore: start > 0 ? turns[0].id : null,
    totalTurns: groups.length,
    truncated: turns.some((turn) => turn.omitted > 0 || turn.items.some((item) => item.truncated)) };
}

async function transcript(root, session) {
  if (!uuid.test(session)) fail('not_found');
  const projects = await realpath(join(root, 'projects'));
  const dirs = await readdir(projects, { withFileTypes: true });
  if (dirs.length > 10000) fail('source_too_large');
  let found;
  for (const dir of dirs) {
    if (!dir.isDirectory() || dir.isSymbolicLink()) continue;
    const path = join(projects, dir.name, `${session}.jsonl`);
    let stat;
    try { stat = await lstat(path, { bigint: true }); }
    catch (error) { if (error.code === 'ENOENT') continue; throw error; }
    if (!stat.isFile() || stat.isSymbolicLink()) continue;
    const canonical = await realpath(path);
    const rel = relative(projects, canonical);
    if (rel.startsWith('..') || isAbsolute(rel)) continue;
    if (found) fail('not_found'); // Ambiguous copies must not alias one source.
    found = { path: canonical, stat };
  }
  if (!found) fail('not_found');
  if (found.stat.size > BigInt(MAX_FILE)) fail('source_too_large');
  const file = await open(found.path, 'r');
  try {
    const buffer = Buffer.alloc(4096);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
    const prefix = buffer.subarray(0, bytesRead);
    const newline = prefix.indexOf(10);
    found.head = hash(newline >= 0 ? prefix.subarray(0, newline) : prefix);
  } finally { await file.close(); }
  return found;
}

function stamp(source) {
  const stat = source.stat;
  const identity = `${source.path}:${stat.dev}:${stat.ino}:${stat.birthtimeNs}:${source.head}`;
  return { generation: hash(identity), revision: hash(`${identity}:${stat.size}:${stat.mtimeNs}:${stat.ctimeNs}`),
    sourceBytes: Number(stat.size) };
}

async function read(request) {
  if (!isAbsolute(request.sdk) || !isAbsolute(request.root)) fail('unavailable');
  if (!Number.isInteger(request.limit) || request.limit < 1 || request.limit > 100) fail('unavailable');
  if (request.action === 'list') {
    const offset = request.offset ?? 0;
    if (!Number.isInteger(offset) || offset < 0 || offset > 100000) fail('invalid_cursor');
    const { listSessions } = await import(pathToFileURL(request.sdk).href);
    const sessions = await listSessions({ limit: request.limit + 1, offset,
      includeWorktrees: false, includeProgrammatic: true });
    return { sessions: sessions.slice(0, request.limit).map((info) => ({
      sessionId: info.sessionId, cwd: clipped(info.cwd || '', 16384).text,
      title: clipped(info.customTitle || info.summary || info.firstPrompt || '', 4096).text,
      updatedAt: new Date(info.lastModified).toISOString(),
    })), nextCursor: sessions.length > request.limit ? String(offset + request.limit) : null };
  }
  const source = await transcript(request.root, request.session);
  const before = stamp(source);
  if (request.action === 'revision') return before;
  const { getSessionInfo, getSessionMessages } = await import(pathToFileURL(request.sdk).href);
  const info = await getSessionInfo(request.session);
  if (!info || info.sessionId !== request.session) fail('not_found');
  const messages = await getSessionMessages(request.session, { includeSystemMessages: true });
  let page;
  if (request.turn) {
    // Locate the next prompt without projecting every older message. Its
    // exclusive cursor selects the desired turn via the ordinary paginator.
    const start = messages.findIndex((message) => `native:${message.uuid}` === request.turn);
    if (start < 0) fail('invalid_cursor');
    const next = messages.slice(start + 1).find(isPrompt);
    page = next ? projectPage(messages, `native:${next.uuid}`, 1) : projectPage(messages, null, 1);
    if (page.turns[0]?.id !== request.turn) fail('invalid_cursor');
  } else page = projectPage(messages, request.before, request.limit);
  const after = stamp(await transcript(request.root, request.session));
  if (after.revision !== before.revision) fail('source_changed');
  return { ...before, ...page, sessionId: request.session,
    cwd: clipped(info.cwd || '', 16384).text,
    title: clipped(info.customTitle || info.summary || info.firstPrompt || '', 4096).text,
    updatedAt: info.lastModified };
}

if (process.argv[1] === '--pcx-read') {
  try {
    let input = '';
    for await (const chunk of process.stdin) {
      input += chunk;
      if (Buffer.byteLength(input) > 65536) fail('unavailable');
    }
    const result = await read(JSON.parse(input));
    process.stdout.write(JSON.stringify(result));
  } catch (error) {
    const known = ['not_found', 'source_changed', 'invalid_cursor', 'source_too_large'];
    process.stdout.write(JSON.stringify({ error: known.includes(error.readerCode) ? error.readerCode : 'unavailable' }));
  }
}
