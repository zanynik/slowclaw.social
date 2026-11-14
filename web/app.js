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

const state = { session: null, journals: [], spaces: [], items: [], book: [], news: null, videos: null, reads: null, loading: false, error: null, query: '' };
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
  Object.assign(state, { journals: [], spaces: [], items: [], book: [], news: null, videos: null, reads: null, error: null, query: '' });
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
      Object.assign(state, { journals: d.journals, spaces: d.spaces, items: d.space_items, book: d.book_nodes, news: d.news, videos: d.videos || null, reads: d.reads || null });
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

async function save(table, row, { quiet = false, done = 'Saved', undo = null } = {}) {
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
    flash(done, { undo });
  } catch (e) {
    flash(e.message, { sticky: true });
    return false;
  }
  if (!quiet) render();
  return true;
}

const uid = prefix => prefix + '_' + (crypto.randomUUID ? crypto.randomUUID()
  : Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join(''));

// One small message in the corner. `undo` adds a button and keeps the message up a little longer.
let flashTimer;
function flash(text, { sticky = false, undo = null } = {}) {
  const el = document.getElementById('status');
  clearTimeout(flashTimer);
  const hide = () => { el.hidden = true; el.replaceChildren(); };
  el.replaceChildren(text, undo ? h('button', { class: 'link', onclick: () => { hide(); undo(); } }, 'Undo') : '');
  el.hidden = !text;
  if (!sticky) flashTimer = setTimeout(hide, undo ? 6000 : 1500);
}

// ---------- routing ----------
function route() {
  const parts = location.hash.replace(/^#\/?/, '').split('/');
  return { view: parts[0] || 'journals', id: decodeURIComponent(parts[1] || '') };
}
const go = hash => { location.hash = hash; };
window.addEventListener('hashchange', () => { document.querySelector('.side')?.classList.remove('open'); render(); });

// ---------- helpers ----------
const spaceById = id => state.spaces.find(s => s.id === id);
const sortedSpaces = () => [...state.spaces].sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name));
const words = text => (text.trim().match(/\S+/g) || []).length;
const typing = () => /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName || '');
const journalTitle = j => (j.title || '').trim() || (j.body || '').split('\n')[0].slice(0, 60) || 'Untitled';
function dayLabel(iso) {
  const d = new Date(iso), today = new Date();
  const y = new Date(); y.setDate(today.getDate() - 1);
  if (d.toDateString() === today.toDateString()) return 'Today';
  if (d.toDateString() === y.toDateString()) return 'Yesterday';
  return d.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'short', year: d.getFullYear() === today.getFullYear() ? undefined : 'numeric' });
}

// ---------- views ----------
const TITLES = { journals: 'Journal', todos: 'To-dos', book: 'Book', news: 'News', videos: 'Videos', reads: 'Reads', unsorted: 'Unsorted', new: 'New entry' };
function pageTitle() {
  const r = route();
  if (!state.session) return 'SlowClaw';
  const name = r.view === 'space' ? spaceById(r.id)?.name
    : r.view === 'journal' ? (j => j && journalTitle(j))(state.journals.find(j => j.id === r.id))
    : TITLES[r.view];
  return name ? name + ' · SlowClaw' : 'SlowClaw';
}

