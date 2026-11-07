// SlowClaw web: read and tend your journals, spaces, lists and book.
// Plain JavaScript, no build step. Two modes, set by mode.js:
//   cloud  (slowclaw.social): Supabase Auth + PostgREST; row-level security keeps rows private.
//   local  (served by the iPhone over Wi-Fi): talks only to the phone; nothing goes online.

const MODE = window.SLOWCLAW_MODE === 'local' ? 'local' : 'cloud';
const SUPABASE_URL = 'https://docmtelcjyvfyjlujibb.supabase.co';
const SUPABASE_KEY = 'sb_publishable_w9ZdQLfwKjo56BDs24ziag_tt2_X_Z3';
const SESSION_KEY = MODE === 'local' ? 'slowclaw.local.v1' : 'slowclaw.session.v2';
const KINDS = [
  { id: 'todo', label: 'To-dos', one: 'to-do' },
  { id: 'idea', label: 'Ideas', one: 'idea' },
  { id: 'question', label: 'Questions', one: 'question' },
  { id: 'note', label: 'Notes', one: 'note' },
];

const state = { session: null, journals: [], spaces: [], items: [], book: [], news: null, videos: null, loading: false, error: null, status: '', draft: null };
const app = document.getElementById('app');

// ---------- tiny DOM helper (text is always set via textContent) ----------
function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'value') el.value = v;
    else if (k === 'checked') el.checked = !!v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat()) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

// ---------- storage ----------
function loadSession() {
  try { return JSON.parse(localStorage.getItem(SESSION_KEY) || 'null'); } catch { return null; }
}
function saveSession(s) {
  state.session = s;
  try { s ? localStorage.setItem(SESSION_KEY, JSON.stringify(s)) : localStorage.removeItem(SESSION_KEY); } catch {}
}

// ---------- auth ----------
async function auth(path, body, token) {
  const headers = { apikey: SUPABASE_KEY, 'Content-Type': 'application/json' };
  if (token) headers.Authorization = 'Bearer ' + token;
  const res = await fetch(SUPABASE_URL + path, { method: path === '/auth/v1/user' ? 'PUT' : 'POST', headers, body: JSON.stringify(body) });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const known = {
      invalid_credentials: 'Email or password is incorrect.',
      email_not_confirmed: 'Confirm your email first (check your inbox), then sign in.',
      user_already_exists: 'An account with this email already exists. Sign in instead.',
      weak_password: 'Choose a longer password (at least 10 characters).',
      over_email_send_rate_limit: 'Too many emails were sent. Try again later.',
    };
    throw new Error(known[data.error_code] || data.msg || data.error_description || data.message || 'Request failed.');
  }
  return data;
}

function adopt(data) {
  if (!data.access_token) return false;
  saveSession({
    access: data.access_token,
    refresh: data.refresh_token,
    expires: Date.now() / 1000 + Number(data.expires_in || 3600),
    email: data.user?.email || state.session?.email || '',
  });
  return true;
}

async function token() {
  const s = state.session;
  if (!s) throw new Error('Not signed in.');
  if (s.expires < Date.now() / 1000 + 60) {
    try {
      const data = await auth('/auth/v1/token?grant_type=refresh_token', { refresh_token: s.refresh });
      adopt(data);
    } catch (e) {
      saveSession(null);
      render();
      throw e;
    }
  }
  return state.session.access;
}

// ---------- REST ----------
async function rest(method, path, body) {
  const headers = { apikey: SUPABASE_KEY, Authorization: 'Bearer ' + (await token()), 'Content-Type': 'application/json' };
  if (method === 'POST') headers.Prefer = 'resolution=merge-duplicates,return=representation';
  const res = await fetch(SUPABASE_URL + '/rest/v1/' + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  if (res.status === 401) { saveSession(null); render(); throw new Error('Session expired. Sign in again.'); }
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(data?.message || 'Request failed (' + res.status + ').');
  return data;
}

// Local mode: the phone's own API, unlocked by the token it issued after the QR scan.
async function phone(method, path, body) {
  const res = await fetch(path, {
    method, headers: { Authorization: 'Bearer ' + state.session.token, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  }).catch(() => { throw new Error('Cannot reach the iPhone. Keep SlowClaw open on it and stay on the same Wi-Fi.'); });
  if (res.status === 401) { signOut(); throw new Error('This browser is no longer paired. Scan the code again.'); }
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(data?.error || 'Request failed (' + res.status + ').');
  return data;
}

function signOut() {
  if (MODE === 'local' && state.session) phone('POST', 'api/signout').catch(() => {});
  saveSession(null);
  Object.assign(state, { journals: [], spaces: [], items: [], book: [], news: null, videos: null, draft: null });
  render();
}

async function fetchAll(table) {
  const rows = [];
  for (let offset = 0; ; offset += 1000) {
    const page = await rest('GET', `${table}?select=*&deleted=eq.false&order=created_at.desc&limit=1000&offset=${offset}`);
    rows.push(...page);
    if (page.length < 1000) break;
  }
  return rows;
}

// Background refreshes must not rebuild the editor under the cursor.
const editorOpen = () => !!document.querySelector('.editor');
const renderUnlessEditing = () => { if (!editorOpen()) render(); };

async function loadAll() {
  state.loading = true; state.error = null; renderUnlessEditing();
  try {
    if (MODE === 'local') {
      const d = await phone('GET', 'api/data');
      Object.assign(state, { journals: d.journals, spaces: d.spaces, items: d.space_items, book: d.book_nodes, news: d.news, videos: d.videos || null });
    } else {
      if (!state.session.email) {
        const res = await fetch(SUPABASE_URL + '/auth/v1/user', { headers: { apikey: SUPABASE_KEY, Authorization: 'Bearer ' + (await token()) } });
        const user = await res.json().catch(() => ({}));
        if (user.email) saveSession({ ...state.session, email: user.email });
      }
      const [journals, spaces, items, book] = await Promise.all([fetchAll('journals'), fetchAll('spaces'), fetchAll('space_items'), fetchAll('book_nodes')]);
      Object.assign(state, { journals, spaces, items, book });
    }
  } catch (e) {
    state.error = e.message;
  }
  state.loading = false;
  renderUnlessEditing();
}

async function save(table, row, { quiet = false } = {}) {
  const now = new Date().toISOString();
  const full = { ...row, updated_at: now };
  flash('Saving…');
  try {
    const saved = MODE === 'local'
      ? (await phone('POST', 'api/save', { table, row: full })).row
      : (await rest('POST', `${table}?on_conflict=user_id,id`, [full]))[0];
    if (!saved) throw new Error('Not saved.');
    const list = state[table === 'space_items' ? 'items' : table];
    const i = list.findIndex(r => r.id === saved.id);
    if (saved.deleted || row.deleted) { if (i >= 0) list.splice(i, 1); }
    else if (i >= 0) list[i] = saved; else list.unshift(saved);
    flash('Saved');
  } catch (e) {
    flash(e.message, true);
    return false;
  }
  if (!quiet) render();
  return true;
}

const uid = prefix => prefix + '_' + (crypto.randomUUID ? crypto.randomUUID()
  : Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join(''));

let flashTimer;
// A small status line. `undo` adds a button that runs once and dismisses the line.
function flash(text, sticky, undo) {
  state.status = text;
  document.querySelector('.status')?.remove();
  clearTimeout(flashTimer);
  if (!text) return;
  const el = h('div', { class: 'status', role: 'status' }, h('span', {}, text),
    undo ? h('button', { class: 'link', onclick: () => { el.remove(); undo(); } }, 'Undo') : null);
  document.body.append(el);
  if (!sticky) flashTimer = setTimeout(() => { state.status = ''; el.remove(); }, undo ? 5000 : 1500);
}

// ---------- routing ----------
function route() {
  const parts = location.hash.replace(/^#\/?/, '').split('/');
  return { view: parts[0] || 'today', id: decodeURIComponent(parts[1] || '') };
}
const go = hash => { location.hash = hash; };
window.addEventListener('hashchange', () => {
  document.querySelector('.side')?.classList.remove('open');
  // Leaving the editor: save it, then forget its draft.
  const leaving = activeEditor; activeEditor = null; state.draft = null;
  if (leaving) leaving.leave();
  render();
  window.scrollTo(0, 0);
});

// ---------- helpers ----------
const spaceById = id => state.spaces.find(s => s.id === id);
const sortedSpaces = () => [...state.spaces].sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name));
const journalTitle = j => (j.title || '').trim() || (j.body || '').split('\n')[0].slice(0, 60) || 'Untitled';
const journalById = id => id ? state.journals.find(j => j.id === id) : null;
const kindById = id => KINDS.find(k => k.id === id) || { id, label: id, one: id };
// Items whose space still exists; the phone removes the rest.
const liveItems = () => state.items.filter(i => spaceById(i.space_id));
const byNewest = (a, b) => b.created_at.localeCompare(a.created_at);
// There is no separate completion time: a done to-do's last update is when it was ticked.
const doneAt = i => i.updated_at || i.created_at;
const wordCount = t => (String(t || '').match(/\S+/g) || []).length;
const plural = (n, one, many = one + 's') => `${n} ${n === 1 ? one : many}`;

const DAY = 86400000;
function startOfDay(d) { const x = new Date(d); x.setHours(0, 0, 0, 0); return x; }
function startOfWeek(d) { const x = startOfDay(d); x.setDate(x.getDate() - (x.getDay() + 6) % 7); return x; } // Monday
function addDays(d, n) { const x = new Date(d); x.setDate(x.getDate() + n); return x; }
const pad2 = n => String(n).padStart(2, '0');
const dayKey = d => { const x = new Date(d); return `${x.getFullYear()}-${pad2(x.getMonth() + 1)}-${pad2(x.getDate())}`; };
const fromDayKey = k => { const [y, m, d] = k.split('-').map(Number); return new Date(y, m - 1, d); };
const between = (iso, a, b) => { const t = new Date(iso); return t >= a && t < b; };
const daysOld = iso => Math.floor((startOfDay(new Date()) - startOfDay(iso)) / DAY);

function dayLabel(iso) {
  const d = new Date(iso), today = new Date();
  const n = daysOld(iso);
  if (n === 0) return 'Today';
  if (n === 1) return 'Yesterday';
  return d.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'short', year: d.getFullYear() === today.getFullYear() ? undefined : 'numeric' });
}
function shortDate(iso) {
  const d = new Date(iso), n = daysOld(iso);
  if (n === 0) return 'today';
  if (n === 1) return 'yesterday';
  if (n < 7) return d.toLocaleDateString(undefined, { weekday: 'short' });
  return d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: d.getFullYear() === new Date().getFullYear() ? undefined : 'numeric' });
}
function ago(iso) {
  const n = daysOld(iso);
  if (n <= 0) return 'today';
  if (n === 1) return 'yesterday';
  if (n < 14) return `${n} days ago`;
  if (n < 60) return `${Math.round(n / 7)} weeks ago`;
  if (n < 730) return `${Math.round(n / 30)} months ago`;
  return `${Math.round(n / 365)} years ago`;
}
function span(days) {
  if (days <= 0) return 'same day';
  if (days === 1) return '1 day';
  if (days < 14) return `${days} days`;
  if (days < 60) return `${Math.round(days / 7)} weeks`;
  return `${Math.round(days / 30)} months`;
}
// Stable per-day choice, so a resurfaced idea does not change on every redraw.
function pickForToday(list, salt = 0) {
  if (!list.length) return null;
  let seed = salt;
  for (const c of dayKey(new Date())) seed = (seed * 31 + c.charCodeAt(0)) >>> 0;
  return list[seed % list.length];
}

