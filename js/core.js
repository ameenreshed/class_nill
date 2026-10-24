import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
export const BASE = new URL('.', location.href).href;

/* ============================================================
   SERVER TIME
   ============================================================ */
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

/* ============================================================
   HEARTBEAT
   ============================================================ */
const HB_KEY = 'lastHeartbeat';
const HB_INTERVAL = 15 * 60 * 1000;

function maybeHeartbeat() {
  try {
    const last = parseInt(sessionStorage.getItem(HB_KEY) || '0', 10);
    if (Date.now() - last > HB_INTERVAL) {
      sessionStorage.setItem(HB_KEY, String(Date.now()));
      supabase.rpc('heartbeat').then(() => {}).catch(() => {});
    }
  } catch {}
}

/* ============================================================
   AUTH
   ============================================================ */
const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
let lastActivity = Date.now();
let idleTimer = null;

function startIdleTimer() {
  if (idleTimer) return;
  ['click', 'keydown', 'touchstart', 'mousemove'].forEach(evt =>
    window.addEventListener(evt, () => { lastActivity = Date.now(); }, { passive: true })
  );
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

  const { data: profile } = await supabase
    .from('profiles').select('*').eq('id', session.user.id).single();
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

/* ============================================================
   THEME
   ============================================================ */
const THEME_KEY = 'theme';

export function getCurrentTheme() {
  return document.documentElement.getAttribute('data-theme') || 'light';
}

export function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  updateThemeIcons();
}

export function setTheme(theme, persist = true) {
  applyTheme(theme);
  if (persist) {
    try { localStorage.setItem(THEME_KEY, theme); } catch {}
  }
}

export function toggleTheme() {
  const current = getCurrentTheme();
  const next = current === 'dark' ? 'light' : 'dark';
  setTheme(next, true);
}

function updateThemeIcons() {
  const isDark = getCurrentTheme() === 'dark';
  document.querySelectorAll('[data-theme-toggle]').forEach(btn => {
    btn.innerHTML = isDark
      ? '<i class="fas fa-sun"></i>'
      : '<i class="fas fa-moon"></i>';
    btn.setAttribute('title', isDark ? 'Switch to light mode' : 'Switch to dark mode');
    btn.setAttribute('aria-label', btn.getAttribute('title'));
  });
  // Update avatar menu theme item if present
  const menuTheme = document.querySelector('[data-theme-menu-item]');
  if (menuTheme) {
    menuTheme.innerHTML = isDark
      ? '<i class="fas fa-sun"></i> Light mode'
      : '<i class="fas fa-moon"></i> Dark mode';
  }
}

export function initTheme() {
  const stored = localStorage.getItem(THEME_KEY);
  const systemDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  const theme = stored || (systemDark ? 'dark' : 'light');
  applyTheme(theme);

  // Listen for system preference changes (only if user hasn't overridden)
  const mq = window.matchMedia('(prefers-color-scheme: dark)');
  const onChange = (e) => {
    if (!localStorage.getItem(THEME_KEY)) {
      applyTheme(e.matches ? 'dark' : 'light');
    }
  };
  if (mq.addEventListener) mq.addEventListener('change', onChange);
  else if (mq.addListener) mq.addListener(onChange);
}

/* ============================================================
   PWA
   ============================================================ */
let deferredInstallPrompt = null;

export function bootPWA() {
  if (!document.querySelector('link[rel="manifest"]')) {
    const link = document.createElement('link');
    link.rel = 'manifest';
    link.href = '/manifest.json';
    document.head.appendChild(link);
  }
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  }
  window.addEventListener('beforeinstallprompt', e => {
    e.preventDefault();
    deferredInstallPrompt = e;
    document.querySelectorAll('[data-install-btn]').forEach(btn => {
      btn.style.display = 'inline-flex';
    });
  });
}

export async function installPWA() {
  if (!deferredInstallPrompt) return;
  deferredInstallPrompt.prompt();
  const { outcome } = await deferredInstallPrompt.userChoice;
  deferredInstallPrompt = null;
  document.querySelectorAll('[data-install-btn]').forEach(btn => {
    btn.style.display = 'none';
  });
  if (outcome === 'accepted') toast('Installed — check your home screen', 'success');
}

