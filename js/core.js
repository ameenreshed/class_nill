import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
export const BASE = new URL('.', location.href).href;

/* ============================================================
   SERVER TIME (NTP-equivalent)
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
   AUTH + IDLE TIMEOUT
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

  if (allowed && !allowed.includes(profile.role)) {
    location.href = `${BASE}${profile.role}.html`;
    return null;
  }

  syncServerTime();
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
export function toggleTheme() {
  const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
  if (isDark) {
    document.documentElement.removeAttribute('data-theme');
    try { localStorage.setItem('theme', 'light'); } catch {}
  } else {
    document.documentElement.setAttribute('data-theme', 'dark');
    try { localStorage.setItem('theme', 'dark'); } catch {}
  }
  updateThemeIcon();
}

function updateThemeIcon() {
  const btn = document.getElementById('themeBtn');
  if (!btn) return;
  const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
  btn.innerHTML = isDark ? '<i class="fas fa-sun"></i>' : '<i class="fas fa-moon"></i>';
  btn.title = isDark ? 'Switch to light mode' : 'Switch to dark mode';
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
    const btn = document.getElementById('installBtn');
    if (btn) btn.style.display = 'inline-flex';
  });
}

export async function installPWA() {
  if (!deferredInstallPrompt) return;
  deferredInstallPrompt.prompt();
  const { outcome } = await deferredInstallPrompt.userChoice;
  deferredInstallPrompt = null;
  const btn = document.getElementById('installBtn');
  if (btn) btn.style.display = 'none';
  if (outcome === 'accepted') toast('Installed — check your home screen', 'success');
}

/* ============================================================
   NAV
   ============================================================ */
export function renderNav(profile) {
  const el = document.getElementById('nav');
  if (!el || !profile) return;

  const links = [];
  if (profile.role === 'admin') {
    links.push(
      { href: 'admin.html',          label: 'Dashboard',  icon: 'fa-gauge-high' },
      { href: 'admin-add.html',      label: 'Quick add',  icon: 'fa-bolt' },
      { href: 'admin-rooms.html',    label: 'Rooms',      icon: 'fa-door-open' },
      { href: 'admin-bookings.html', label: 'Bookings',   icon: 'fa-calendar-check' },
      { href: 'admin-users.html',    label: 'Users',      icon: 'fa-users' },
      { href: 'admin-settings.html', label: 'Settings',   icon: 'fa-gear' },
      { href: 'student.html',        label: 'Free rooms', icon: 'fa-building' }
    );
  } else if (profile.role === 'faculty') {
    links.push(
      { href: 'faculty.html',        label: 'Dashboard',    icon: 'fa-gauge-high' },
      { href: 'faculty-makeup.html', label: 'Makeup class', icon: 'fa-chalkboard-user' },
      { href: 'student.html',        label: 'Free rooms',   icon: 'fa-building' }
    );
  } else {
    links.push({ href: 'student.html', label: 'Free rooms', icon: 'fa-building' });
  }

  const current = location.pathname.split('/').pop() || 'index.html';
  el.innerHTML = `
    <nav class="nav">
      <a class="nav-brand" href="index.html">amnrd<span>.</span>scheduler</a>
      <div class="nav-links">
        ${links.map(l => `
          <a href="${l.href}" class="nav-link ${current === l.href ? 'active' : ''}">
            <i class="fas ${l.icon}"></i>${l.label}
          </a>`).join('')}
      </div>
      <div class="nav-right">
        <button class="btn btn-sm" id="installBtn" style="display:none">
          <i class="fas fa-download"></i> Install
        </button>
        <span class="nav-email">${escapeHtml(profile.email)}</span>
        <span class="badge badge-${profile.role}">
          <i class="fas fa-${profile.role === 'admin' ? 'shield-halved' : profile.role === 'faculty' ? 'chalkboard-user' : 'graduation-cap'}"></i>${profile.role}
        </span>
        <button class="nav-icon-btn" id="themeBtn" aria-label="Toggle theme"></button>
        <button class="nav-logout" id="logoutBtn">
          <i class="fas fa-right-from-bracket"></i><span>Sign out</span>
        </button>
      </div>
    </nav>
  `;
  document.getElementById('logoutBtn').onclick = signOut;
  const themeBtn = document.getElementById('themeBtn');
  if (themeBtn) { updateThemeIcon(); themeBtn.onclick = toggleTheme; }
  const installBtn = document.getElementById('installBtn');
  if (installBtn && deferredInstallPrompt) {
    installBtn.style.display = 'inline-flex';
    installBtn.onclick = installPWA;
  }
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
  const rn  = String(roomNumber).trim().padStart(2, '0');
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