// Numbers behind the Today page and the progress views.
function stats() {
  const now = new Date(), today = startOfDay(now), tomorrow = addDays(today, 1);
  const week = startOfWeek(now), lastWeek = addDays(week, -7);
  const days = new Set(state.journals.map(j => dayKey(j.created_at)));
  let streak = 0, d = today;
  if (!days.has(dayKey(d))) d = addDays(d, -1);
  while (days.has(dayKey(d))) { streak++; d = addDays(d, -1); }
  const todos = liveItems().filter(i => i.kind === 'todo');
  const done = todos.filter(i => i.done), open = todos.filter(i => !i.done);
  return {
    streak, journaledToday: days.has(dayKey(today)),
    entriesWeek: state.journals.filter(j => between(j.created_at, week, tomorrow)).length,
    entriesLastWeek: state.journals.filter(j => between(j.created_at, lastWeek, week)).length,
    wordsWeek: state.journals.filter(j => between(j.created_at, week, tomorrow)).reduce((n, j) => n + wordCount(j.body), 0),
    doneToday: done.filter(i => between(doneAt(i), today, tomorrow)).length,
    doneWeek: done.filter(i => between(doneAt(i), week, tomorrow)).length,
    doneLastWeek: done.filter(i => between(doneAt(i), lastWeek, week)).length,
    open: open.length, done: done.length,
    stale: open.filter(i => daysOld(i.created_at) >= 30).length,
  };
}

// ---------- views ----------
function render() {
  stopPairing();
  app.replaceChildren(state.session ? shell() : MODE === 'local' ? pairView() : authView());
}

// ---------- QR sign-in ----------
const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
const randomHex = n => hex(crypto.getRandomValues(new Uint8Array(n)));

function qrCanvas(text) {
  const qr = qrcode(0, 'M');
  qr.addData(text);
  qr.make();
  const n = qr.getModuleCount(), cell = 6, pad = 4 * cell, size = n * cell + 2 * pad;
  const canvas = h('canvas', { width: size, height: size, class: 'qr', 'aria-label': 'Sign-in code' });
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, size, size);
  ctx.fillStyle = '#000';
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (qr.isDark(r, c)) ctx.fillRect(pad + c * cell, pad + r * cell, cell, cell);
  return canvas;
}

let pairing = null;
function stopPairing() { if (pairing) { clearTimeout(pairing.timer); pairing.stopped = true; pairing = null; } }

// slowclaw.social: the phone seals a fresh session for this browser with `key` (only in the
// QR code) and drops it in a relay that holds it for two minutes. The relay sees ciphertext.
async function cloudQR(box, note) {
  stopPairing();
  const job = pairing = { stopped: false };
  const id = randomHex(32), key = randomHex(32), secret = randomHex(32);
  const call = async (input) => {
    const res = await fetch(SUPABASE_URL + '/functions/v1/cloud-qr', {
      method: 'POST', headers: { apikey: SUPABASE_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(input) });
    const v = await res.json().catch(() => ({}));
    if (!res.ok || v.error) throw new Error(v.error || 'Request failed');
    return v;
  };
  try {
    const { expires } = await call({ action: 'start', id, secret });
    if (job.stopped) return;
    box.replaceChildren(qrCanvas(JSON.stringify({ type: 'slowclaw-cloud', id, key, expires })));
    const poll = async () => {
      if (job.stopped) return;
      if (Date.now() / 1000 > expires - 2) return cloudQR(box, note);
      try {
        const v = await call({ action: 'poll', id, secret });
        if (v.payload) {
          const raw = Uint8Array.from(atob(v.payload), c => c.charCodeAt(0));
          const k = await crypto.subtle.importKey('raw', Uint8Array.from(key.match(/../g), x => parseInt(x, 16)), { name: 'AES-GCM' }, false, ['decrypt']);
          const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: raw.slice(0, 12), additionalData: new TextEncoder().encode('cloud-qr/' + id) }, k, raw.slice(12));
          const s = JSON.parse(new TextDecoder().decode(plain));
          if (s.nonce !== id || s.expires_at < Date.now() / 1000) throw new Error('This code expired. A new one is shown.');
          call({ action: 'ack', id, secret }).catch(() => {});
          stopPairing();
          adopt({ ...s, user: { email: s.email } });
          go('#/today'); render(); loadAll();
          return;
        }
      } catch (e) {
        if (String(e.message).includes('QR_EXPIRED')) return cloudQR(box, note);
        note.textContent = e.message; note.hidden = false;
      }
      job.timer = setTimeout(poll, 2000);
    };
    job.timer = setTimeout(poll, 2000);
  } catch (e) {
    note.textContent = 'Could not show a code: ' + e.message; note.hidden = false;
  }
}

// Local view: the phone approves this browser when it scans the code. No cloud involved.
async function localQR(box, note) {
  stopPairing();
  const job = pairing = { stopped: false };
  const id = randomHex(16), secret = randomHex(32);
  try {
    const res = await fetch('api/pair/start', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id, secret }) });
    const v = await res.json();
    if (!res.ok) throw new Error(v.error || 'Request failed');
    if (job.stopped) return;
    box.replaceChildren(qrCanvas(JSON.stringify({ type: 'slowclaw-local', id })));
    const poll = async () => {
      if (job.stopped) return;
      if (Date.now() / 1000 > v.expires - 2) return localQR(box, note);
      try {
        const r = await fetch('api/pair/poll', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id, secret }) });
        const p = await r.json();
        if (r.status === 404) return localQR(box, note);
        if (p.token) { stopPairing(); saveSession({ token: p.token, email: p.device || 'This iPhone' }); render(); loadAll(); return; }
      } catch { note.textContent = 'Cannot reach the iPhone. Keep SlowClaw open on it.'; note.hidden = false; }
      job.timer = setTimeout(poll, 1500);
    };
    job.timer = setTimeout(poll, 1500);
  } catch (e) {
    note.textContent = 'Could not show a code: ' + e.message; note.hidden = false;
  }
}

function pairView() {
  const box = h('div', { class: 'qr-box' }, h('p', { class: 'muted' }, 'Preparing a code…'));
  const note = h('div', { class: 'notice', hidden: true });
  const view = h('div', { class: 'auth' },
    h('h1', {}, 'SlowClaw on this Wi-Fi'),
    h('p', { class: 'muted' }, 'On your iPhone, open SlowClaw → Settings → Scan a browser\'s sign-in code, and point it at this code. Your journals go straight from the phone to this browser; nothing goes online.'),
    box, note);
  setTimeout(() => localQR(box, note), 0);
  return view;
}