function render() {
  stopPairing();
  // Adding several things in a row: the box you typed in keeps the cursor after the redraw.
  const focused = document.activeElement?.dataset?.add;
  app.replaceChildren(state.session ? shell() : MODE === 'local' ? pairView() : authView());
  document.title = pageTitle();
  if (focused) app.querySelector(`[data-add="${CSS.escape(focused)}"]`)?.focus();
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
          go('#/'); render(); loadAll();
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
  const openTodos = id => state.items.filter(i => i.space_id === id && i.kind === 'todo' && !i.done).length;
  const navItem = (label, hash, count, active) =>
    h('li', {}, h('button', { class: active ? 'active' : '', onclick: () => go(hash) }, h('span', {}, label), count ? h('span', { class: 'count' }, count) : null));
  const unsorted = state.journals.filter(j => !spaceById(j.space_id));
  side.append(
    h('div', { class: 'brand' }, 'SlowClaw', h('button', { class: 'icon', title: 'Refresh', 'aria-label': 'Refresh', onclick: loadAll }, '↻')),
    h('ul', { class: 'nav' },
      navItem('All journals', '#/journals', state.journals.length, r.view === 'journals'),
      navItem('To-dos', '#/todos', state.items.filter(i => i.kind === 'todo' && !i.done && spaceById(i.space_id)).length, r.view === 'todos'),
      navItem('Book', '#/book', state.book.filter(isPassage).length, r.view === 'book'),
      state.news ? navItem('News', '#/news', state.news.length, r.view === 'news') : null,
      state.videos ? navItem('Videos', '#/videos', state.videos.reduce((n, g) => n + g.videos.length, 0), r.view === 'videos') : null,
      state.reads ? navItem('Reads', '#/reads', state.reads.reduce((n, g) => n + g.articles.length, 0), r.view === 'reads') : null,
      navItem('Unsorted', '#/unsorted', unsorted.length, r.view === 'unsorted')),
    h('div', { class: 'nav-title' }, 'Spaces'),
    h('ul', { class: 'nav' },
      sortedSpaces().map(s => navItem(s.name, '#/space/' + encodeURIComponent(s.id), openTodos(s.id) || '', r.view === 'space' && r.id === s.id)),
      h('li', {}, h('button', { class: 'muted', onclick: addSpace }, '+ New space'))),
    h('div', { class: 'side-foot' },
      MODE === 'local' ? h('span', {}, 'Local view · nothing goes online') : null,
      h('span', {}, /@phone\.slowclaw\.invalid$/.test(state.session.email || '') ? 'Signed in with your iPhone' : state.session.email),
      h('button', { class: 'link', onclick: signOut }, 'Sign out')));

  let content;
  if (state.loading && !state.journals.length && !state.spaces.length) content = h('p', { class: 'muted' }, 'Loading…');
  else if (r.view === 'space') content = spaceView(r.id);
  else if (r.view === 'journal') content = journalView(r.id);
  else if (r.view === 'new') content = journalView(null);
  else if (r.view === 'todos') content = todosView();
  else if (r.view === 'book') content = bookView(r.id);
  else if (r.view === 'news' && state.news) content = newsView();
  else if (r.view === 'videos' && state.videos) content = videosView();
  else if (r.view === 'reads' && state.reads) content = readsView();
  else if (r.view === 'unsorted') content = journalsView('Unsorted', unsorted, 'Journals the phone has not filed yet. Open one to choose a space.');
  else content = journalsView('Journal', state.journals);

  const backdrop = h('div', { class: 'backdrop', onclick: () => side.classList.remove('open') });
  const main = h('main', {},
    h('button', { class: 'menu-btn', 'aria-label': 'Open menu', onclick: () => side.classList.add('open') }, '☰ Menu'),
    state.error ? h('div', { class: 'notice', role: 'alert' }, state.error, ' ', h('button', { class: 'link', onclick: loadAll }, 'Try again')) : null,
    content);
  return h('div', { class: 'shell' }, side, backdrop, main);
}

function journalsView(title, journals, hint) {
  const search = h('input', { type: 'search', class: 'search', placeholder: 'Search  ( / )', 'aria-label': 'Search journals', value: state.query || '' });
  const list = h('div');
  const draw = () => {
    const q = (state.query || '').toLowerCase();
    const shown = [...journals]
      .filter(j => !q || (j.title + ' ' + j.body + ' ' + (spaceById(j.space_id)?.name || '')).toLowerCase().includes(q))
      .sort((a, b) => b.created_at.localeCompare(a.created_at));
    let lastDay = '';
    const nodes = [];
    for (const j of shown) {
      const day = dayLabel(j.created_at);
      if (day !== lastDay) { nodes.push(h('li', { class: 'day' }, day)); lastDay = day; }
      nodes.push(journalRow(j));
    }
    list.replaceChildren(shown.length ? h('ul', { class: 'journals' }, nodes)
      : h('p', { class: 'muted empty' }, q ? `Nothing matches “${state.query.trim()}”.` : 'Nothing here yet. Record a journal on your iPhone and it shows up here.'));
  };
  search.addEventListener('input', () => { state.query = search.value; draw(); });
  draw();
  return h('div', {},
    h('h1', {}, title),
    hint ? h('p', { class: 'muted' }, hint) : null,
    h('div', { class: 'toolbar' }, search, h('button', { onclick: newJournal }, '+ New entry')),
    list);
}

