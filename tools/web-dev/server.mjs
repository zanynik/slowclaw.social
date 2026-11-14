#!/usr/bin/env node
// Work on the website without an iPhone: serves ../../web in local mode with sample data.
//
//   node tools/web-dev/server.mjs        then open http://localhost:8787
//
// It answers the same /api routes as ios-app/SlowClawApp/Sync/LocalServer.swift (pairing is
// approved at once, edits are kept in memory). No dependencies; nothing here ships to users.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../web/', import.meta.url));
const port = Number(process.env.PORT || 8787);
const ago = (days, hour = 9) => { const d = new Date(Date.now() - days * 864e5); d.setHours(hour, 12, 0, 0); return d.toISOString(); };
const row = (extra, days = 0, hour) => ({ created_at: ago(days, hour), updated_at: ago(days, hour), deleted: false, ...extra });

const data = {
  device: 'Sample iPhone',
  spaces: [
    row({ id: 'space_work', name: 'Work', icon: 'briefcase', sort_order: 0, summary: 'The launch plan is settling: a smaller first release, then weekly updates.' }, 30),
    row({ id: 'space_health', name: 'Health', icon: 'heart', sort_order: 1, summary: '' }, 30),
    row({ id: 'space_ideas', name: 'Ideas & Projects', icon: 'lightbulb', sort_order: 2, summary: '' }, 30),
  ],
  journals: [
    row({ id: 'journal_1', title: 'Planning the week', body: 'Three things matter this week: finish the draft, call user_a about the venue, and take Friday off.\n\nThe draft is the one I keep avoiding.', space_id: 'space_work' }, 0, 8),
    row({ id: 'journal_2', title: '', body: 'Slept badly, but the morning walk helped. I want to keep the walks even when it rains.', space_id: 'space_health' }, 0, 7),
    row({ id: 'journal_3', title: 'A reading group', body: 'What if the reading group met every second week and each person brought one page they loved?', space_id: 'space_ideas' }, 1, 21),
    row({ id: 'journal_4', title: 'Loose thought', body: 'Not filed anywhere yet.', space_id: null }, 3, 12),
  ],
  space_items: [
    row({ id: 'item_1', space_id: 'space_work', journal_id: 'journal_1', kind: 'todo', text: 'Finish the draft', done: false }, 0),
    row({ id: 'item_2', space_id: 'space_work', journal_id: 'journal_1', kind: 'todo', text: 'Call user_a about the venue', done: false }, 0),
    row({ id: 'item_3', space_id: 'space_work', journal_id: null, kind: 'todo', text: 'Book Friday off', done: true }, 1),
    row({ id: 'item_4', space_id: 'space_health', journal_id: 'journal_2', kind: 'todo', text: 'Buy a rain jacket', done: false }, 0),
    row({ id: 'item_5', space_id: 'space_ideas', journal_id: 'journal_3', kind: 'idea', text: 'Reading group: one loved page each', done: false }, 1),
    row({ id: 'item_6', space_id: 'space_ideas', journal_id: 'journal_3', kind: 'question', text: 'Who would host the first evening?', done: false }, 1),
  ],
  book_nodes: [
    row({ id: 'node_1', journal_id: 'journal_1', kind: 'passage', text: 'The draft is the one I keep avoiding. Three things matter this week, and it is the only one that scares me.', position: 1, chapter: 0, chapter_title: 'Draft & Week' }, 0),
    row({ id: 'node_2', journal_id: 'journal_2', kind: 'passage', text: 'Slept badly, but the morning walk helped. I want to keep the walks even when it rains.', position: 2, chapter: 1, chapter_title: 'Morning walk' }, 0),
    row({ id: 'node_3', journal_id: 'journal_3', kind: 'passage', text: 'What if the reading group met every second week and each person brought one page they loved?', position: 3, chapter: 1, chapter_title: 'Morning walk' }, 1),
  ],
  news: [
    { id: 'card_1', topic: 'Draft & Week', headline: 'Why short deadlines help writers finish', summary: '', has_image: false, sources: 'Example News', newest: ago(0),
      articles: [{ title: 'Why short deadlines help writers finish', source: 'Example News', url: 'https://example.com/deadlines' }] },
  ],
  videos: [
    { label: 'Morning walk', videos: [{ id: 'aaaaaaaaaaa', title: 'What walking does to the brain', channel: 'Example Channel' }] },
  ],
  reads: [
    { label: 'Morning walk', articles: [{ id: 'a:1', title: 'On going slowly', author: 'user_a', summary: 'An essay on attention, weather and the habit of walking the same road.', minutes: 9, published: ago(4), url: 'https://example.com/slowly' }] },
  ],
};

const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.json': 'application/json' };
const send = (res, status, body, type = 'application/json') => { res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store' }); res.end(body); };
const json = (res, value, status = 200) => send(res, status, JSON.stringify(value));

async function body(req) {
  let raw = '';
  for await (const chunk of req) raw += chunk;
  try { return JSON.parse(raw || '{}'); } catch { return {}; }
}

createServer(async (req, res) => {
  const path = new URL(req.url, 'http://localhost').pathname;
  if (path === '/mode.js') return send(res, 200, "window.SLOWCLAW_MODE = 'local';\n", 'text/javascript');
  if (path === '/api/pair/start') return json(res, { ok: true, expires: Date.now() / 1000 + 180 });
  if (path === '/api/pair/poll') return json(res, { token: 'dev', device: data.device });
  if (path.startsWith('/api/')) {
    if (req.headers.authorization !== 'Bearer dev') return json(res, { error: 'pair this browser first' }, 401);
    if (path === '/api/data') {
      const live = list => list.filter(r => !r.deleted);
      return json(res, { ...data, journals: live(data.journals), spaces: live(data.spaces), space_items: live(data.space_items) });
    }
    if (path === '/api/signout') return json(res, { ok: true });
    if (path === '/api/save' && req.method === 'POST') {
      const { table, row: incoming } = await body(req);
      const list = data[table];
      if (!Array.isArray(list) || !incoming?.id || !['journals', 'spaces', 'space_items'].includes(table)) return json(res, { error: 'could not save' }, 400);
      const i = list.findIndex(r => r.id === incoming.id);
      const saved = { ...(i >= 0 ? list[i] : {}), ...incoming };
      if (i >= 0) list[i] = saved; else list.push(saved);
      return json(res, { row: saved });
    }
    return json(res, { error: 'not found' }, 404);
  }
  const file = normalize(join(root, path === '/' ? 'index.html' : path));
  if (!file.startsWith(root)) return json(res, { error: 'not found' }, 404);
  try { send(res, 200, await readFile(file), types[extname(file)] || 'application/octet-stream'); }
  catch { json(res, { error: 'not found' }, 404); }
}).listen(port, () => console.log(`SlowClaw web (local mode, sample data): http://localhost:${port}`));