function authView(mode = 'signin', message = '') {
  const email = h('input', { type: 'email', placeholder: 'Email', autocomplete: 'username', required: true });
  const password = h('input', { type: 'password', placeholder: 'Password', autocomplete: mode === 'signup' ? 'new-password' : 'current-password', required: true, minlength: 6 });
  const note = h('div', { class: 'notice', hidden: !message }, message);
  const show = (text) => { note.textContent = text; note.hidden = false; };
  const submit = async (e) => {
    e.preventDefault();
    try {
      if (mode === 'signin') {
        adopt(await auth('/auth/v1/token?grant_type=password', { email: email.value, password: password.value }));
        render(); loadAll();
      } else {
        const data = await auth('/auth/v1/signup', { email: email.value, password: password.value });
        if (adopt(data)) { render(); loadAll(); } else show('Check your email to confirm your account, then sign in.');
      }
    } catch (err) { show(err.message); }
  };
  const swap = (m) => app.replaceChildren(authView(m));
  const box = h('div', { class: 'qr-box' }, h('p', { class: 'muted' }, 'Preparing a code…'));
  setTimeout(() => cloudQR(box, note), 0);
  return h('div', { class: 'auth' },
    h('h1', {}, 'SlowClaw'),
    h('p', { class: 'muted' }, 'Your journals, sorted into spaces with to-dos, ideas, questions and a living book.'),
    h('div', { class: 'card' },
      h('h2', {}, 'Sign in with your iPhone'),
      h('p', { class: 'small muted' }, 'In SlowClaw on your iPhone: Settings → Scan a browser\'s sign-in code. No password needed.'),
      box),
    h('details', {},
      h('summary', { class: 'muted small' }, 'Use email and password instead'),
    h('form', { onsubmit: submit },
      email, password,
      h('button', { class: 'primary', type: 'submit' }, mode === 'signin' ? 'Sign in' : 'Create account'),
      h('div', { class: 'row small' },
        h('button', { class: 'link', type: 'button', onclick: () => swap(mode === 'signin' ? 'signup' : 'signin') },
          mode === 'signin' ? 'Create an account' : 'I already have an account'),
        h('button', { class: 'link', type: 'button', onclick: async () => {
          if (!email.value) return show('Enter your email first.');
          try { await auth('/auth/v1/recover', { email: email.value }); show('Password reset email sent.'); } catch (err) { show(err.message); }
        } }, 'Forgot password')))),
      note);
}

function setPasswordView() {
  const password = h('input', { type: 'password', placeholder: 'New password', autocomplete: 'new-password', minlength: 6 });
  const note = h('div', { class: 'notice', hidden: true });
  return h('div', { class: 'auth' },
    h('h1', {}, 'Set a new password'),
    h('form', { onsubmit: async (e) => {
      e.preventDefault();
      try { await auth('/auth/v1/user', { password: password.value }, await token()); go('#/'); render(); loadAll(); }
      catch (err) { note.textContent = err.message; note.hidden = false; }
    } }, password, h('button', { class: 'primary', type: 'submit' }, 'Save password'), note));
}

function shell() {
  const r = route();
  if (r.view === 'set-password') return setPasswordView();
  const side = h('aside', { class: 'side' });
  const items = liveItems();
  const openTodos = id => items.filter(i => i.space_id === id && i.kind === 'todo' && !i.done).length;
  const navItem = (label, hash, count, active, glyph) =>
    h('li', {}, h('button', { class: active ? 'active' : '', onclick: () => go(hash), 'aria-current': active ? 'page' : null },
      h('span', {}, glyph ? h('span', { class: 'glyph', 'aria-hidden': 'true' }, glyph) : null, label),
      count ? h('span', { class: 'count' }, count) : null));
  const unsorted = state.journals.filter(j => !spaceById(j.space_id));
  const count = kind => items.filter(i => i.kind === kind && !(kind === 'todo' && i.done)).length;
  const inSpace = r.view === 'space' ? r.id : null;
  side.append(
    h('div', { class: 'brand' }, 'SlowClaw', h('button', { class: 'icon', title: 'Refresh', 'aria-label': 'Refresh', onclick: loadAll }, state.loading ? '…' : '↻')),
    h('ul', { class: 'nav' },
      navItem('Today', '#/today', '', r.view === 'today' || r.view === 'day', '☼'),
      navItem('Journal', '#/journals', state.journals.length, r.view === 'journals' || r.view === 'journal' || r.view === 'new', '¶'),
      navItem('To-dos', '#/todos', count('todo'), r.view === 'todos', '✓'),
      navItem('Ideas', '#/ideas', count('idea'), r.view === 'ideas', '✦'),
      navItem('Questions', '#/questions', count('question'), r.view === 'questions', '?'),
      navItem('Notes', '#/notes', count('note'), r.view === 'notes', '✎'),
      navItem('Book', '#/book', state.book.filter(n => (n.kind || 'passage') === 'passage').length, r.view === 'book', '❦'),
      state.news ? navItem('News', '#/news', state.news.length, r.view === 'news', '◫') : null,
      state.videos ? navItem('Videos', '#/videos', state.videos.reduce((n, g) => n + g.videos.length, 0), r.view === 'videos', '▷') : null,
      unsorted.length ? navItem('Unsorted', '#/unsorted', unsorted.length, r.view === 'unsorted', '○') : null),
    h('div', { class: 'nav-title' }, 'Spaces'),
    h('ul', { class: 'nav' },
      sortedSpaces().map(s => navItem(s.name, '#/space/' + encodeURIComponent(s.id), openTodos(s.id) || '', inSpace === s.id)),
      h('li', {}, h('button', { class: 'muted', onclick: addSpace }, '+ New space'))),
    h('div', { class: 'side-foot' },
      h('span', { class: 'keys' }, h('kbd', {}, 'N'), ' new entry · ', h('kbd', {}, '/'), ' search'),
      MODE === 'local' ? h('span', {}, 'Local view · nothing goes online') : null,
      h('span', {}, /@phone\.slowclaw\.invalid$/.test(state.session.email || '') ? 'Signed in with your iPhone' : state.session.email),
      h('button', { class: 'link', onclick: signOut }, 'Sign out')));

  let content;
  if (state.loading && !state.journals.length && !state.spaces.length) content = h('p', { class: 'muted' }, 'Loading…');
  else if (r.view === 'space') content = spaceView(r.id);
  else if (r.view === 'journal') content = journalView(r.id);
  else if (r.view === 'new') content = journalView(null);
  else if (r.view === 'todos') content = todosView(r.id === 'done' ? 'done' : 'open');
  else if (r.view === 'ideas' || r.view === 'questions' || r.view === 'notes') content = collectedView(r.view.replace(/s$/, ''));
  else if (r.view === 'day') content = dayView(r.id);
  else if (r.view === 'book') content = bookView(r.id);
  else if (r.view === 'news' && state.news) content = newsView();
  else if (r.view === 'videos' && state.videos) content = videosView();
  else if (r.view === 'unsorted') content = journalsView('Unsorted', unsorted, 'Journals the phone has not filed yet. Open one to choose a space.');
  else if (r.view === 'journals') content = journalsView('Journal', state.journals);
  else content = todayView();

  const main = h('main', { class: 'view-' + r.view },
    h('button', { class: 'menu-btn', onclick: () => side.classList.toggle('open') }, '☰ Menu'),
    state.error ? h('div', { class: 'notice' }, state.error) : null,
    content);
  return h('div', { class: 'shell' }, side, main);
}

// ---------- shared pieces ----------
const kindGlyph = { todo: '✓', idea: '✦', question: '?', note: '✎' };
const spaceChip = space => space
  ? h('button', { class: 'chip', onclick: e => { e.stopPropagation(); go('#/space/' + encodeURIComponent(space.id)); } }, space.name)
  : null;
const kindChip = kind => h('span', { class: 'kind kind-' + kind }, h('span', { 'aria-hidden': 'true' }, kindGlyph[kind] || '•'), ' ', kindById(kind).one);

async function setDone(item, done) {
  if (!(await save('space_items', { ...item, done }))) return;
  if (done) {
    const n = stats().doneToday;
    flash(`Done · ${plural(n, 'to-do')} today`, false, () => save('space_items', { ...item, done: false }));
  }
}

// One to-do, idea, question or note. Click the words to edit them in place.
function itemRow(item, o = {}) {
  const space = spaceById(item.space_id);
  const source = journalById(item.journal_id);
  const old = !item.done && item.kind === 'todo' ? daysOld(item.created_at) : 0;
  const text = h('span', { class: 'text', tabindex: 0, role: 'button', title: 'Click to edit' }, item.text);
  const edit = () => {
    const input = h('input', { type: 'text', class: 'inline-edit', value: item.text, 'aria-label': 'Edit ' + kindById(item.kind).one });
    let finished = false;
    const finish = commit => {
      if (finished) return; finished = true;
      const t = input.value.trim();
      if (commit && t && t !== item.text) save('space_items', { ...item, text: t });
      else input.replaceWith(text);
    };
    input.addEventListener('keydown', e => { if (e.key === 'Enter') finish(true); if (e.key === 'Escape') finish(false); });
    input.addEventListener('blur', () => finish(true));
    text.replaceWith(input); input.focus();
  };
  text.addEventListener('click', edit);
  text.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); edit(); } });
  const meta = [];
  if (o.kind) meta.push(kindChip(item.kind));
  if (o.space !== false && space) meta.push(spaceChip(space));
  if (item.done) {
    const took = daysOld(item.created_at) - daysOld(doneAt(item));
    meta.push(h('span', {}, 'done ' + shortDate(doneAt(item)) + (took > 0 ? ' · took ' + span(took) : '')));
  } else if (o.age !== false) {
    meta.push(h('span', { class: old >= 30 ? 'stale' : '' }, old >= 30 ? 'waiting ' + span(old) : shortDate(item.created_at)));
  }
  if (source && o.source !== false) meta.push(h('button', { class: 'link source', title: 'Open the entry this came from', onclick: () => go('#/journal/' + encodeURIComponent(source.id)) }, '↗ ' + journalTitle(source)));
  return h('li', { class: 'item' + (item.done ? ' done' : '') },
    item.kind === 'todo'
      ? h('input', { type: 'checkbox', checked: item.done, 'aria-label': item.done ? 'Mark not done' : 'Mark done', onchange: e => setDone(item, e.target.checked) })
      : h('span', { class: 'bullet kind-' + item.kind, 'aria-hidden': 'true' }, kindGlyph[item.kind]),
    h('div', { class: 'body' }, text, meta.length ? h('div', { class: 'meta' }, meta) : null),
    h('button', { class: 'icon del', title: 'Delete', 'aria-label': 'Delete', onclick: () => {
      save('space_items', { ...item, deleted: true }).then(ok => ok && flash('Deleted', false, () => save('space_items', { ...item, deleted: false })));
    } }, '×'));
}

