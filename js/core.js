import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
export const BASE = new URL('.', location.href).href;

/* SERVER TIME */
let serverOffsetMs = 0;
export async function syncServerTime() {
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/time_slots?select=slot_id&limit=1`, {
      method: 'GET',
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` },
      cache: 'no-store',
    });
    const d = res.headers.get('date');
    if (d) serverOffsetMs = new Date(d).getTime() - Date.now();
  } catch {}
}
export function nowDate() { return new Date(Date.now() + serverOffsetMs); }
export function todayISO() {
  const d = nowDate();
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}

/* AUTH */
const HB_KEY = 'lastHeartbeat';
function maybeHeartbeat() {
  try {
    const last = parseInt(sessionStorage.getItem(HB_KEY) || '0', 10);
    if (Date.now() - last > 15 * 60 * 1000) {
      sessionStorage.setItem(HB_KEY, String(Date.now()));
      supabase.rpc('heartbeat').then(() => {}).catch(() => {});
    }
  } catch {}
}
const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
let lastActivity = Date.now();
let idleTimer = null;
function startIdleTimer() {
  if (idleTimer) return;
  ['click','keydown','touchstart','mousemove'].forEach(e =>
    window.addEventListener(e, () => { lastActivity = Date.now(); }, { passive: true }));
  idleTimer = setInterval(() => {
    if (Date.now() - lastActivity > IDLE_TIMEOUT_MS) {
      toast('Session expired due to inactivity', 'info');
      signOut();
    }
  }, 60_000);
}
export async function requireRole(allowed) {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) { location.href = `${BASE}login.html`; return null; }
  const { data: profile } = await supabase.from('profiles').select('*').eq('id', session.user.id).single();
  if (!profile) { location.href = `${BASE}login.html`; return null; }
  if (profile.is_active === false) {
    try { await supabase.auth.signOut(); } catch {}
    location.href = `${BASE}login.html?err=suspended`;
    return null;
  }
  if (allowed && !allowed.includes(profile.role)) {
    location.href = `${BASE}${profile.role}.html`;
    return null;
  }
  syncServerTime();
  maybeHeartbeat();
  startIdleTimer();
  return { session, profile };
}
export async function signOut() {
  try { await supabase.auth.signOut(); } catch {}
  location.href = `${BASE}login.html`;
}

/* THEME */
const THEME_KEY = 'theme';
export function getCurrentTheme() { return document.documentElement.getAttribute('data-theme') || 'light'; }
export function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  updateThemeIcons();
}
export function setTheme(theme, persist = true) {
  applyTheme(theme);
  if (persist) { try { localStorage.setItem(THEME_KEY, theme); } catch {} }
}
export function toggleTheme() {
  setTheme(getCurrentTheme() === 'dark' ? 'light' : 'dark', true);
}
function updateThemeIcons() {
  const isDark = getCurrentTheme() === 'dark';
  document.querySelectorAll('[data-theme-toggle]').forEach(btn => {
    btn.innerHTML = isDark ? '<i class="fas fa-sun"></i>' : '<i class="fas fa-moon"></i>';
    const label = isDark ? 'Switch to light mode' : 'Switch to dark mode';
    btn.setAttribute('title', label);
    btn.setAttribute('aria-label', label);
  });
  const menuTheme = document.querySelector('[data-theme-menu-item]');
  if (menuTheme) {
    menuTheme.innerHTML = isDark ? '<i class="fas fa-sun"></i> Light mode' : '<i class="fas fa-moon"></i> Dark mode';
  }
}
export function initTheme() {
  const stored = localStorage.getItem(THEME_KEY);
  const systemDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  applyTheme(stored || (systemDark ? 'dark' : 'light'));
  const mq = window.matchMedia('(prefers-color-scheme: dark)');
  const onChange = (e) => { if (!localStorage.getItem(THEME_KEY)) applyTheme(e.matches ? 'dark' : 'light'); };
  if (mq.addEventListener) mq.addEventListener('change', onChange);
  else if (mq.addListener) mq.addListener(onChange);
}