// `withDay` is for lists that are not grouped under day headings.
function journalRow(j, withDay = false) {
  const space = spaceById(j.space_id);
  return h('li', {}, h('button', { onclick: () => go('#/journal/' + encodeURIComponent(j.id)) },
    h('span', { class: 'title' }, journalTitle(j)),
    j.body ? h('span', { class: 'snippet' }, j.body) : null,
    h('span', { class: 'small muted' },
      withDay ? dayLabel(j.created_at) + ', ' : '',
      new Date(j.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }), ' ',
      space && !withDay ? h('span', { class: 'chip' }, space.name) : null)));
}

// One line of a list: tick it (to-dos), click the text to edit it, or remove it.
function itemRow(item) {
  const text = h('span', { class: 'text', tabindex: '0', role: 'button', title: 'Click to edit' }, item.text);
  const edit = () => {
    const input = h('input', { type: 'text', class: 'text', value: item.text, 'aria-label': 'Edit' });
    let finished = false;
    const finish = (keep) => {
      if (finished) return;
      finished = true;
      const next = input.value.trim();
      if (keep && next && next !== item.text) save('space_items', { ...item, text: next });
      else input.replaceWith(text);
    };
    input.addEventListener('keydown', e => { if (e.key === 'Enter') finish(true); if (e.key === 'Escape') finish(false); });
    input.addEventListener('blur', () => finish(true));
    text.replaceWith(input);
    input.focus();
  };
  text.addEventListener('click', edit);
  text.addEventListener('keydown', e => { if (e.key === 'Enter') edit(); });
  const toggle = done => save('space_items', { ...item, done }, done
    ? { done: 'Done', undo: () => save('space_items', { ...state.items.find(i => i.id === item.id) || item, done: false }) } : {});
  const remove = () => save('space_items', { ...item, deleted: true }, { done: 'Removed', undo: () => save('space_items', { ...item, deleted: false }) });
  return h('li', { class: item.done ? 'done' : '' },
    item.kind === 'todo' ? h('input', { type: 'checkbox', checked: item.done, 'aria-label': 'Done: ' + item.text, onchange: e => toggle(e.target.checked) }) : null,
    text,
    item.journal_id && state.journals.some(j => j.id === item.journal_id)
      ? h('button', { class: 'icon', title: 'Open the entry this came from', 'aria-label': 'Open the entry this came from', onclick: () => go('#/journal/' + encodeURIComponent(item.journal_id)) }, '↗')
      : null,
    h('button', { class: 'icon', title: 'Remove', 'aria-label': 'Remove: ' + item.text, onclick: remove }, '×'));
}

// The text box that adds to a list. `key` lets render() give it the cursor back.
function addBox(key, placeholder, make) {
  const input = h('input', { type: 'text', placeholder, 'data-add': key, 'aria-label': placeholder });
  const add = () => {
    const text = input.value.trim();
    if (!text) return input.focus();
    input.value = '';
    save('space_items', { id: uid('item'), journal_id: null, text, done: false, created_at: new Date().toISOString(), deleted: false, ...make() });
  };
  input.addEventListener('keydown', e => { if (e.key === 'Enter') add(); });
  return { input, button: h('button', { onclick: add }, 'Add') };
}

function spaceView(id) {
  const space = spaceById(id);
  if (!space) return h('p', { class: 'muted' }, 'This space no longer exists.');
  const items = state.items.filter(i => i.space_id === id);
  const journals = state.journals.filter(j => j.space_id === id);
  return h('div', {},
    h('h1', {}, space.name),
    h('div', { class: 'toolbar small' },
      h('button', { onclick: () => renameSpace(space) }, 'Rename'),
      h('button', { onclick: () => deleteSpace(space) }, 'Delete space')),
    space.summary ? h('div', { class: 'card' }, h('h2', {}, 'Overview'), h('div', { class: 'summary' }, space.summary)) : null,
    KINDS.map(k => itemsCard(space, k, items.filter(i => i.kind === k.id))),
    h('div', { class: 'card' },
      h('h2', {}, `Journal entries (${journals.length})`),
      journals.length ? h('ul', { class: 'journals' }, journals.map(j => journalRow(j, true))) : h('p', { class: 'muted small' }, 'No entries yet.')));
}