// "Add …" input with a space picker that remembers the last space used.
function addItemRow(kind, fixedSpace, placeholder) {
  const spaces = sortedSpaces();
  const key = 'slowclaw.add-space';
  let last = '';
  try { last = localStorage.getItem(key) || ''; } catch {}
  const tag = kind + ':' + (fixedSpace ? fixedSpace.id : '*');
  const input = h('input', { type: 'text', placeholder: placeholder || `Add ${kindById(kind).one}…`, 'aria-label': `Add ${kindById(kind).one}`, 'data-add': tag });
  const select = fixedSpace ? null : h('select', { 'aria-label': 'Space' }, spaces.map(s => h('option', { value: s.id }, s.name)));
  if (select) select.value = spaceById(last) ? last : spaces[0]?.id || '';
  const add = async () => {
    const text = input.value.trim();
    const spaceId = fixedSpace ? fixedSpace.id : select.value;
    if (!text || !spaceId) return;
    try { localStorage.setItem(key, spaceId); } catch {}
    await save('space_items', { id: uid('item'), space_id: spaceId, journal_id: null, kind, text, done: false, created_at: new Date().toISOString(), deleted: false });
    document.querySelector(`[data-add="${CSS.escape(tag)}"]`)?.focus();
  };
  input.addEventListener('keydown', e => { if (e.key === 'Enter') add(); });
  if (!spaces.length) return h('p', { class: 'muted small' }, 'Create a space first.');
  return h('div', { class: 'add-row' }, input, select, h('button', { onclick: add }, 'Add'));
}

const statTile = (label, value, sub, onclick) =>
  h(onclick ? 'button' : 'div', { class: 'tile', onclick }, h('div', { class: 'tile-label' }, label), h('div', { class: 'tile-value' }, value), sub ? h('div', { class: 'tile-sub' }, sub) : null);

function versus(now, before) {
  if (!now && !before) return 'none last week either';
  if (now === before) return 'same as last week';
  return `${now > before ? '+' : '−'}${Math.abs(now - before)} vs last week (${before})`;
}

// Activity calendar: one square per day, darker for more entries and finished to-dos.
function activityGrid(weeks = 20) {
  const today = startOfDay(new Date());
  const first = addDays(startOfWeek(today), -7 * (weeks - 1));
  const entries = new Map(), done = new Map();
  for (const j of state.journals) { const k = dayKey(j.created_at); entries.set(k, (entries.get(k) || 0) + 1); }
  for (const i of liveItems()) if (i.kind === 'todo' && i.done) { const k = dayKey(doneAt(i)); done.set(k, (done.get(k) || 0) + 1); }
  const readout = h('div', { class: 'grid-readout small muted' }, 'Hover a day to see it. Click to open it.');
  const describe = (k, d) => `${d.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' })} · ${plural(entries.get(k) || 0, 'entry', 'entries')} · ${plural(done.get(k) || 0, 'to-do')} done`;
  const cols = [];
  const months = [];
  for (let w = 0; w < weeks; w++) {
    const cells = [];
    const monday = addDays(first, 7 * w);
    months.push(monday.getDate() <= 7 || w === 0 ? monday.toLocaleDateString(undefined, { month: 'short' }) : '');
    for (let d = 0; d < 7; d++) {
      const day = addDays(monday, d);
      if (day > today) { cells.push(h('span', { class: 'cell future' })); continue; }
      const k = dayKey(day);
      const n = (entries.get(k) || 0) + (done.get(k) || 0);
      const level = n === 0 ? 0 : n === 1 ? 1 : n <= 3 ? 2 : n <= 5 ? 3 : 4;
      const label = describe(k, day);
      cells.push(h('button', { class: `cell l${level}` + (k === dayKey(today) ? ' today' : ''), 'aria-label': label, title: label,
        onmouseenter: () => { readout.textContent = label; }, onfocus: () => { readout.textContent = label; },
        onclick: () => go('#/day/' + k) }));
    }
    cols.push(h('div', { class: 'col' }, cells));
  }
  const box = h('div', { class: 'activity' },
    h('div', { class: 'months', 'aria-hidden': 'true' }, months.map(m => h('span', {}, m))),
    h('div', { class: 'grid', role: 'group', 'aria-label': 'Activity over the last ' + weeks + ' weeks' }, cols),
    h('div', { class: 'grid-foot' }, readout,
      h('span', { class: 'legend small muted', 'aria-hidden': 'true' }, 'Less ', [0, 1, 2, 3, 4].map(l => h('span', { class: 'cell l' + l })), ' More')));
  // On narrow screens the grid scrolls; start at the most recent weeks.
  setTimeout(() => { box.scrollLeft = box.scrollWidth; }, 0);
  return box;
}

// Bars of to-dos finished per week. One series, so the title names it; hover reads it out.
function weeklyDoneChart(weeks = 12) {
  const thisWeek = startOfWeek(new Date());
  const done = liveItems().filter(i => i.kind === 'todo' && i.done);
  const counts = Array.from({ length: weeks }, (_, w) => {
    const from = addDays(thisWeek, -7 * (weeks - 1 - w));
    return { from, n: done.filter(i => between(doneAt(i), from, addDays(from, 7))).length };
  });
  const peak = Math.max(...counts.map(c => c.n));
  const max = Math.max(4, peak);
  const W = 900, H = 170, top = 18, bottom = 22, gap = 8, bw = (W - gap * (weeks - 1)) / weeks, base = H - bottom;
  const readout = h('div', { class: 'small muted grid-readout' }, 'Hover a week to see it.');
  const label = c => `Week of ${c.from.toLocaleDateString(undefined, { day: 'numeric', month: 'short' })}: ${plural(c.n, 'to-do')} done`;
  const bars = counts.map((c, i) => {
    const x = i * (bw + gap), y = top + (base - top) * (1 - c.n / max), r = Math.min(4, bw / 2, base - y);
    const last = i === weeks - 1;
    const g = svg('g', { class: 'bar' + (last ? ' current' : ''), tabindex: 0, 'aria-label': label(c) },
      svg('rect', { x, y: top, width: bw, height: base - top, class: 'hit' }),
      c.n ? svg('path', { class: 'mark', d: `M${x},${base} V${y + r} Q${x},${y} ${x + r},${y} H${x + bw - r} Q${x + bw},${y} ${x + bw},${y + r} V${base} Z` }) : null,
      c.n && (last || c.n === peak) ? svg('text', { x: x + bw / 2, y: y - 5, class: 'val' }, c.n) : null,
      (weeks - 1 - i) % 3 === 0 ? svg('text', { x: x + bw / 2, y: H - 6, class: 'tick' }, last ? 'this week' : c.from.toLocaleDateString(undefined, { day: 'numeric', month: 'short' })) : null,
      svg('title', {}, label(c)));
    const show = () => { readout.textContent = label(c); };
    g.addEventListener('mouseenter', show);
    g.addEventListener('focus', show);
    return g;
  });
  return h('div', {},
    svg('svg', { viewBox: `0 0 ${W} ${H}`, class: 'bars', role: 'group', 'aria-label': `To-dos done per week, last ${weeks} weeks` },
      svg('line', { x1: 0, x2: W, y1: base, y2: base, class: 'axis' }), ...bars),
    readout);
}