/* PWA */
let deferredInstallPrompt = null;
export function bootPWA() {
  if (!document.querySelector('link[rel="manifest"]')) {
    const link = document.createElement('link');
    link.rel = 'manifest';
    link.href = '/manifest.json';
    document.head.appendChild(link);
  }
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
  window.addEventListener('beforeinstallprompt', e => {
    e.preventDefault();
    deferredInstallPrompt = e;
    document.querySelectorAll('[data-install-btn]').forEach(btn => { btn.style.display = 'inline-flex'; });
  });
}
export async function installPWA() {
  if (!deferredInstallPrompt) return;
  deferredInstallPrompt.prompt();
  const { outcome } = await deferredInstallPrompt.userChoice;
  deferredInstallPrompt = null;
  document.querySelectorAll('[data-install-btn]').forEach(btn => { btn.style.display = 'none'; });
  if (outcome === 'accepted') toast('Installed — check your home screen', 'success');
}

/* COMMAND PALETTE */
let commandRegistry = [];
let cmdOverlay = null, cmdInput = null, cmdList = null, cmdFocused = 0, cmdFiltered = [];

export function openCommandPalette() {
  if (!cmdOverlay) buildCmdPalette();
  cmdOverlay.classList.add('open');
  cmdInput.value = '';
  cmdFocused = 0;
  renderCmdResults('');
  setTimeout(() => cmdInput.focus(), 60);
}
export function closeCommandPalette() { if (cmdOverlay) cmdOverlay.classList.remove('open'); }

function buildCmdPalette() {
  cmdOverlay = document.createElement('div');
  cmdOverlay.className = 'cmd-overlay';
  cmdOverlay.innerHTML = `
    <div class="cmd-panel">
      <input class="cmd-input" type="text" placeholder="Search pages and actions…" autocomplete="off" spellcheck="false">
      <div class="cmd-list"></div>
    </div>`;
  document.body.appendChild(cmdOverlay);
  cmdInput = cmdOverlay.querySelector('.cmd-input');
  cmdList = cmdOverlay.querySelector('.cmd-list');
  cmdOverlay.onclick = (e) => { if (e.target === cmdOverlay) closeCommandPalette(); };
  cmdInput.oninput = (e) => { cmdFocused = 0; renderCmdResults(e.target.value); };
  cmdInput.onkeydown = (e) => {
    if (e.key === 'Escape') closeCommandPalette();
    else if (e.key === 'ArrowDown') { e.preventDefault(); cmdFocused = Math.min(cmdFocused + 1, cmdFiltered.length - 1); updateCmdFocus(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); cmdFocused = Math.max(cmdFocused - 1, 0); updateCmdFocus(); }
    else if (e.key === 'Enter') { e.preventDefault(); const c = cmdFiltered[cmdFocused]; if (c) { closeCommandPalette(); c.action(); } }
  };
}
function renderCmdResults(q) {
  const query = q.toLowerCase().trim();
  cmdFiltered = commandRegistry.filter(c =>
    !query || c.label.toLowerCase().includes(query) || (c.keywords || '').toLowerCase().includes(query));
  if (cmdFocused >= cmdFiltered.length) cmdFocused = 0;
  if (!cmdFiltered.length) { cmdList.innerHTML = `<div class="cmd-empty">No matches for "${escapeHtml(q)}"</div>`; return; }
  cmdList.innerHTML = cmdFiltered.map((c, i) => `
    <div class="cmd-item ${i === cmdFocused ? 'focused' : ''}" data-idx="${i}">
      <i class="fas ${c.icon || 'fa-circle'}"></i>
      <span>${escapeHtml(c.label)}</span>
      ${c.shortcut ? `<span class="cmd-shortcut">${escapeHtml(c.shortcut)}</span>` : ''}
    </div>
  `).join('');
  cmdList.querySelectorAll('.cmd-item').forEach(el => {
    el.onclick = () => { const c = cmdFiltered[parseInt(el.dataset.idx, 10)]; if (c) { closeCommandPalette(); c.action(); } };
  });
  updateCmdFocus();
}
function updateCmdFocus() {
  cmdList.querySelectorAll('.cmd-item').forEach((el, i) => el.classList.toggle('focused', i === cmdFocused));
  const f = cmdList.querySelector('.cmd-item.focused');
  if (f) f.scrollIntoView({ block: 'nearest' });
}