/* ============================================================
   NAV DATA
   ============================================================ */
function getNavItems(profile) {
  if (profile.role === 'admin') {
    return [
      { href: 'admin.html',          label: 'Dashboard',  icon: 'fa-gauge-high' },
      { href: 'admin-add.html',      label: 'Quick add',  icon: 'fa-bolt' },
      { href: 'admin-rooms.html',    label: 'Rooms',      icon: 'fa-door-open' },
      { href: 'admin-bookings.html', label: 'Bookings',   icon: 'fa-calendar-check' },
      { href: 'admin-users.html',    label: 'Users',      icon: 'fa-users' },
      { href: 'admin-settings.html', label: 'Settings',   icon: 'fa-gear' },
      { href: 'student.html',        label: 'Free rooms', icon: 'fa-building' },
    ];
  }
  if (profile.role === 'faculty') {
    return [
      { href: 'faculty.html',        label: 'Dashboard',    icon: 'fa-gauge-high' },
      { href: 'faculty-makeup.html', label: 'Makeup',       icon: 'fa-chalkboard-user' },
      { href: 'student.html',        label: 'Free rooms',   icon: 'fa-building' },
      { href: 'profile.html',        label: 'Profile',      icon: 'fa-user' },
    ];
  }
  return [
    { href: 'student.html', label: 'Free rooms', icon: 'fa-building' },
    { href: 'profile.html', label: 'Profile',    icon: 'fa-user' },
  ];
}

/* ============================================================
   NAV RENDER
   ============================================================ */
export function renderNav(profile) {
  const el = document.getElementById('nav');
  if (!el || !profile) return;

  initTheme();

  const items = getNavItems(profile);
  const current = location.pathname.split('/').pop() || 'index.html';
  const initial = ((profile.full_name || profile.email || '?').trim()[0] || '?').toUpperCase();
  const roleIcon = profile.role === 'admin' ? 'shield-halved'
                 : profile.role === 'faculty' ? 'chalkboard-user'
                 : 'graduation-cap';

  // Mobile bottom nav: up to 4 items, then More if needed
  const bottomItems = items.slice(0, 4);
  const moreItems = items.slice(4);
  const hasMore = moreItems.length > 0;

  const navHTML = `
    <div class="nav">
      <div class="nav-inner">
        <a href="index.html" class="nav-brand">amnrd<span class="nav-brand-dot">.</span>scheduler</a>

        <div class="nav-links">
          ${items.map(l => `
            <a href="${l.href}" class="nav-link ${current === l.href ? 'active' : ''}">
              <i class="fas ${l.icon}"></i>${l.label}
            </a>
          `).join('')}
        </div>

        <div class="nav-actions">
          <button class="btn btn-sm" data-install-btn style="display:none" onclick="window.__installPWA && window.__installPWA()">
            <i class="fas fa-download"></i> Install
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
            <span class="badge badge-${profile.role}">
              <i class="fas fa-${roleIcon}"></i>${profile.role}
            </span>
          </div>
        </div>
        <div class="avatar-menu-divider"></div>
        <a href="profile.html" class="avatar-menu-item">
          <i class="fas fa-user"></i> Profile
        </a>
        <button class="avatar-menu-item" data-theme-menu-item onclick="window.__toggleTheme && window.__toggleTheme()"></button>
        ${profile.role === 'admin' ? `
          <a href="admin-users.html" class="avatar-menu-item">
            <i class="fas fa-users"></i> Manage users
          </a>
          <a href="admin-settings.html" class="avatar-menu-item">
            <i class="fas fa-gear"></i> Settings
          </a>
        ` : ''}
        <div class="avatar-menu-divider"></div>
        <button class="avatar-menu-item avatar-menu-danger" id="logoutBtn">
          <i class="fas fa-right-from-bracket"></i> Sign out
        </button>
      </div>
    </div>

    <nav class="mobile-bottom-nav">
      <div class="mobile-bottom-nav-items">
        ${bottomItems.map(l => `
          <a href="${l.href}" class="mobile-nav-item ${current === l.href ? 'active' : ''}">
            <i class="fas ${l.icon}"></i>
            <span>${l.label}</span>
          </a>
        `).join('')}
        ${hasMore ? `
          <button class="mobile-nav-item" id="moreSheetBtn">
            <i class="fas fa-ellipsis"></i>
            <span>More</span>
          </button>
        ` : ''}
      </div>
    </nav>

    <div class="more-sheet-backdrop" id="moreSheetBackdrop"></div>
    <div class="more-sheet" id="moreSheet">
      <div class="more-sheet-handle"></div>
      ${moreItems.map(l => `
        <a href="${l.href}" class="more-sheet-item">
          <i class="fas ${l.icon}"></i>${l.label}
        </a>
      `).join('')}
      <a href="profile.html" class="more-sheet-item">
        <i class="fas fa-user"></i>Profile
      </a>
      <button class="more-sheet-item" id="moreLogoutBtn" style="color:var(--danger)">
        <i class="fas fa-right-from-bracket" style="color:var(--danger)"></i>Sign out
      </button>
    </div>
  `;

  el.innerHTML = navHTML;

  // Wire theme toggle
  document.querySelectorAll('[data-theme-toggle]').forEach(btn => {
    btn.onclick = toggleTheme;
  });
  updateThemeIcons();

  // Wire avatar dropdown
  const avatarBtn = document.getElementById('avatarBtn');
  const avatarMenu = document.getElementById('avatarMenu');
  if (avatarBtn && avatarMenu) {
    avatarBtn.onclick = (e) => {
      e.stopPropagation();
      avatarMenu.classList.toggle('open');
    };
    document.addEventListener('click', (e) => {
      if (!avatarMenu.contains(e.target) && !avatarBtn.contains(e.target)) {
        avatarMenu.classList.remove('open');
      }
    });
  }

  // Wire logout
  document.getElementById('logoutBtn')?.addEventListener('click', signOut);
  document.getElementById('moreLogoutBtn')?.addEventListener('click', signOut);

  // Wire more sheet
  const moreBtn = document.getElementById('moreSheetBtn');
  const moreSheet = document.getElementById('moreSheet');
  const moreBackdrop = document.getElementById('moreSheetBackdrop');
  if (moreBtn && moreSheet) {
    moreBtn.onclick = () => {
      moreBackdrop.classList.add('open');
      moreSheet.classList.add('open');
    };
    moreBackdrop.onclick = () => {
      moreBackdrop.classList.remove('open');
      moreSheet.classList.remove('open');
    };
  }

  // Expose globally
  window.__toggleTheme = toggleTheme;
  window.__installPWA = installPWA;

  bootPWA();
}