// ---------- today ----------
function todayView() {
  const s = stats();
  const hour = new Date().getHours();
  const hello = hour < 5 ? 'Still up' : hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
  const items = liveItems();
  const open = items.filter(i => i.kind === 'todo' && !i.done).sort(byNewest);
  const doneToday = items.filter(i => i.kind === 'todo' && i.done && daysOld(doneAt(i)) === 0).sort((a, b) => doneAt(b).localeCompare(doneAt(a)));
  const oldest = [...open].sort((a, b) => a.created_at.localeCompare(b.created_at))[0];
  const ideas = items.filter(i => i.kind === 'idea').sort(byNewest);
  const questions = items.filter(i => i.kind === 'question').sort(byNewest);
  const past = items.filter(i => (i.kind === 'idea' || i.kind === 'question' || i.kind === 'note') && daysOld(i.created_at) >= 21);
  const resurfaced = pickForToday(past);
  const recent = [...state.journals].sort(byNewest).slice(0, 4);
  const now = new Date();
  const onThisDay = state.journals.filter(j => { const d = new Date(j.created_at); return d.getDate() === now.getDate() && d.getMonth() === now.getMonth() && d.getFullYear() < now.getFullYear(); });

  const mini = (title, hash, list, empty, limit = 5) => h('section', { class: 'card' },
    h('h2', {}, h('button', { class: 'link', onclick: () => go(hash) }, title), list.length > limit ? h('button', { class: 'link small', onclick: () => go(hash) }, `All ${list.length} →`) : null),
    list.length ? h('ul', { class: 'items' }, list.slice(0, limit).map(i => itemRow(i, { age: true }))) : h('p', { class: 'muted small' }, empty));

  return h('div', { class: 'today' },
    h('header', { class: 'page-head' },
      h('div', {}, h('h1', {}, hello),
        h('p', { class: 'muted' }, now.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' }),
          s.journaledToday ? ' · you have journaled today' : ' · nothing journaled yet today')),
      h('button', { class: 'primary', onclick: newJournal }, '+ Write an entry')),
    h('div', { class: 'tiles' },
      statTile('Journal streak', plural(s.streak, 'day'), s.journaledToday ? 'including today' : s.streak ? 'write today to keep it' : 'start one today', () => go('#/journals')),
      statTile('Entries this week', s.entriesWeek, versus(s.entriesWeek, s.entriesLastWeek) + (s.wordsWeek ? ` · ${s.wordsWeek.toLocaleString()} words` : ''), () => go('#/journals')),
      statTile('To-dos done this week', s.doneWeek, versus(s.doneWeek, s.doneLastWeek), () => go('#/todos/done')),
      statTile('Open to-dos', s.open, s.stale ? `${s.stale} waiting over a month` : 'none waiting long', () => go('#/todos'))),
    h('section', { class: 'card' }, h('h2', {}, 'Your last 30 weeks'), activityGrid(30)),
    h('div', { class: 'columns' },
      h('div', {},
        h('section', { class: 'card' },
          h('h2', {}, h('button', { class: 'link', onclick: () => go('#/todos') }, 'Next up'), open.length > 7 ? h('button', { class: 'link small', onclick: () => go('#/todos') }, `All ${open.length} →`) : null),
          open.length ? h('ul', { class: 'items' }, open.slice(0, 7).map(i => itemRow(i))) : h('p', { class: 'muted small' }, 'Nothing open. To-dos you mention in a recording show up here.'),
          addItemRow('todo', null, 'Add a to-do…'),
          doneToday.length ? h('div', { class: 'done-today' }, h('div', { class: 'small muted' }, `Done today (${doneToday.length})`), h('ul', { class: 'items' }, doneToday.map(i => itemRow(i)))) : null),
        oldest && daysOld(oldest.created_at) >= 14 ? h('section', { class: 'card nudge' },
          h('h2', {}, 'Waiting longest'),
          h('p', { class: 'nudge-text' }, oldest.text),
          h('p', { class: 'muted small' }, `Added ${ago(oldest.created_at)}${spaceById(oldest.space_id) ? ' in ' + spaceById(oldest.space_id).name : ''}. Do it, or let it go.`),
          h('div', { class: 'toolbar' },
            h('button', { onclick: () => setDone(oldest, true) }, '✓ Done'),
            h('button', { onclick: () => save('space_items', { ...oldest, deleted: true }).then(ok => ok && flash('Let go', false, () => save('space_items', { ...oldest, deleted: false }))) }, 'Let it go'))) : null,
        mini('Open questions', '#/questions', questions, 'Questions you wonder about out loud collect here.')),
      h('div', {},
        resurfaced ? h('section', { class: 'card resurface' },
          h('h2', {}, 'From ' + ago(resurfaced.created_at)),
          h('p', { class: 'nudge-text' }, resurfaced.text),
          h('div', { class: 'meta small muted' }, kindChip(resurfaced.kind), ' ', spaceChip(spaceById(resurfaced.space_id)),
            journalById(resurfaced.journal_id) ? h('button', { class: 'link source', onclick: () => go('#/journal/' + encodeURIComponent(resurfaced.journal_id)) }, ' ↗ ' + journalTitle(journalById(resurfaced.journal_id))) : null)) : null,
        mini('Recent ideas', '#/ideas', ideas, 'Ideas from your journals collect here.'),
        h('section', { class: 'card' },
          h('h2', {}, h('button', { class: 'link', onclick: () => go('#/journals') }, 'Latest entries')),
          recent.length ? h('ul', { class: 'journals compact' }, recent.map(journalRow)) : h('p', { class: 'muted small' }, 'Record a journal on your iPhone and it shows up here.')),
        onThisDay.length ? h('section', { class: 'card' }, h('h2', {}, 'On this day'),
          h('ul', { class: 'journals compact' }, onThisDay.sort(byNewest).map(journalRow))) : null)),
    spacesGlance());
}

function spacesGlance() {
  const spaces = sortedSpaces();
  if (!spaces.length) return null;
  const items = liveItems();
  return h('section', {},
    h('h2', { class: 'section-title' }, 'Spaces'),
    h('div', { class: 'space-grid' }, spaces.map(s => {
      const mine = items.filter(i => i.space_id === s.id);
      const todos = mine.filter(i => i.kind === 'todo'), done = todos.filter(i => i.done).length;
      const entries = state.journals.filter(j => j.space_id === s.id);
      const last = entries.sort(byNewest)[0];
      return h('button', { class: 'space-card', onclick: () => go('#/space/' + encodeURIComponent(s.id)) },
        h('div', { class: 'space-name' }, s.name),
        h('div', { class: 'small muted' }, plural(entries.length, 'entry', 'entries'), last ? ' · last ' + ago(last.created_at) : ''),
        progressBar(done, todos.length),
        h('div', { class: 'small muted counts' },
          ['todo', 'idea', 'question', 'note'].map(k => {
            const n = k === 'todo' ? todos.length - done : mine.filter(i => i.kind === k).length;
            return n ? h('span', {}, h('span', { class: 'kind-' + k, 'aria-hidden': 'true' }, kindGlyph[k]), ' ' + n + ' ' + (k === 'todo' ? 'open' : kindById(k).label.toLowerCase())) : null;
          })));
    })));
}

function progressBar(done, total) {
  if (!total) return h('div', { class: 'small muted' }, 'No to-dos yet');
  const pct = Math.round(100 * done / total);
  return h('div', { class: 'progress', role: 'img', 'aria-label': `${done} of ${total} to-dos done` },
    h('div', { class: 'track' }, h('div', { class: 'fill', style: `width:${pct}%` })),
    h('span', { class: 'small muted' }, `${done}/${total} done`));
}

// ---------- one day ----------
function dayView(key) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(key)) return h('p', { class: 'muted' }, 'Unknown day.');
  const from = fromDayKey(key), to = addDays(from, 1);
  const entries = state.journals.filter(j => between(j.created_at, from, to)).sort(byNewest);
  const items = liveItems();
  const done = items.filter(i => i.kind === 'todo' && i.done && between(doneAt(i), from, to));
  const captured = items.filter(i => between(i.created_at, from, to) && !done.includes(i));
  const step = n => h('button', { onclick: () => go('#/day/' + dayKey(addDays(from, n))), disabled: n > 0 && daysOld(from) <= 0 }, n < 0 ? '← Previous day' : 'Next day →');
  return h('div', {},
    h('header', { class: 'page-head' },
      h('div', {}, h('h1', {}, dayLabel(from.toISOString())), h('p', { class: 'muted' },
        `${plural(entries.length, 'entry', 'entries')} · ${plural(done.length, 'to-do')} done · ${plural(captured.length, 'item')} captured`)),
      h('div', { class: 'toolbar' }, step(-1), step(1))),
    h('div', { class: 'columns' },
      h('section', { class: 'card' }, h('h2', {}, 'Entries'),
        entries.length ? h('ul', { class: 'journals' }, entries.map(journalRow)) : h('p', { class: 'muted small' }, 'No entries this day.')),
      h('div', {},
        h('section', { class: 'card' }, h('h2', {}, 'Done'),
          done.length ? h('ul', { class: 'items' }, done.map(i => itemRow(i))) : h('p', { class: 'muted small' }, 'Nothing ticked off this day.')),
        h('section', { class: 'card' }, h('h2', {}, 'Captured'),
          captured.length ? h('ul', { class: 'items' }, captured.map(i => itemRow(i, { kind: true, age: false }))) : h('p', { class: 'muted small' }, 'No to-dos, ideas, questions or notes from this day.')))));
}

// ---------- journals ----------
function journalsView(title, journals, hint) {
  const search = h('input', { type: 'search', placeholder: 'Search entries', value: state.query || '', 'aria-label': 'Search entries' });
  const counter = h('span', { class: 'small muted' });
  const list = h('div');
  const draw = () => {
    const q = (state.query || '').toLowerCase().trim();
    const shown = [...journals]
      .filter(j => !q || ((j.title || '') + ' ' + (j.body || '')).toLowerCase().includes(q))
      .sort(byNewest);
    counter.textContent = q ? `${shown.length} of ${journals.length}` : plural(journals.length, 'entry', 'entries');
    let lastMonth = '', lastDay = '';
    const nodes = [];
    for (const j of shown) {
      const d = new Date(j.created_at);
      const month = d.toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
      if (month !== lastMonth && daysOld(j.created_at) > 6) {
        const inMonth = shown.filter(x => new Date(x.created_at).toLocaleDateString(undefined, { month: 'long', year: 'numeric' }) === month);
        nodes.push(h('li', { class: 'month' }, h('span', {}, month), h('span', { class: 'small muted' },
          `${plural(inMonth.length, 'entry', 'entries')} · ${inMonth.reduce((n, x) => n + wordCount(x.body), 0).toLocaleString()} words`)));
        lastMonth = month;
      }
      const day = dayLabel(j.created_at);
      if (day !== lastDay) { nodes.push(h('li', { class: 'day' }, h('button', { class: 'link', onclick: () => go('#/day/' + dayKey(j.created_at)) }, day))); lastDay = day; }
      nodes.push(journalRow(j));
    }
    list.replaceChildren(shown.length ? h('ul', { class: 'journals' }, nodes) : h('p', { class: 'muted' }, q ? 'No matches.' : 'Nothing here yet. Record a journal on your iPhone and it shows up here.'));
  };
  search.addEventListener('input', () => { state.query = search.value; draw(); });
  draw();
  return h('div', { class: 'journal-list' },
    h('header', { class: 'page-head' }, h('div', {}, h('h1', {}, title), hint ? h('p', { class: 'muted' }, hint) : null),
      h('button', { class: 'primary', onclick: newJournal }, '+ New entry')),
    h('div', { class: 'toolbar' }, search, counter),
    list);
}