/* MODALS */
export function openModal({ title, sub, body, actions, wide = false }) {
  return new Promise((resolve) => {
    const dialog = document.createElement('dialog');
    dialog.className = 'modal-dialog';
    dialog.innerHTML = `
      <div class="modal-content ${wide ? 'modal-wide' : ''}">
        <div class="modal-header">
          <div>
            <div class="modal-title">${escapeHtml(title)}</div>
            ${sub ? `<div class="modal-sub">${escapeHtml(sub)}</div>` : ''}
          </div>
          <button class="modal-close" data-action="close" aria-label="Close"><i class="fas fa-xmark"></i></button>
        </div>
        <div class="modal-body">${body}</div>
        ${actions ? `<div class="modal-footer">${actions}</div>` : ''}
      </div>`;
    document.body.appendChild(dialog);
    dialog.showModal();
    const finish = (v) => { dialog.close(); dialog.remove(); resolve(v); };
    dialog.querySelector('[data-action="close"]').onclick = () => finish(null);
    dialog.querySelectorAll('[data-modal-action]').forEach(btn => {
      btn.onclick = () => { const a = btn.dataset.modalAction; finish(a === 'cancel' ? null : a); };
    });
    dialog.onclick = (e) => { if (e.target === dialog) finish(null); };
    dialog.addEventListener('close', () => { if (dialog.isConnected) { dialog.remove(); resolve(null); } });
  });
}
export async function confirmDialog({ title = 'Are you sure?', message = '', confirmText = 'Confirm', danger = false }) {
  const result = await openModal({
    title,
    body: `<p style="color:var(--text-secondary);line-height:1.6;margin:0">${escapeHtml(message)}</p>`,
    actions: `
      <button class="btn" data-modal-action="cancel">Cancel</button>
      <button class="btn ${danger ? 'btn-danger' : 'btn-primary'}" data-modal-action="confirm">${escapeHtml(confirmText)}</button>`,
  });
  return result === 'confirm';
}
export function openFormModal({ title, fields, saveText = 'Save', wide = false }) {
  return new Promise((resolve) => {
    const dialog = document.createElement('dialog');
    dialog.className = 'modal-dialog';
    dialog.innerHTML = `
      <div class="modal-content ${wide ? 'modal-wide' : ''}">
        <div class="modal-header">
          <div class="modal-title">${escapeHtml(title)}</div>
          <button class="modal-close" data-action="close"><i class="fas fa-xmark"></i></button>
        </div>
        <div class="modal-body">${fields}</div>
        <div class="modal-footer">
          <button class="btn" data-action="cancel">Cancel</button>
          <button class="btn btn-primary" data-action="save">${escapeHtml(saveText)}</button>
        </div>
      </div>`;
    document.body.appendChild(dialog);
    dialog.showModal();
    const finish = (v) => { dialog.close(); dialog.remove(); resolve(v); };
    dialog.querySelector('[data-action="close"]').onclick = () => finish(null);
    dialog.querySelector('[data-action="cancel"]').onclick = () => finish(null);
    dialog.querySelector('[data-action="save"]').onclick = () => {
      const data = {};
      dialog.querySelectorAll('[data-field]').forEach(el => {
        data[el.dataset.field] = el.type === 'checkbox' ? el.checked : el.value;
      });
      finish(data);
    };
    dialog.onclick = (e) => { if (e.target === dialog) finish(null); };
    dialog.addEventListener('close', () => { if (dialog.isConnected) { dialog.remove(); resolve(null); } });
  });
}

