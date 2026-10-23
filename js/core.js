import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
export const BASE = new URL('.', location.href).href;

/* ============================================================
   AUTH
   ============================================================ */
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
  return { session, profile };
}

export async function signOut() {
  await supabase.auth.signOut();
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
  btn.innerHTML = isDark
    ? '<i class="fas fa-sun"></i>'
    : '<i class="fas fa-moon"></i>';
  btn.title = isDark ? 'Switch to light mode' : 'Switch to dark mode';
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
      { href: 'admin.html',          label: 'Dashboard',    icon: 'fa-gauge-high' },
      { href: 'admin-add.html',      label: 'Quick add',    icon: 'fa-bolt' },
      { href: 'admin-rooms.html',    label: 'Rooms',        icon: 'fa-door-open' },
      { href: 'admin-bookings.html', label: 'Bookings',     icon: 'fa-calendar-check' },
      { href: 'admin-users.html',    label: 'Users',        icon: 'fa-users' },
      { href: 'student.html',        label: 'Free rooms',   icon: 'fa-building' }
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
          </a>
        `).join('')}
      </div>
      <div class="nav-right">
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
  try { return JSON.parse(localStorage.getItem('pendingRooms') || '[]'); }
  catch { return []; }
}

export function queueRoom(room) {
  const pending = getPendingRooms();
  const idx = pending.findIndex(r => r.room_id === room.room_id);
  if (idx >= 0) pending[idx] = room; else pending.push(room);
  localStorage.setItem('pendingRooms', JSON.stringify(pending));
}

export function removePendingRoom(room_id) {
  const pending = getPendingRooms().filter(r => r.room_id !== room_id);
  localStorage.setItem('pendingRooms', JSON.stringify(pending));
}

export async function syncPendingRooms() {
  const pending = getPendingRooms();
  if (!pending.length) return { synced: 0 };

  const payload = pending.map(r => {
    const { _pending, _createdAt, ...clean } = r;
    return clean;
  });

  const { error } = await supabase.from('rooms').upsert(payload, { onConflict: 'room_id' });
  if (error) throw error;

  localStorage.setItem('pendingRooms', '[]');
  return { synced: payload.length };
}

export function getPendingBookings() {
  try { return JSON.parse(localStorage.getItem('pendingBookings') || '[]'); }
  catch { return []; }
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
      if (error.code === '23505') {
        failed++;
      } else {
        remaining.push(b); failed++;
      }
    } else {
      synced++;
    }
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

export function todayISO() {
  return new Date().toISOString().slice(0, 10);
}

export function toast(msg, kind = 'info') {
  let el = document.querySelector('.toast');
  if (!el) { el = document.createElement('div'); el.className = 'toast'; document.body.appendChild(el); }
  el.className = `toast toast-${kind} show`;
  el.textContent = msg;
  clearTimeout(el._t);
  el._t = setTimeout(() => el.classList.remove('show'), 3500);
}