function journalRow(j) {
  const space = spaceById(j.space_id);
  const mine = state.items.filter(i => i.journal_id === j.id);
  const words = wordCount(j.body);
  const body = (j.body || '').trim();
  const snippet = (j.title || '').trim() ? body : body.split('\n').slice(1).join(' ').trim() || '';
  return h('li', {}, h('a', { class: 'entry', href: '#/journal/' + encodeURIComponent(j.id) },
    h('span', { class: 'title' }, journalTitle(j)),
    snippet ? h('span', { class: 'snippet' }, snippet) : null,
    h('span', { class: 'meta small muted' },
      h('span', {}, new Date(j.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })),
      words ? h('span', {}, plural(words, 'word')) : null,
      space ? h('span', { class: 'chip' }, space.name) : null,
      KINDS.map(k => {
        const n = mine.filter(i => i.kind === k.id).length;
        return n ? h('span', { class: 'count-badge kind-' + k.id, title: plural(n, k.one) }, kindGlyph[k.id] + ' ' + n) : null;
      }))));
}

// ---------- the editor ----------
let activeEditor = null;

function journalView(id) {
  // id === null is a new entry that is only stored once it has some text.
  let j = id === null ? null : state.journals.find(x => x.id === id);
  if (id !== null && !j) return h('p', { class: 'muted' }, 'This entry was not found.');
  const isNew = !j;
  if (isNew) j = state.draft?.isNew ? { ...state.draft.row } : { id: uid('journal'), title: '', body: '', space_id: null, created_at: new Date().toISOString(), deleted: false };
  let stored = !isNew;
  // A redraw (for example after ticking a to-do here) keeps the words being typed.
  const draft = state.draft?.row.id === j.id ? state.draft.row : null;
  if (activeEditor) activeEditor.cancel();
  const title = h('input', { class: 'title-input', type: 'text', value: draft ? draft.title : j.title, placeholder: 'Title', 'aria-label': 'Title' });
  const body = h('textarea', { class: 'body-input', value: draft ? draft.body : j.body, placeholder: isNew ? 'Write…' : null, 'aria-label': 'Entry' });
  const select = h('select', { 'aria-label': 'Space' },
    h('option', { value: '' }, 'Unsorted'),
    sortedSpaces().map(s => h('option', { value: s.id }, s.name)));
  select.value = (draft ? draft.space_id : j.space_id) || '';
  const current = () => ({ ...j, title: title.value.trim(), body: body.value, space_id: select.value || null });
  const dirty = () => { const c = current(); return c.title !== (j.title || '') || c.body !== (j.body || '') || c.space_id !== (j.space_id || null); };
  const words = h('span', {});
  const count = () => { const n = wordCount(body.value); words.textContent = `${plural(n, 'word')} · ${Math.max(1, Math.round(n / 220))} min read`; };
  const grow = () => { body.style.height = 'auto'; body.style.height = body.scrollHeight + 2 + 'px'; };

  // Autosave quietly a moment after typing stops, and when leaving the page.
  let timer, closed = false;
  const persist = async (quiet = true) => {
    clearTimeout(timer);
    if (closed || !dirty()) return;
    const next = current();
    if (!stored && !next.title && !next.body.trim()) return;
    if (await save('journals', next, { quiet })) {
      j = state.journals.find(x => x.id === next.id) || next;
      if (!stored) { stored = true; if (route().view === 'new') history.replaceState(null, '', '#/journal/' + encodeURIComponent(next.id)); }
    }
  };
  const remember = () => { state.draft = { isNew: !stored, row: current() }; };
  const later = () => { remember(); clearTimeout(timer); timer = setTimeout(persist, 1200); };
  title.addEventListener('input', later);
  body.addEventListener('input', () => { later(); count(); grow(); });
  select.addEventListener('change', () => { remember(); persist(); });
  title.addEventListener('blur', () => persist());
  body.addEventListener('blur', () => persist());
  body.addEventListener('keydown', e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); go('#/journals'); } });
  activeEditor = { leave: () => persist(false), cancel: () => { closed = true; clearTimeout(timer); } };
  if (draft && dirty()) later();

  // Capture: select words in the entry and keep them as a to-do, idea, question or note.
  const capture = h('input', { type: 'text', placeholder: 'Select words above, or type…', 'aria-label': 'Text to capture' });
  let typed = false;
  capture.addEventListener('input', () => { typed = !!capture.value; });
  const fromSelection = () => {
    const picked = body.value.slice(body.selectionStart, body.selectionEnd).replace(/\s+/g, ' ').trim();
    if (picked && !typed && picked.length <= 240) capture.value = picked;
  };
  body.addEventListener('mouseup', fromSelection);
  body.addEventListener('keyup', e => { if (e.shiftKey) fromSelection(); });
  const captureAs = async kind => {
    const text = capture.value.trim();
    const spaceId = select.value;
    if (!text) { capture.focus(); return; }
    if (!spaceId) { flash('Choose a space for this entry first.'); select.focus(); return; }
    remember();
    await persist(true);
    await save('space_items', { id: uid('item'), space_id: spaceId, journal_id: j.id, kind, text, done: false, created_at: new Date().toISOString(), deleted: false });
  };

  const ordered = [...state.journals].sort(byNewest);
  const at = ordered.findIndex(x => x.id === j.id);
  const newer = at > 0 ? ordered[at - 1] : null, older = at >= 0 ? ordered[at + 1] : null;
  const fromThis = isNew && !stored ? [] : state.items.filter(i => i.journal_id === j.id);
  setTimeout(() => { grow(); count(); if (isNew && !draft) body.focus(); }, 0);

  return h('div', { class: 'editor-wrap' },
    h('div', { class: 'editor' },
      h('div', { class: 'editor-nav' },
        h('button', { class: 'link', onclick: () => history.length > 1 ? history.back() : go('#/journals') }, '← Back'),
        h('span', { class: 'toolbar small' },
          h('button', { disabled: !newer, title: newer ? journalTitle(newer) : null, onclick: () => go('#/journal/' + encodeURIComponent(newer.id)) }, '‹ Newer'),
          h('button', { disabled: !older, title: older ? journalTitle(older) : null, onclick: () => go('#/journal/' + encodeURIComponent(older.id)) }, 'Older ›'))),
      title,
      h('div', { class: 'small muted' }, new Date(j.created_at).toLocaleString(undefined, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit' }), ' · ', words, ' · saves automatically'),
      body,
      h('div', { class: 'toolbar' },
        h('button', { class: 'primary', onclick: () => go('#/journals'), title: 'Ctrl/⌘ + Enter' }, 'Done'),
        isNew && !stored ? null : h('button', { onclick: () => { if (confirm('Delete this entry?')) { closed = true; clearTimeout(timer); activeEditor = null; save('journals', { ...j, deleted: true, title: '', body: '' }); go('#/journals'); } } }, 'Delete'))),
    h('aside', { class: 'editor-side' },
      h('section', { class: 'card' },
        h('label', { class: 'small muted field' }, 'Space', select),
        j.space_id && spaceById(j.space_id) ? h('button', { class: 'link small', onclick: () => go('#/space/' + encodeURIComponent(j.space_id)) }, 'Open ' + spaceById(j.space_id).name + ' →') : null),
      h('section', { class: 'card' },
        h('h2', {}, 'From this entry', fromThis.length ? h('span', { class: 'small muted' }, fromThis.length) : null),
        fromThis.length ? h('ul', { class: 'items' }, fromThis.sort((a, b) => KINDS.findIndex(k => k.id === a.kind) - KINDS.findIndex(k => k.id === b.kind)).map(i => itemRow(i, { kind: true, source: false, space: false, age: false })))
          : h('p', { class: 'muted small' }, 'Nothing picked out yet.'),
        h('div', { class: 'capture' },
          h('div', { class: 'small muted' }, 'Keep something from this entry'),
          capture,
          h('div', { class: 'capture-kinds' }, KINDS.map(k => h('button', { class: 'kind-btn kind-' + k.id, onclick: () => captureAs(k.id) }, kindGlyph[k.id] + ' ' + k.one)))))));
}

// ---------- to-dos ----------
function todosView(tab) {
  const s = stats();
  const items = liveItems();
  const tabs = h('div', { class: 'tabs', role: 'tablist' },
    h('button', { role: 'tab', 'aria-selected': tab === 'open' ? 'true' : 'false', class: tab === 'open' ? 'active' : '', onclick: () => go('#/todos') }, `Open · ${s.open}`),
    h('button', { role: 'tab', 'aria-selected': tab === 'done' ? 'true' : 'false', class: tab === 'done' ? 'active' : '', onclick: () => go('#/todos/done') }, `Done · ${s.done}`));
  const head = h('header', { class: 'page-head' },
    h('div', {}, h('h1', {}, 'To-dos'),
      h('p', { class: 'muted' }, `${plural(s.doneToday, 'to-do')} done today · ${s.doneWeek} this week (${versus(s.doneWeek, s.doneLastWeek)})`)),
    tabs);

  if (tab === 'done') {
    const done = items.filter(i => i.kind === 'todo' && i.done).sort((a, b) => doneAt(b).localeCompare(doneAt(a)));
    const nodes = [];
    let last = '';
    for (const i of done) {
      const d = dayLabel(doneAt(i));
      if (d !== last) {
        const n = done.filter(x => dayLabel(doneAt(x)) === d).length;
        nodes.push(h('li', { class: 'day' }, h('button', { class: 'link', onclick: () => go('#/day/' + dayKey(doneAt(i))) }, d), h('span', { class: 'small muted' }, ' · ' + n)));
        last = d;
      }
      nodes.push(itemRow(i));
    }
    const took = done.map(i => daysOld(i.created_at) - daysOld(doneAt(i)));
    const median = took.length ? [...took].sort((a, b) => a - b)[Math.floor(took.length / 2)] : 0;
    return h('div', {}, head,
      h('div', { class: 'tiles' },
        statTile('Done today', s.doneToday),
        statTile('Done this week', s.doneWeek, versus(s.doneWeek, s.doneLastWeek)),
        statTile('Done in total', s.done, s.open ? `${Math.round(100 * s.done / (s.done + s.open))}% of all to-dos` : 'everything is done'),
        statTile('Usual time to finish', done.length ? span(median) : '—', 'from added to done (median)')),
      h('section', { class: 'card' }, h('h2', {}, 'To-dos done per week'), weeklyDoneChart(12)),
      h('section', { class: 'card' }, h('h2', {}, 'Done log'),
        done.length ? h('ul', { class: 'items log' }, nodes) : h('p', { class: 'muted small' }, 'Tick off a to-do and it shows up here, so you can see how far you have come.')));
  }

  let sort = 'newest';
  try { sort = localStorage.getItem('slowclaw.todos.sort') || 'newest'; } catch {}
  const open = items.filter(i => i.kind === 'todo' && !i.done)
    .sort((a, b) => sort === 'oldest' ? a.created_at.localeCompare(b.created_at) : byNewest(a, b));
  const groups = sortedSpaces().map(sp => [sp, open.filter(i => i.space_id === sp.id)]).filter(([, l]) => l.length);
  const doneToday = items.filter(i => i.kind === 'todo' && i.done && daysOld(doneAt(i)) === 0);
  const sorter = h('select', { 'aria-label': 'Sort', onchange: e => { try { localStorage.setItem('slowclaw.todos.sort', e.target.value); } catch {} render(); } },
    h('option', { value: 'newest' }, 'Newest first'), h('option', { value: 'oldest' }, 'Oldest first'));
  sorter.value = sort;
  return h('div', {}, head,
    h('div', { class: 'toolbar wide' }, addItemRow('todo'), sorter),
    doneToday.length ? h('section', { class: 'card done-today' }, h('h2', {}, `Done today · ${doneToday.length}`, h('button', { class: 'link small', onclick: () => go('#/todos/done') }, 'All done →')),
      h('ul', { class: 'items' }, doneToday.map(i => itemRow(i, { space: true })))) : null,
    groups.length
      ? h('div', { class: 'card-grid' }, groups.map(([sp, list]) => {
          const all = items.filter(i => i.space_id === sp.id && i.kind === 'todo');
          return h('section', { class: 'card' },
            h('h2', {}, h('button', { class: 'link', onclick: () => go('#/space/' + encodeURIComponent(sp.id)) }, sp.name), h('span', { class: 'small muted' }, list.length)),
            progressBar(all.length - list.length, all.length),
            h('ul', { class: 'items' }, list.map(i => itemRow(i, { space: false }))));
        }))
      : h('p', { class: 'muted' }, 'Nothing to do. To-dos from your recordings show up here.'));
}

// ---------- ideas, questions, notes ----------
function collectedView(kind) {
  const k = kindById(kind);
  const all = liveItems().filter(i => i.kind === kind).sort(byNewest);
  let group = 'space';
  try { group = localStorage.getItem('slowclaw.collect.group') || 'space'; } catch {}
  const search = h('input', { type: 'search', placeholder: `Search ${k.label.toLowerCase()}`, value: state.itemQuery || '', 'aria-label': 'Search' });
  const grouping = h('select', { 'aria-label': 'Group by', onchange: e => { try { localStorage.setItem('slowclaw.collect.group', e.target.value); } catch {} group = e.target.value; draw(); } },
    h('option', { value: 'space' }, 'By space'), h('option', { value: 'month' }, 'By month'));
  grouping.value = group;
  const list = h('div');
  const counter = h('span', { class: 'small muted' });
  const draw = () => {
    const q = (state.itemQuery || '').toLowerCase().trim();
    const shown = all.filter(i => !q || i.text.toLowerCase().includes(q));
    counter.textContent = q ? `${shown.length} of ${all.length}` : '';
    if (!shown.length) { list.replaceChildren(h('p', { class: 'muted' }, q ? 'No matches.' : `No ${k.label.toLowerCase()} yet. They are picked out of your journals on your iPhone, or add one here.`)); return; }
    const buckets = new Map();
    for (const i of shown) {
      const key = group === 'month' ? new Date(i.created_at).toLocaleDateString(undefined, { month: 'long', year: 'numeric' }) : i.space_id;
      if (!buckets.has(key)) buckets.set(key, []);
      buckets.get(key).push(i);
    }
    let entries = [...buckets.entries()];
    if (group === 'space') {
      const order = sortedSpaces().map(s => s.id);
      entries.sort((a, b) => b[1].length - a[1].length || order.indexOf(a[0]) - order.indexOf(b[0]));
    }
    list.replaceChildren(h('div', { class: group === 'space' ? 'card-grid' : '' }, entries.map(([key, rows]) => h('section', { class: 'card' },
      h('h2', {}, group === 'space'
        ? h('button', { class: 'link', onclick: () => go('#/space/' + encodeURIComponent(key)) }, spaceById(key)?.name || 'Space')
        : key, h('span', { class: 'small muted' }, rows.length)),
      h('ul', { class: 'items' }, rows.map(i => itemRow(i, { space: group !== 'space' })))))));
  };
  search.addEventListener('input', () => { state.itemQuery = search.value; draw(); });
  draw();
  const sources = new Set(all.map(i => i.journal_id).filter(Boolean)).size;
  const spaces = new Set(all.map(i => i.space_id)).size;
  const thisMonth = all.filter(i => daysOld(i.created_at) < 30).length;
  const old = all.filter(i => daysOld(i.created_at) >= 21);
  let pick = pickForToday(old, kind.length);
  const pickBox = h('div');
  const showPick = () => pickBox.replaceChildren(pick ? h('section', { class: 'card resurface' },
    h('h2', {}, 'Worth another look', old.length > 1 ? h('button', { class: 'link small', onclick: () => { pick = old[Math.floor(Math.random() * old.length)]; showPick(); } }, 'Another') : null),
    h('p', { class: 'nudge-text' }, pick.text),
    h('div', { class: 'meta small muted' }, `From ${ago(pick.created_at)} · `, spaceChip(spaceById(pick.space_id)),
      journalById(pick.journal_id) ? h('button', { class: 'link source', onclick: () => go('#/journal/' + encodeURIComponent(pick.journal_id)) }, ' ↗ ' + journalTitle(journalById(pick.journal_id))) : null)) : '');
  showPick();
  return h('div', {},
    h('header', { class: 'page-head' }, h('div', {}, h('h1', {}, k.label),
      h('p', { class: 'muted' }, all.length
        ? `${plural(all.length, k.one)} from ${plural(sources, 'entry', 'entries')} across ${plural(spaces, 'space')} · ${thisMonth} in the last 30 days`
        : `Every ${k.one} from your journals, in one place.`))),
    pickBox,
    h('div', { class: 'toolbar wide' }, addItemRow(kind)),
    h('div', { class: 'toolbar' }, search, grouping, counter),
    list);
}

// ---------- a space ----------
function spaceView(id) {
  const space = spaceById(id);
  if (!space) return h('p', { class: 'muted' }, 'This space no longer exists.');
  const items = state.items.filter(i => i.space_id === id);
  const journals = state.journals.filter(j => j.space_id === id).sort(byNewest);
  const todos = items.filter(i => i.kind === 'todo');
  const doneWeek = todos.filter(i => i.done && between(doneAt(i), startOfWeek(new Date()), addDays(startOfDay(new Date()), 1))).length;
  return h('div', {},
    h('header', { class: 'page-head' },
      h('div', {}, h('h1', {}, space.name),
        h('p', { class: 'muted' }, `${plural(journals.length, 'entry', 'entries')}${journals[0] ? ' · last ' + ago(journals[0].created_at) : ''} · ${doneWeek} done this week`)),
      h('div', { class: 'toolbar small' },
        h('button', { onclick: () => renameSpace(space) }, 'Rename'),
        h('button', { onclick: () => deleteSpace(space) }, 'Delete space'))),
    space.summary ? h('section', { class: 'card overview' }, h('h2', {}, 'Overview'), h('div', { class: 'summary' }, space.summary)) : null,
    h('div', { class: 'card-grid two' }, KINDS.map(k => itemsCard(space, k, items.filter(i => i.kind === k.id)))),
    h('section', { class: 'card' },
      h('h2', {}, `Journal entries`, h('span', { class: 'small muted' }, journals.length)),
      journals.length ? h('ul', { class: 'journals' }, journals.map(journalRow)) : h('p', { class: 'muted small' }, 'No entries yet.')));
}

function itemsCard(space, kind, items) {
  const open = items.filter(i => !i.done).sort(byNewest);
  const done = items.filter(i => i.done).sort((a, b) => doneAt(b).localeCompare(doneAt(a)));
  return h('section', { class: 'card' },
    h('h2', {}, h('span', {}, h('span', { class: 'kind-' + kind.id, 'aria-hidden': 'true' }, kindGlyph[kind.id] + ' '), kind.label), h('span', { class: 'small muted' }, kind.id === 'todo' ? `${open.length} open` : open.length || '')),
    kind.id === 'todo' ? progressBar(done.length, items.length) : null,
    open.length ? h('ul', { class: 'items' }, open.map(i => itemRow(i, { space: false }))) : h('p', { class: 'muted small' }, `No ${kind.label.toLowerCase()} yet.`),
    kind.id === 'todo' && done.length ? h('details', {}, h('summary', { class: 'small muted' }, `Done (${done.length})`), h('ul', { class: 'items' }, done.map(i => itemRow(i, { space: false })))) : null,
    addItemRow(kind.id, space));
}

// ---------- book ----------
const PALETTE = ['#2563eb', '#ea580c', '#16a34a', '#db2777', '#9333ea', '#0d9488', '#dc2626', '#4f46e5', '#a16207', '#059669'];
const chapterColor = n => PALETTE[Math.abs(n) % PALETTE.length];

function bookChapters() {
  const all = [...state.book].filter(n => !n.deleted).sort((a, b) => a.position - b.position);
  const path = all.filter(n => (n.kind || 'passage') === 'passage');
  const chapters = [];
  for (const n of all) {
    const last = chapters[chapters.length - 1];
    if (last && last.id === n.chapter) last.nodes.push(n);
    else chapters.push({ id: n.chapter, title: n.chapter_title, nodes: [n] });
  }
  return { path, chapters };
}

function svg(tag, attrs = {}, ...children) {
  const el = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const [k, v] of Object.entries(attrs)) if (v != null) el.setAttribute(k, v);
  for (const c of children) if (c != null && c !== false) el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  return el;
}