/* NOTIFICATIONS */
export async function getNotifications(profile) {
  if (profile.role === 'admin') {
    const { data } = await supabase
      .from('bookings')
      .select('id,book_date,slot_id,room_id,created_at,type')
      .eq('status', 'pending')
      .order('created_at', { ascending: false })
      .limit(10);
    return (data ?? []).map(b => ({
      icon: 'fa-hourglass-half', iconType: 'warning',
      title: `Pending: ${b.room_id} · ${b.type}`,
      meta: `${b.book_date} · ${b.slot_id}`,
      time: b.created_at,
      href: 'admin-bookings.html',
    }));
  }
  if (profile.role === 'faculty') {
    const { data } = await supabase
      .from('bookings')
      .select('id,book_date,slot_id,room_id,status,created_at')
      .eq('faculty_id', profile.id)
      .in('status', ['approved', 'rejected'])
      .order('created_at', { ascending: false })
      .limit(10);
    return (data ?? []).map(b => ({
      icon: b.status === 'approved' ? 'fa-circle-check' : 'fa-circle-xmark',
      iconType: b.status === 'approved' ? 'success' : 'danger',
      title: `Booking ${b.status}: ${b.room_id}`,
      meta: `${b.book_date} · ${b.slot_id}`,
      time: b.created_at,
      href: 'faculty.html',
    }));
  }
  return [];
}
async function updateNotifDot(profile) {
  const items = await getNotifications(profile);
  const dot = document.getElementById('notifDot');
  if (dot) dot.style.display = items.length > 0 ? 'block' : 'none';
}
async function openNotifPanel(profile) {
  const items = await getNotifications(profile);
  const panel = document.getElementById('notifPanel');
  if (!panel) return;
  const body = items.length
    ? items.map(n => `
      <a href="${n.href}" class="notif-item">
        <div class="notif-icon notif-icon-${n.iconType}"><i class="fas ${n.icon}"></i></div>
        <div class="notif-body">
          <div class="notif-title">${escapeHtml(n.title)}</div>
          <div class="notif-meta">${escapeHtml(n.meta)} · ${formatRelativeTime(n.time)}</div>
        </div>
      </a>`).join('')
    : '<div class="notif-empty"><i class="fas fa-bell-slash"></i>You\'re all caught up</div>';
  panel.querySelector('.notif-list').innerHTML = body;
  panel.classList.add('open');
}

/* NAV */
function getNavItems(profile) {
  if (profile.role === 'admin') return [
    { href: 'admin.html',          label: 'Dashboard',  icon: 'fa-gauge-high' },
    { href: 'admin-add.html',      label: 'Quick add',  icon: 'fa-bolt' },
    { href: 'admin-rooms.html',    label: 'Rooms',      icon: 'fa-door-open' },
    { href: 'admin-bookings.html', label: 'Bookings',   icon: 'fa-calendar-check' },
    { href: 'admin-users.html',    label: 'Users',      icon: 'fa-users' },
    { href: 'admin-settings.html', label: 'Settings',   icon: 'fa-gear' },
    { href: 'student.html',        label: 'Free rooms', icon: 'fa-building' },
  ];
  if (profile.role === 'faculty') return [
    { href: 'faculty.html',        label: 'Dashboard',  icon: 'fa-gauge-high' },
    { href: 'faculty-makeup.html', label: 'Makeup',     icon: 'fa-chalkboard-user' },
    { href: 'student.html',        label: 'Free rooms', icon: 'fa-building' },
    { href: 'profile.html',        label: 'Profile',    icon: 'fa-user' },
  ];
  return [
    { href: 'student.html', label: 'Free rooms', icon: 'fa-building' },
    { href: 'profile.html', label: 'Profile',    icon: 'fa-user' },
  ];
}
function getGlobalCommands(profile, items) {
  const cmds = items.map(l => ({
    label: l.label, icon: l.icon, keywords: l.label + ' page',
    action: () => { location.href = l.href; },
  }));
  cmds.push(
    { label: 'My profile', icon: 'fa-user', keywords: 'account settings', action: () => { location.href = 'profile.html'; } },
    { label: 'Toggle theme', icon: 'fa-circle-half-stroke', keywords: 'dark light mode', action: () => toggleTheme() },
    { label: 'Sign out', icon: 'fa-right-from-bracket', keywords: 'logout exit', action: () => signOut() },
  );
  return cmds;
}

