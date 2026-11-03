// SlowClaw web: read and tend your journals, spaces and lists.
// Plain JavaScript, no build step. Talks to Supabase Auth + PostgREST directly;
// row-level security keeps every row private to its owner.

const SUPABASE_URL = 'https://docmtelcjyvfyjlujibb.supabase.co';
const SUPABASE_KEY = 'sb_publishable_w9ZdQLfwKjo56BDs24ziag_tt2_X_Z3';
const SESSION_KEY = 'slowclaw.session.v2';
const KINDS = [
  { id: 'todo', label: 'To-dos', one: 'to-do' },
  { id: 'idea', label: 'Ideas', one: 'idea' },
  { id: 'question', label: 'Questions', one: 'question' },
  { id: 'note', label: 'Notes', one: 'note' },
];

const state = { session: null, journals: [], spaces: [], items: [], loading: false, error: null, status: '' };
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

async function fetchAll(table) {
  const rows = [];
  for (let offset = 0; ; offset += 1000) {
    const page = await rest('GET', `${table}?select=*&deleted=eq.false&order=created_at.desc&limit=1000&offset=${offset}`);
    rows.push(...page);
    if (page.length < 1000) break;
  }
  return rows;
}

async function loadAll() {
  state.loading = true; state.error = null; render();
  try {
    if (!state.session.email) {
      const res = await fetch(SUPABASE_URL + '/auth/v1/user', { headers: { apikey: SUPABASE_KEY, Authorization: 'Bearer ' + (await token()) } });
      const user = await res.json().catch(() => ({}));
      if (user.email) saveSession({ ...state.session, email: user.email });
    }
    const [journals, spaces, items] = await Promise.all([fetchAll('journals'), fetchAll('spaces'), fetchAll('space_items')]);
    state.journals = journals; state.spaces = spaces; state.items = items;
  } catch (e) {
    state.error = e.message;
  }
  state.loading = false;
  render();
}

async function save(table, row) {
  const now = new Date().toISOString();
  const full = { ...row, updated_at: now };
  flash('Saving…');
  try {
    const [saved] = await rest('POST', `${table}?on_conflict=user_id,id`, [full]);
    const list = state[table === 'space_items' ? 'items' : table];
    const i = list.findIndex(r => r.id === saved.id);
    if (saved.deleted) { if (i >= 0) list.splice(i, 1); }
    else if (i >= 0) list[i] = saved; else list.unshift(saved);
    flash('Saved');
  } catch (e) {
    flash(e.message, true);
  }
  render();
}

const uid = prefix => prefix + '_' + (crypto.randomUUID ? crypto.randomUUID()
  : Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join(''));

let flashTimer;
function flash(text, sticky) {
  state.status = text;
  const el = document.querySelector('.status');
  if (el) el.textContent = text; else if (text) document.body.append(h('div', { class: 'status' }, text));
  clearTimeout(flashTimer);
  if (!sticky) flashTimer = setTimeout(() => { state.status = ''; document.querySelector('.status')?.remove(); }, 1500);
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
const journalTitle = j => (j.title || '').trim() || (j.body || '').split('\n')[0].slice(0, 60) || 'Untitled';
function dayLabel(iso) {
  const d = new Date(iso), today = new Date();
  const y = new Date(); y.setDate(today.getDate() - 1);
  if (d.toDateString() === today.toDateString()) return 'Today';
  if (d.toDateString() === y.toDateString()) return 'Yesterday';
  return d.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'short', year: d.getFullYear() === today.getFullYear() ? undefined : 'numeric' });
}