function bookView() {
  const { path, chapters } = bookChapters();
  if (!path.length) return h('div', {}, h('h1', {}, 'Book'),
    h('p', { class: 'muted' }, 'Your book grows on your iPhone as you journal. Passages join only when they connect to what is already there and add something new.'));
  const jump = id => document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  const journal = id => state.journals.find(j => j.id === id);
  return h('div', { class: 'book' },
    h('h1', {}, 'Book'),
    h('p', { class: 'muted small' }, `${path.length} passages in ${chapters.length} chapters: grouped by theme on your iPhone, in the order you lived them.`),
    h('div', { class: 'card' }, h('h2', {}, 'Contents'),
      h('ol', { class: 'toc' }, chapters.map(c => h('li', {},
        h('button', { class: 'link', onclick: () => jump('c-' + c.id) },
          h('span', { class: 'dot', style: 'background:' + chapterColor(c.id) }), c.title || 'Chapter ' + (c.id + 1)),
        h('span', { class: 'muted small' }, ' · ' + c.nodes.filter(n => (n.kind || 'passage') === 'passage').length))))),
    chapters.map(c => h('section', { class: 'chapter', id: 'c-' + c.id },
      h('div', { class: 'muted small caps' }, 'Chapter ' + (c.id + 1)),
      h('h2', {}, c.title || 'Untitled'),
      c.nodes.map(n => {
        // Lines written on the phone to connect passages: shown as such, never as the author's words.
        if ((n.kind || 'passage') !== 'passage') return h('p', { class: 'book-line ' + n.kind, title: 'Connecting line written on the iPhone' }, n.text);
        const j = n.journal_id && journal(n.journal_id);
        return h('div', { class: 'passage', id: 'p-' + n.id },
          h('p', {}, n.text),
          j ? h('button', { class: 'link small', onclick: () => go('#/journal/' + encodeURIComponent(j.id)) },
            'From “' + journalTitle(j) + '”, ' + dayLabel(j.created_at)) : null);
      }))));
}