export function renderNav(profile, extraCommands = []) {
  const el = document.getElementById('nav');
  if (!el || !profile) return;

  initTheme();
  const items = getNavItems(profile);
  commandRegistry = [...getGlobalCommands(profile, items), ...extraCommands];
  setupShortcuts();

  const current = location.pathname.split('/').pop() || 'index.html';
  const initial = ((profile.full_name || profile.email || '?').trim()[0] || '?').toUpperCase();
  const roleIcon = profile.role === 'admin' ? 'shield-halved' : profile.role === 'faculty' ? 'chalkboard-user' : 'graduation-cap';

  const bottomItems = items.slice(0, 4);
  const moreItems = items.slice(4);

  el.innerHTML = `
    <div class="nav">
      <div class="nav-inner">
        <a href="index.html" class="nav-brand">LPU<span class="nav-brand-dot">.</span>Scheduler</a>
        <div class="nav-links">
          ${items.map(l => `
            <a href="${l.href}" class="nav-link ${current === l.href ? 'active' : ''}">
              <i class="fas ${l.icon}"></i>${l.label}
            </a>`).join('')}
        </div>
        <div class="nav-actions">
          <button class="btn btn-sm" data-install-btn style="display:none" onclick="window.__installPWA && window.__installPWA()">
            <i class="fas fa-download"></i> Install
          </button>
          <button class="nav-icon-btn" id="cmdBtn" title="Search (⌘K)" aria-label="Open command palette"><i class="fas fa-search"></i></button>
          <button class="nav-icon-btn nav-bell-btn" id="notifBtn" title="Notifications" aria-label="Notifications">
            <i class="fas fa-bell"></i>
            <span class="notif-badge-dot" id="notifDot" style="display:none"></span>
          </button>
          <button class="nav-icon-btn" data-theme-toggle aria-label="Toggle theme"></button>
          <button class="nav-avatar-btn" id="avatarBtn" aria-label="Account menu">
            <span class="avatar-sm">${escapeHtml(initial)}</span>
          </button>
        </div>
      </div>

      <div class="avatar-menu" id="avatarMenu">
        <div class="avatar-menu-header">
          <div class="avatar-menu-name">${escapeHtml(profile.full_name || profile.email)}</div>
          <div class="avatar-menu-email">${escapeHtml(profile.email)}</div>
          <div class="avatar-menu-role">
            <span class="badge badge-${profile.role}"><i class="fas fa-${roleIcon}"></i>${profile.role}</span>
          </div>
        </div>
        <div class="avatar-menu-divider"></div>
        <a href="profile.html" class="avatar-menu-item"><i class="fas fa-user"></i> Profile</a>
        <button class="avatar-menu-item" data-theme-menu-item onclick="window.__toggleTheme && window.__toggleTheme()"></button>
        <div class="avatar-menu-divider"></div>
        <button class="avatar-menu-item avatar-menu-danger" id="logoutBtn"><i class="fas fa-right-from-bracket"></i> Sign out</button>
      </div>

      <div class="notif-panel" id="notifPanel">
        <div class="notif-panel-header">
          <div class="notif-panel-title">Notifications</div>
          <button class="btn btn-sm btn-ghost" id="notifClose"><i class="fas fa-xmark"></i></button>
        </div>
        <div class="notif-list"><div class="notif-empty"><i class="fas fa-spinner fa-spin"></i>Loading…</div></div>
      </div>
    </div>

    <nav class="mobile-bottom-nav">
      <div class="mobile-bottom-nav-items">
        ${bottomItems.map(l => `
          <a href="${l.href}" class="mobile-nav-item ${current === l.href ? 'active' : ''}">
            <i class="fas ${l.icon}"></i><span>${l.label}</span>
          </a>`).join('')}
        ${moreItems.length ? `
          <button class="mobile-nav-item" id="moreSheetBtn">
            <i class="fas fa-ellipsis"></i><span>More</span>
          </button>` : ''}
      </div>
    </nav>

    <div class="more-sheet-backdrop" id="moreSheetBackdrop"></div>
    <div class="more-sheet" id="moreSheet">
      <div class="more-sheet-handle"></div>
      ${moreItems.map(l => `<a href="${l.href}" class="more-sheet-item"><i class="fas ${l.icon}"></i>${l.label}</a>`).join('')}
      <a href="profile.html" class="more-sheet-item"><i class="fas fa-user"></i>Profile</a>
      <button class="more-sheet-item" id="moreLogoutBtn" style="color:var(--danger)">
        <i class="fas fa-right-from-bracket" style="color:var(--danger)"></i>Sign out
      </button>
    </div>`;

  document.querySelectorAll('[data-theme-toggle]').forEach(btn => { btn.onclick = toggleTheme; });
  updateThemeIcons();
  window.__toggleTheme = toggleTheme;
  window.__installPWA = installPWA;

  const avatarBtn = document.getElementById('avatarBtn');
  const avatarMenu = document.getElementById('avatarMenu');
  if (avatarBtn && avatarMenu) {
    avatarBtn.onclick = (e) => { e.stopPropagation(); avatarMenu.classList.toggle('open'); };
    document.addEventListener('click', (e) => {
      if (!avatarMenu.contains(e.target) && !avatarBtn.contains(e.target)) avatarMenu.classList.remove('open');
    });
  }

  document.getElementById('logoutBtn')?.addEventListener('click', signOut);
  document.getElementById('moreLogoutBtn')?.addEventListener('click', signOut);
  document.getElementById('cmdBtn')?.addEventListener('click', openCommandPalette);

  const notifBtn = document.getElementById('notifBtn');
  const notifPanel = document.getElementById('notifPanel');
  const notifClose = document.getElementById('notifClose');
  if (notifBtn && notifPanel) {
    notifBtn.onclick = async (e) => {
      e.stopPropagation();
      if (notifPanel.classList.contains('open')) notifPanel.classList.remove('open');
      else { await openNotifPanel(profile); document.getElementById('avatarMenu')?.classList.remove('open'); }
    };
    notifClose.onclick = () => notifPanel.classList.remove('open');
    document.addEventListener('click', (e) => {
      if (!notifPanel.contains(e.target) && !notifBtn.contains(e.target)) notifPanel.classList.remove('open');
    });
    updateNotifDot(profile);
  }

  const moreBtn = document.getElementById('moreSheetBtn');
  const moreSheet = document.getElementById('moreSheet');
  const moreBackdrop = document.getElementById('moreSheetBackdrop');
  if (moreBtn && moreSheet) {
    moreBtn.onclick = () => { moreBackdrop.classList.add('open'); moreSheet.classList.add('open'); };
    moreBackdrop.onclick = () => { moreBackdrop.classList.remove('open'); moreSheet.classList.remove('open'); };
  }

  bootPWA();
}
function setupShortcuts() {
  if (window.__shortcutsSet) return;
  window.__shortcutsSet = true;
  document.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
      e.preventDefault();
      openCommandPalette();
    }
  });
}