// ---------- views ----------
function render() {
  app.replaceChildren(state.session ? shell() : authView());
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
  return h('div', { class: 'auth' },
    h('h1', {}, 'SlowClaw'),
    h('p', { class: 'muted' }, 'Your journals, sorted into spaces with to-dos, ideas and questions. Use the same account as the iPhone app.'),
    h('form', { onsubmit: submit },
      email, password,
      h('button', { class: 'primary', type: 'submit' }, mode === 'signin' ? 'Sign in' : 'Create account'),
      h('div', { class: 'row small' },
        h('button', { class: 'link', type: 'button', onclick: () => swap(mode === 'signin' ? 'signup' : 'signin') },
          mode === 'signin' ? 'Create an account' : 'I already have an account'),
        h('button', { class: 'link', type: 'button', onclick: async () => {
          if (!email.value) return show('Enter your email first.');
          try { await auth('/auth/v1/recover', { email: email.value }); show('Password reset email sent.'); } catch (err) { show(err.message); }
        } }, 'Forgot password')),
      note));
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
    h('div', { class: 'brand' }, 'SlowClaw', h('button', { class: 'icon', title: 'Refresh', onclick: loadAll }, '↻')),
    h('ul', { class: 'nav' },
      navItem('All journals', '#/journals', state.journals.length, r.view === 'journals'),
      navItem('Unsorted', '#/unsorted', unsorted.length, r.view === 'unsorted')),
    h('div', { class: 'nav-title' }, 'Spaces'),
    h('ul', { class: 'nav' },
      sortedSpaces().map(s => navItem(s.name, '#/space/' + encodeURIComponent(s.id), openTodos(s.id) || '', r.view === 'space' && r.id === s.id)),
      h('li', {}, h('button', { class: 'muted', onclick: addSpace }, '+ New space'))),
    h('div', { class: 'side-foot' },
      h('span', {}, state.session.email),
      h('button', { class: 'link', onclick: () => { saveSession(null); state.journals = []; state.spaces = []; state.items = []; render(); } }, 'Sign out')));

  let content;
  if (state.loading && !state.journals.length && !state.spaces.length) content = h('p', { class: 'muted' }, 'Loading…');
  else if (r.view === 'space') content = spaceView(r.id);
  else if (r.view === 'journal') content = journalView(r.id);
  else if (r.view === 'unsorted') content = journalsView('Unsorted', unsorted, 'Journals the phone has not filed yet. Open one to choose a space.');
  else content = journalsView('Journal', state.journals);

  const main = h('main', {},
    h('button', { class: 'menu-btn', onclick: () => side.classList.toggle('open') }, '☰ Spaces'),
    state.error ? h('div', { class: 'notice' }, state.error) : null,
    content);
  return h('div', { class: 'shell' }, side, main);
}

function journalsView(title, journals, hint) {
  const search = h('input', { type: 'text', placeholder: 'Search', value: state.query || '' });
  const list = h('div');
  const draw = () => {
    const q = (state.query || '').toLowerCase();
    const shown = [...journals]
      .filter(j => !q || (j.title + ' ' + j.body).toLowerCase().includes(q))
      .sort((a, b) => b.created_at.localeCompare(a.created_at));
    let lastDay = '';
    const nodes = [];
    for (const j of shown) {
      const day = dayLabel(j.created_at);
      if (day !== lastDay) { nodes.push(h('div', { class: 'day' }, day)); lastDay = day; }
      nodes.push(journalRow(j));
    }
    list.replaceChildren(shown.length ? h('ul', { class: 'journals' }, nodes) : h('p', { class: 'muted' }, q ? 'No matches.' : 'Nothing here yet. Record a journal on your iPhone and it shows up here.'));
  };
  search.addEventListener('input', () => { state.query = search.value; draw(); });
  draw();
  return h('div', {},
    h('h1', {}, title),
    hint ? h('p', { class: 'muted' }, hint) : null,
    h('div', { class: 'toolbar' }, search, h('button', { onclick: newJournal }, '+ New entry')),
    list);
}

function journalRow(j) {
  const space = spaceById(j.space_id);
  return h('li', {}, h('button', { onclick: () => go('#/journal/' + encodeURIComponent(j.id)) },
    h('span', { class: 'title' }, journalTitle(j)),
    j.body ? h('span', { class: 'snippet' }, j.body) : null,
    h('span', { class: 'small muted' },
      new Date(j.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }), ' ',
      space ? h('span', { class: 'chip' }, space.name) : null)));
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
      journals.length ? h('ul', { class: 'journals' }, journals.map(journalRow)) : h('p', { class: 'muted small' }, 'No entries yet.')));
}