// ---------- news (local view only: the cards are made on the iPhone) ----------
function newsView() {
  const cards = state.news || [];
  return h('div', {},
    h('h1', {}, 'News'),
    h('p', { class: 'muted small' }, 'Stories on topics your iPhone found in your journal. Only the topic words were sent to Google News; summaries were written on the phone.'),
    cards.length ? h('div', { class: 'news-grid' }, cards.map(c => h('article', { class: 'news-card' },
      c.has_image ? h('img', { src: 'news-image/' + encodeURIComponent(c.id), alt: '', loading: 'lazy' })
                  : h('div', { class: 'news-fallback', style: 'background:' + chapterColor(c.topic.length) }, c.topic.slice(0, 1).toUpperCase()),
      h('div', { class: 'news-body' },
        h('div', { class: 'caps small accent' }, c.topic),
        h('h2', {}, c.headline),
        h('p', { class: 'muted' }, c.summary),
        h('details', {}, h('summary', { class: 'small muted' }, c.sources || 'Sources'),
          h('ul', { class: 'sources' }, c.articles.map(a => h('li', {},
            h('a', { href: a.url, target: '_blank', rel: 'noopener noreferrer' }, a.title), h('span', { class: 'muted small' }, ' · ' + a.source)))))))))
      : h('p', { class: 'muted' }, 'No stories yet. Open the News tab on your iPhone to fetch some.'));
}

// ---------- videos (local view only: chosen on the iPhone) ----------
function videosView() {
  const goals = state.videos || [];
  return h('div', {},
    h('h1', {}, 'Videos'),
    h('p', { class: 'muted small' }, 'Explanations for what your journal says you want to understand. Only the searches were sent to YouTube; the reasons were worked out on your iPhone.'),
    goals.length ? goals.map(g => h('div', { class: 'card' },
      h('h2', {}, g.label),
      h('p', { class: 'muted small' }, g.why),
      g.videos.length
        ? h('div', { class: 'video-grid' }, g.videos.map(v => h('a', { class: 'video', href: 'https://www.youtube.com/watch?v=' + encodeURIComponent(v.id), target: '_blank', rel: 'noopener noreferrer' },
            h('img', { src: 'https://i.ytimg.com/vi/' + encodeURIComponent(v.id) + '/hqdefault.jpg', alt: '', loading: 'lazy' }),
            h('span', { class: 'v-title' }, v.title),
            h('span', { class: 'muted small' }, [v.channel, v.duration].filter(Boolean).join(' · ')))))
        : h('a', { href: 'https://www.youtube.com/results?search_query=' + encodeURIComponent(g.query), target: '_blank', rel: 'noopener noreferrer' }, 'Search “' + g.query + '” on YouTube')))
      : h('p', { class: 'muted' }, 'No suggestions yet. Open Discover → Videos on your iPhone.'));
}

// ---------- actions ----------
function newJournal() {
  go('#/new');
}

async function addSpace() {
  const name = prompt('Name of the new space');
  if (!name || !name.trim()) return;
  const now = new Date().toISOString();
  const order = Math.max(0, ...state.spaces.map(s => s.sort_order)) + 1;
  await save('spaces', { id: uid('space'), name: name.trim(), icon: 'tray', summary: '', sort_order: order, created_at: now, deleted: false });
}

async function renameSpace(space) {
  const name = prompt('Rename space', space.name);
  if (name && name.trim()) await save('spaces', { ...space, name: name.trim() });
}

async function deleteSpace(space) {
  if (!confirm(`Delete “${space.name}”? Its journals become unsorted and its lists are removed.`)) return;
  await save('spaces', { ...space, deleted: true });
  for (const j of state.journals.filter(j => j.space_id === space.id)) await save('journals', { ...j, space_id: null });
  for (const i of state.items.filter(i => i.space_id === space.id)) await save('space_items', { ...i, deleted: true });
  go('#/');
}

// ---------- start ----------
(function start() {
  // Email confirmation and password recovery links land here with tokens in the hash.
  const params = new URLSearchParams(location.hash.replace(/^#/, ''));
  if (MODE === 'cloud' && params.get('access_token')) {
    adopt({
      access_token: params.get('access_token'),
      refresh_token: params.get('refresh_token'),
      expires_in: params.get('expires_in'),
      user: { email: '' },
    });
    history.replaceState(null, '', location.pathname + (params.get('type') === 'recovery' ? '#/set-password' : '#/'));
  } else {
    state.session = loadSession();
  }
  render();
  if (state.session && route().view !== 'set-password') loadAll();
  // N: new entry, /: search. Ignored while typing.
  document.addEventListener('keydown', e => {
    if (!state.session || e.metaKey || e.ctrlKey || e.altKey) return;
    const t = e.target;
    if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
    if (e.key === 'n' || e.key === 'N') { e.preventDefault(); newJournal(); }
    else if (e.key === '/') { const s = document.querySelector('main input[type=search]'); if (s) { e.preventDefault(); s.focus(); } }
    else if (e.key === 'Escape') document.querySelector('.side')?.classList.remove('open');
  });
  document.addEventListener('visibilitychange', () => { if (!document.hidden && state.session) loadAll(); });
  // The phone is the source of truth in local mode; pick up its changes now and then.
  if (MODE === 'local') setInterval(() => { if (!document.hidden && state.session && !editorOpen()) loadAll(); }, 30000);
})();