/* OFFLINE */
export function isOnline() { return navigator.onLine; }
export function onNetworkChange(cb) {
  window.addEventListener('online', () => cb(true));
  window.addEventListener('offline', () => cb(false));
}
export function getPendingRooms() { try { return JSON.parse(localStorage.getItem('pendingRooms') || '[]'); } catch { return []; } }
export function queueRoom(room) {
  const pending = getPendingRooms();
  const idx = pending.findIndex(r => r.room_id === room.room_id);
  if (idx >= 0) pending[idx] = room; else pending.push(room);
  localStorage.setItem('pendingRooms', JSON.stringify(pending));
}
export function removePendingRoom(room_id) {
  localStorage.setItem('pendingRooms', JSON.stringify(getPendingRooms().filter(r => r.room_id !== room_id)));
}
export async function syncPendingRooms() {
  const pending = getPendingRooms();
  if (!pending.length) return { synced: 0 };
  const payload = pending.map(({ _pending, _createdAt, ...clean }) => clean);
  const { error } = await supabase.from('rooms').upsert(payload, { onConflict: 'room_id' });
  if (error) throw error;
  localStorage.setItem('pendingRooms', '[]');
  return { synced: payload.length };
}
export function getPendingBookings() { try { return JSON.parse(localStorage.getItem('pendingBookings') || '[]'); } catch { return []; } }
export function queueBooking(booking) {
  const pending = getPendingBookings();
  pending.push(booking);
  localStorage.setItem('pendingBookings', JSON.stringify(pending));
}
export async function syncPendingBookings() {
  const pending = getPendingBookings();
  if (!pending.length) return { synced: 0, failed: 0 };
  let synced = 0, failed = 0;
  const remaining = [];
  for (const b of pending) {
    const { _pending, _createdAt, ...clean } = b;
    const { error } = await supabase.from('bookings').insert(clean);
    if (error) { if (error.code === '23505') failed++; else { remaining.push(b); failed++; } }
    else synced++;
  }
  localStorage.setItem('pendingBookings', JSON.stringify(remaining));
  return { synced, failed };
}