function itemsCard(space, kind, items) {
  const open = items.filter(i => !i.done).sort((a, b) => b.created_at.localeCompare(a.created_at));
  const done = items.filter(i => i.done);
  const input = h('input', { type: 'text', placeholder: `Add ${kind.one}…` });
  const add = () => {
    const text = input.value.trim();
    if (!text) return;
    const now = new Date().toISOString();
    save('space_items', { id: uid('item'), space_id: space.id, journal_id: null, kind: kind.id, text, done: false, created_at: now, deleted: false });
  };
  input.addEventListener('keydown', e => { if (e.key === 'Enter') add(); });
  const row = (item) => h('li', { class: item.done ? 'done' : '' },
    kind.id === 'todo'
      ? h('input', { type: 'checkbox', checked: item.done, 'aria-label': 'Done', onchange: e => save('space_items', { ...item, done: e.target.checked }) })
      : null,
    h('span', { class: 'text' }, item.text),
    item.journal_id && state.journals.some(j => j.id === item.journal_id)
      ? h('button', { class: 'icon', title: 'Open source journal', onclick: () => go('#/journal/' + encodeURIComponent(item.journal_id)) }, '↗')
      : null,
    h('button', { class: 'icon', title: 'Delete', onclick: () => save('space_items', { ...item, deleted: true }) }, '×'));
  return h('div', { class: 'card' },
    h('h2', {}, kind.label, done.length && kind.id === 'todo' ? h('span', { class: 'small muted' }, `${done.length} done`) : null),
    open.length ? h('ul', { class: 'items' }, open.map(row)) : h('p', { class: 'muted small' }, `No ${kind.label.toLowerCase()} yet.`),
    kind.id === 'todo' && done.length ? h('details', {}, h('summary', { class: 'small muted' }, 'Show done'), h('ul', { class: 'items' }, done.map(row))) : null,
    h('div', { class: 'add-row' }, input, h('button', { onclick: add }, 'Add')));
}

function journalView(id) {
  const j = state.journals.find(x => x.id === id);
  if (!j) return h('p', { class: 'muted' }, 'This entry was not found.');
  const title = h('input', { class: 'title-input', type: 'text', value: j.title, placeholder: 'Title' });
  const body = h('textarea', { value: j.body });
  const select = h('select', {},
    h('option', { value: '' }, 'Unsorted'),
    sortedSpaces().map(s => h('option', { value: s.id }, s.name)));
  select.value = j.space_id || '';
  const fromThis = state.items.filter(i => i.journal_id === id);
  return h('div', { class: 'editor' },
    h('button', { class: 'link', onclick: () => history.back() }, '← Back'),
    title,
    h('div', { class: 'small muted' }, new Date(j.created_at).toLocaleString()),
    h('label', { class: 'small muted' }, 'Space', select),
    body,
    h('div', { class: 'toolbar' },
      h('button', { class: 'primary', onclick: () => save('journals', { ...j, title: title.value.trim(), body: body.value, space_id: select.value || null }) }, 'Save'),
      h('button', { onclick: () => { if (confirm('Delete this entry?')) { save('journals', { ...j, deleted: true, title: '', body: '' }); go('#/'); } } }, 'Delete')),
    fromThis.length ? h('div', { class: 'card' }, h('h2', {}, 'From this entry'),
      h('ul', { class: 'items' }, fromThis.map(i => h('li', {}, h('span', { class: 'chip' }, i.kind), h('span', { class: 'text' }, i.text))))) : null);
}

// ---------- actions ----------
async function newJournal() {
  const id = uid('journal');
  const now = new Date().toISOString();
  await save('journals', { id, title: '', body: '', space_id: null, created_at: now, deleted: false });
  go('#/journal/' + encodeURIComponent(id));
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
  if (params.get('access_token')) {
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
})();