/* ============================================================
   OFFLINE
   ============================================================ */
export function isOnline() { return navigator.onLine; }
export function onNetworkChange(cb) {
  window.addEventListener('online', () => cb(true));
  window.addEventListener('offline', () => cb(false));
}

export function getPendingRooms() {
  try { return JSON.parse(localStorage.getItem('pendingRooms') || '[]'); } catch { return []; }
}
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

export function getPendingBookings() {
  try { return JSON.parse(localStorage.getItem('pendingBookings') || '[]'); } catch { return []; }
}
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
    if (error) {
      if (error.code === '23505') failed++;
      else { remaining.push(b); failed++; }
    } else synced++;
  }
  localStorage.setItem('pendingBookings', JSON.stringify(remaining));
  return { synced, failed };
}

/* ============================================================
   HELPERS
   ============================================================ */
export function deriveRoomId(building, floor, roomNumber, suffix) {
  const floorDigit = String(floor);
  const rn = String(roomNumber).trim().padStart(2, '0');
  const sfx = String(suffix || '').trim().toUpperCase();
  const room_id = `${building}-${floorDigit}${rn}${sfx}`;
  const display_name = `${building}-${floorDigit}${rn}${sfx ? ' ' + sfx : ''}`;
  return { room_id, display_name, floor_digit: floorDigit, room_number: rn, suffix: sfx };
}

export function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c =>
    ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
}

export function toast(msg, kind = 'info') {
  let el = document.querySelector('.toast');
  if (!el) {
    el = document.createElement('div');
    el.className = 'toast';
    document.body.appendChild(el);
  }
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
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' })
    + ' · '
    + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}