/* HELPERS */
export function deriveRoomId(building, floor, roomNumber, suffix) {
  const floorDigit = String(floor);
  const rn = String(roomNumber).trim().padStart(2, '0');
  const sfx = String(suffix || '').trim().toUpperCase();
  return {
    room_id: `${building}-${floorDigit}${rn}${sfx}`,
    display_name: `${building}-${floorDigit}${rn}${sfx ? ' ' + sfx : ''}`,
    floor_digit: floorDigit, room_number: rn, suffix: sfx,
  };
}
export function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
}
export function toast(msg, kind = 'info') {
  let el = document.querySelector('.toast');
  if (!el) { el = document.createElement('div'); el.className = 'toast'; document.body.appendChild(el); }
  el.className = `toast toast-${kind} show`;
  el.textContent = msg;
  clearTimeout(el._t);
  el._t = setTimeout(() => el.classList.remove('show'), 3500);
}
export function formatTime(d) {
  return `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}:${String(d.getSeconds()).padStart(2,'0')}`;
}
export function parseTimeOnDate(dateStr, timeStr) {
  return new Date(`${dateStr}T${String(timeStr).slice(0,8)}`);
}
export function formatDateTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' · ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}
export function formatRelativeTime(iso) {
  if (!iso) return '';
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ago`;
  const days = Math.floor(hrs / 24);
  if (days < 7) return `${days}d ago`;
  return new Date(iso).toLocaleDateString([], { month: 'short', day: 'numeric' });
}
export function debounce(fn, ms = 250) {
  let t;
  return (...args) => { clearTimeout(t); t = setTimeout(() => fn(...args), ms); };
}
export async function copyToClipboard(text) {
  try { await navigator.clipboard.writeText(text); toast('Copied', 'success'); return true; }
  catch { toast('Copy failed', 'error'); return false; }
}