function itemsCard(space, kind, items) {
  const open = items.filter(i => !i.done).sort((a, b) => b.created_at.localeCompare(a.created_at));
  const done = items.filter(i => i.done);
  const add = addBox(kind.id + ':' + space.id, `Add ${kind.one}…`, () => ({ space_id: space.id, kind: kind.id }));
  return h('div', { class: 'card' },
    h('h2', {}, kind.label, done.length && kind.id === 'todo' ? h('span', { class: 'small muted' }, `${done.length} done`) : null),
    open.length ? h('ul', { class: 'items' }, open.map(itemRow)) : h('p', { class: 'muted small' }, `No ${kind.label.toLowerCase()} yet.`),
    kind.id === 'todo' && done.length ? h('details', {}, h('summary', { class: 'small muted' }, 'Show done'), h('ul', { class: 'items' }, done.map(itemRow))) : null,
    h('div', { class: 'add-row' }, add.input, add.button));
}

function journalView(id) {
  // id === null is a new entry that is only stored once it has some text.
  let j = id === null ? null : state.journals.find(x => x.id === id);
  if (id !== null && !j) return h('p', { class: 'muted' }, 'This entry was not found.');
  const isNew = !j;
  if (isNew) j = { id: uid('journal'), title: '', body: '', space_id: null, created_at: new Date().toISOString(), deleted: false };
  let stored = !isNew;
  const title = h('input', { class: 'title-input', type: 'text', value: j.title, placeholder: 'Title', 'aria-label': 'Title' });
  const body = h('textarea', { value: j.body, placeholder: isNew ? 'Write…' : null, 'aria-label': 'Entry text' });
  const count = h('span', {});
  const fit = () => {
    body.style.height = 'auto';
    body.style.height = Math.max(220, body.scrollHeight + 2) + 'px';
    const n = words(body.value);
    count.textContent = n ? ` · ${n} ${n === 1 ? 'word' : 'words'}` : '';
  };
  setTimeout(fit, 0);
  const select = h('select', {},
    h('option', { value: '' }, 'Unsorted'),
    sortedSpaces().map(s => h('option', { value: s.id }, s.name)));
  select.value = j.space_id || '';
  const current = () => ({ ...j, title: title.value.trim(), body: body.value, space_id: select.value || null });
  const dirty = () => { const c = current(); return c.title !== j.title || c.body !== j.body || c.space_id !== (j.space_id || null); };

  // Autosave quietly a moment after typing stops, and when leaving the page. Saves run one
  // after another, so a blur and a page change at the same moment cannot store the entry twice.
  let timer, closed = false, left = false, queue = Promise.resolve();
  const persist = () => queue = queue.then(async () => {
    clearTimeout(timer);
    if (closed || !dirty()) return;
    const next = current();
    if (!stored && !next.title && !next.body.trim()) return;
    if (!(await save('journals', next, { quiet: true }))) return;
    j = state.journals.find(x => x.id === next.id) || next;
    if (!stored) {
      stored = true;
      if (!left) history.replaceState(null, '', '#/journal/' + encodeURIComponent(next.id));
    }
    // Already on another page: redraw it with the text that was just saved.
    if (left) renderUnlessEditing();
  });
  const later = () => { clearTimeout(timer); timer = setTimeout(persist, 1200); };
  title.addEventListener('input', later);
  body.addEventListener('input', () => { later(); fit(); });
  select.addEventListener('change', () => persist());
  title.addEventListener('blur', () => persist());
  body.addEventListener('blur', () => persist());
  window.addEventListener('hashchange', () => { left = true; persist(); }, { once: true });

  const fromThis = isNew ? [] : state.items.filter(i => i.journal_id === id);
  if (isNew) setTimeout(() => body.focus(), 0);
  return h('div', { class: 'editor' },
    h('button', { class: 'link', onclick: () => history.back() }, '← Back'),
    title,
    h('div', { class: 'small muted' }, new Date(j.created_at).toLocaleString([], { dateStyle: 'full', timeStyle: 'short' }), count, ' · saves automatically'),
    h('label', { class: 'small muted' }, 'Space', select),
    body,
    h('div', { class: 'toolbar' },
      h('button', { class: 'primary', onclick: () => go('#/') }, 'Done'),
      isNew ? null : h('button', { onclick: () => { if (confirm('Delete this entry?')) { closed = true; clearTimeout(timer); save('journals', { ...j, deleted: true, title: '', body: '' }); go('#/'); } } }, 'Delete')),
    fromThis.length ? h('div', { class: 'card' }, h('h2', {}, 'From this entry'),
      h('ul', { class: 'items' }, fromThis.map(i => h('li', {}, h('span', { class: 'chip' }, KINDS.find(k => k.id === i.kind)?.one || i.kind), h('span', { class: 'text' }, i.text))))) : null);
}

function todosView() {
  const spaces = sortedSpaces();
  if (!spaces.length) return h('div', {}, h('h1', {}, 'To-dos'), h('p', { class: 'muted' }, 'Create a space first.'));
  let last = '';
  try { last = localStorage.getItem('slowclaw.todos.space') || ''; } catch {}
  const select = h('select', { 'aria-label': 'Space for the new to-do' }, spaces.map(s => h('option', { value: s.id }, s.name)));
  select.value = spaceById(last) ? last : spaces[0].id;
  select.addEventListener('change', () => { try { localStorage.setItem('slowclaw.todos.space', select.value); } catch {} });
  const add = addBox('todo', 'Add a to-do…', () => ({ space_id: select.value, kind: 'todo' }));
  const groups = spaces.map(s => [s, state.items.filter(i => i.space_id === s.id && i.kind === 'todo' && !i.done)
    .sort((a, b) => b.created_at.localeCompare(a.created_at))]).filter(([, list]) => list.length);
  return h('div', {},
    h('h1', {}, 'To-dos'),
    h('div', { class: 'add-row' }, add.input, select, add.button),
    groups.length
      ? groups.map(([s, list]) => h('div', { class: 'card' },
          h('h2', {}, h('button', { class: 'link', onclick: () => go('#/space/' + encodeURIComponent(s.id)) }, s.name)),
          h('ul', { class: 'items' }, list.map(itemRow))))
      : h('p', { class: 'muted empty' }, 'Nothing to do. To-dos from your recordings show up here.'));
}

// ---------- book ----------
const PALETTE = ['#2563eb', '#ea580c', '#16a34a', '#db2777', '#9333ea', '#0d9488', '#dc2626', '#4f46e5', '#a16207', '#059669'];
const chapterColor = n => PALETTE[Math.abs(n) % PALETTE.length];

const isPassage = n => (n.kind || 'passage') === 'passage';

function bookChapters() {
  const all = [...state.book].filter(n => !n.deleted).sort((a, b) => a.position - b.position);
  const path = all.filter(isPassage);
  const chapters = [];
  for (const n of all) {
    const last = chapters[chapters.length - 1];
    if (last && last.id === n.chapter) last.nodes.push(n);
    else chapters.push({ id: n.chapter, title: n.chapter_title, nodes: [n] });
  }
  return { path, chapters };
}

function bookView() {
  const { path, chapters } = bookChapters();
  if (!path.length) return h('div', {}, h('h1', {}, 'Book'),
    h('p', { class: 'muted empty' }, 'Your book grows on your iPhone as you journal: the passages worth keeping, grouped into chapters by theme.'));
  const jump = id => document.getElementById(id)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  const journal = id => state.journals.find(j => j.id === id);
  return h('div', { class: 'book' },
    h('h1', {}, 'Book'),
    h('p', { class: 'muted small' }, `${path.length} passages in ${chapters.length} chapters: grouped by theme on your iPhone, in the order you lived them.`),
    h('div', { class: 'card' }, h('h2', {}, 'Contents'),
      h('ol', { class: 'toc' }, chapters.map(c => h('li', {},
        h('button', { class: 'link', onclick: () => jump('c-' + c.id) },
          h('span', { class: 'dot', style: 'background:' + chapterColor(c.id) }), c.title || 'Chapter ' + (c.id + 1)),
        h('span', { class: 'muted small' }, ' · ' + c.nodes.filter(isPassage).length))))),
    chapters.map(c => h('section', { class: 'chapter', id: 'c-' + c.id },
      h('div', { class: 'muted small caps' }, 'Chapter ' + (c.id + 1)),
      h('h2', {}, c.title || 'Untitled'),
      c.nodes.map(n => {
        // Lines written on the phone to connect passages: shown as such, never as the author's words.
        if (!isPassage(n)) return h('p', { class: 'book-line ' + n.kind, title: 'Connecting line written on the iPhone' }, n.text);
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
    h('p', { class: 'muted small' }, 'Stories for the chapters of your book. Only topic searches were sent to Google News; the phone kept the ones close to what you wrote.'),
    cards.length ? h('div', { class: 'news-grid' }, cards.map(c => h('article', { class: 'news-card' },
      c.has_image ? h('img', { src: 'news-image/' + encodeURIComponent(c.id), alt: '', loading: 'lazy' })
                  : h('div', { class: 'news-fallback', style: 'background:' + chapterColor(c.topic.length) }, c.topic.slice(0, 1).toUpperCase()),
      h('div', { class: 'news-body' },
        h('div', { class: 'caps small accent' }, c.topic),
        h('h2', {}, c.headline),
        c.summary ? h('p', { class: 'muted' }, c.summary) : null,
        h('details', {}, h('summary', { class: 'small muted' }, c.sources || 'Sources'),
          h('ul', { class: 'sources' }, c.articles.map(a => h('li', {},
            h('a', { href: a.url, target: '_blank', rel: 'noopener noreferrer' }, a.title), h('span', { class: 'muted small' }, ' · ' + a.source)))))))))
      : h('p', { class: 'muted' }, 'No stories yet. Open the News tab on your iPhone to fetch some.'));
}

// ---------- videos and reads (local view only: matched on the iPhone) ----------
function videosView() {
  const groups = state.videos || [];
  return h('div', {},
    h('h1', {}, 'Videos'),
    h('p', { class: 'muted small' }, 'Recent videos from your channels, matched on your iPhone to the chapters of your book. Nothing about you was sent.'),
    groups.length ? groups.map(g => h('div', { class: 'card' },
      h('h2', {}, g.label),
      h('div', { class: 'video-grid' }, g.videos.map(v => h('a', { class: 'video', href: 'https://www.youtube.com/watch?v=' + encodeURIComponent(v.id), target: '_blank', rel: 'noopener noreferrer' },
        h('img', { src: 'https://i.ytimg.com/vi/' + encodeURIComponent(v.id) + '/hqdefault.jpg', alt: '', loading: 'lazy' }),
        h('span', { class: 'v-title' }, v.title),
        h('span', { class: 'muted small' }, v.channel))))))
      : h('p', { class: 'muted empty' }, 'No videos yet. Open Discover → Videos on your iPhone.'));
}

function readsView() {
  const groups = state.reads || [];
  // Only http(s) links are followed; anything else stays plain text.
  const safe = url => /^https?:\/\//.test(url || '') ? url : null;
  return h('div', {},
    h('h1', {}, 'Reads'),
    h('p', { class: 'muted small' }, 'Long essays from writers you chose, published on Nostr and matched on your iPhone to the chapters of your book.'),
    groups.length ? groups.map(g => h('div', { class: 'card' },
      h('h2', {}, g.label),
      h('ul', { class: 'reads' }, g.articles.map(a => h('li', {},
        safe(a.url) ? h('a', { class: 'read-title', href: safe(a.url), target: '_blank', rel: 'noopener noreferrer' }, a.title) : h('span', { class: 'read-title' }, a.title),
        a.summary ? h('p', { class: 'muted' }, a.summary) : null,
        h('span', { class: 'muted small' }, [a.author, a.minutes ? a.minutes + ' min read' : '', a.published ? dayLabel(a.published) : ''].filter(Boolean).join(' · ')))))))
      : h('p', { class: 'muted empty' }, 'No essays yet. Open Discover → Reads on your iPhone.'));
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

// ---------- keyboard ----------
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') document.querySelector('.side.open')?.classList.remove('open');
  if (!state.session || typing() || e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.key === '/') { const box = document.querySelector('input.search'); if (box) { e.preventDefault(); box.focus(); } }
  if (e.key === 'n') { e.preventDefault(); newJournal(); }
});

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
  document.addEventListener('visibilitychange', () => { if (!document.hidden && state.session) loadAll(); });
  // The phone is the source of truth in local mode; pick up its changes now and then.
  if (MODE === 'local') setInterval(() => { if (!document.hidden && state.session && !editorOpen()) loadAll(); }, 30000);
})();
