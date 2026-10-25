import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';
export { SUPABASE_URL, SUPABASE_ANON_KEY };

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
export const BASE = new URL('.', location.href).href;

if (typeof navigator !== 'undefined' && 'serviceWorker' in navigator) {
  navigator.serviceWorker.getRegistrations().then(r => r.forEach(x => x.unregister())).catch(() => {});
}

export async function waitForSession(maxMs = 2500) {
  const start = Date.now();
  while (Date.now() - start < maxMs) {
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (session) return session;
    } catch {}
    await new Promise(r => setTimeout(r, 150));
  }
  return null;
}

let serverOffsetMs = 0;
export async function syncServerTime() {
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/time_slots?select=slot_id&limit=1`, {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` }, cache: 'no-store',
    });
    const d = res.headers.get('date');
    if (d) serverOffsetMs = new Date(d).getTime() - Date.now();
  } catch {}
}
export function nowDate() { return new Date(Date.now() + serverOffsetMs); }
export function todayISO(d = nowDate()) {
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}
export function formatTime(d) {
  return `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}:${String(d.getSeconds()).padStart(2,'0')}`;
}
export function parseTimeOnDate(dateStr, timeStr) { return new Date(`${dateStr}T${String(timeStr).slice(0,8)}`); }
export function dayOfWeekNum(dateStr) { return new Date(`${dateStr}T12:00:00`).getDay(); }
export function dayName(dateStr) { return ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][dayOfWeekNum(dateStr)]; }
export function isSunday(dateStr) { return dayOfWeekNum(dateStr) === 0; }
export function addDays(dateStr, n) {
  const d = new Date(`${dateStr}T12:00:00`); d.setDate(d.getDate() + n); return todayISO(d);
}
export function humanDate(dateStr) {
  return new Date(`${dateStr}T12:00:00`).toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
}
export function slotStateOnDate(slot, dateStr) {
  const today = todayISO();
  if (dateStr < today) return 'past-day';
  if (dateStr > today) return 'upcoming';
  const nowStr = formatTime(nowDate());
  if (nowStr >= slot.end_time) return 'ended';
  if (nowStr >= slot.start_time) return 'current';
  return 'upcoming';
}
export function minutesUntilStart(slot, dateStr) {
  if (dateStr < todayISO()) return 0;
  return Math.max(0, Math.ceil((parseTimeOnDate(dateStr, slot.start_time) - nowDate()) / 60000));
}
export function minutesUntilEnd(slot, dateStr) {
  if (dateStr !== todayISO()) return 0;
  return Math.max(0, Math.ceil((parseTimeOnDate(dateStr, slot.end_time) - nowDate()) / 60000));
}
export function currentSlot(slots, dateStr = todayISO()) {
  if (dateStr !== todayISO()) return null;
  const nowStr = formatTime(nowDate());
  return slots.find(s => nowStr >= s.start_time && nowStr < s.end_time) || null;
}
export function nextSlot(slots, dateStr = todayISO()) {
  if (dateStr !== todayISO()) return null;
  const nowStr = formatTime(nowDate());
  return slots.find(s => s.start_time > nowStr) || null;
}
export function classifyCell({ roomId, slotId, dateStr, timetable, bookings, calendarEntry }) {
  if (calendarEntry && calendarEntry.kind === 'holiday') {
    return { state: 'holiday', label: 'Holiday', reason: calendarEntry.label || 'Holiday' };
  }
  if (isSunday(dateStr) && !(calendarEntry && calendarEntry.kind === 'working_saturday')) {
    return { state: 'closed', label: 'Closed', reason: 'Sunday' };
  }
  const dow = dayOfWeekNum(dateStr);
  const tt = timetable.find(t => t.room_id === roomId && t.slot_id === slotId && t.day_of_week === dow && t.is_active !== false);
  if (tt) return { state: 'class', label: 'Class', reason: `${tt.course_code || 'Class'}${tt.section_id ? ' · ' + tt.section_id : ''}`, detail: tt };
  const bk = bookings.find(b => b.room_id === roomId && b.slot_id === slotId && (b.status === 'pending' || b.status === 'approved'));
  if (bk) {
    const labelMap = { makeup: 'Makeup', exam: 'Exam', event: 'Event', maintenance: 'Maint', regular: 'Class' };
    return {
      state: bk.type === 'makeup' ? 'makeup' : bk.type === 'exam' ? 'exam' : bk.type === 'event' ? 'exam' : bk.type === 'maintenance' ? 'maint' : 'class',
      label: labelMap[bk.type] || 'Booked', reason: bk.reason || labelMap[bk.type] || 'Booked', detail: bk,
    };
  }
  return { state: 'free', label: 'Free', reason: 'No class, no booking' };
}
export async function loadBaseData() {
  const [{ data: rooms }, { data: slots }, { data: types }, { data: buildings }, { data: sections }] = await Promise.all([
    supabase.from('rooms').select('*').eq('bookable', true).order('building').order('floor'),
    supabase.from('time_slots').select('*').eq('is_active', true).order('sort_order').order('start_time'),
    supabase.from('room_types').select('*').eq('is_active', true),
    supabase.from('buildings').select('*').eq('is_active', true).order('sort_order'),
    supabase.from('sections').select('*').order('section_id'),
  ]);
  return { rooms: rooms ?? [], slots: slots ?? [], types: types ?? [], buildings: buildings ?? [], sections: sections ?? [] };
}
export async function loadDataForDate(dateStr) {
  const dow = dayOfWeekNum(dateStr);
  const [{ data: tt }, { data: bk }, { data: cal }] = await Promise.all([
    supabase.from('timetable').select('*').eq('day_of_week', dow).eq('is_active', true),
    supabase.from('bookings').select('*').eq('book_date', dateStr).in('status', ['pending', 'approved']),
    supabase.from('academic_calendar').select('*').eq('date', dateStr).maybeSingle(),
  ]);
  return { timetable: tt ?? [], bookings: bk ?? [], calendarEntry: cal ?? null };
}
export async function roomsFreeRightNow() {
  const base = await loadBaseData();
  const today = todayISO();
  const slot = currentSlot(base.slots, today);
  if (!slot) return { slot: null, free: [], total: base.rooms.length };
  const { timetable, bookings, calendarEntry } = await loadDataForDate(today);
  const free = base.rooms.filter(r => {
    const c = classifyCell({ roomId: r.room_id, slotId: slot.slot_id, dateStr: today, timetable, bookings, calendarEntry });
    return c.state === 'free';
  });
  return { slot, free, total: base.rooms.length };
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
  el._t = setTimeout(() => el.classList.remove('show'), 3000);
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
export function formatDateTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' · ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}
export function debounce(fn, ms = 200) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }
const THEME_KEY = 'theme';
export function getCurrentTheme() { return document.documentElement.getAttribute('data-theme') || 'light'; }
function updateThemeIcons() {
  const isDark = getCurrentTheme() === 'dark';
  document.querySelectorAll('[data-theme-toggle]').forEach(btn => {
    btn.innerHTML = isDark ? '<i class="fas fa-sun"></i>' : '<i class="fas fa-moon"></i>';
  });
}
export function applyTheme(theme) { document.documentElement.setAttribute('data-theme', theme); updateThemeIcons(); }
export function setTheme(theme, persist = true) { applyTheme(theme); if (persist) { try { localStorage.setItem(THEME_KEY, theme); } catch {} } }
export function toggleTheme() { setTheme(getCurrentTheme() === 'dark' ? 'light' : 'dark', true); }
export function initTheme() {
  const stored = localStorage.getItem(THEME_KEY);
  const systemDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  applyTheme(stored || (systemDark ? 'dark' : 'light'));
}
export async function requireRole(allowed) {
  const session = await waitForSession(2500);
  if (!session) { location.replace(`${BASE}login.html`); return null; }
  const { data: profile } = await supabase.from('profiles').select('*').eq('id', session.user.id).single();
  if (!profile) { location.replace(`${BASE}login.html`); return null; }
  if (profile.is_active === false) { try { await supabase.auth.signOut(); } catch {} location.replace(`${BASE}login.html?err=suspended`); return null; }
  if (allowed && !allowed.includes(profile.role)) { location.replace(`${BASE}${profile.role}.html`); return null; }
  syncServerTime();
  return { session, profile };
}
export async function signOut() { try { await supabase.auth.signOut(); } catch {} location.replace(`${BASE}login.html`); }

/* ============================================================
   NAV — updated with links for every role
   ============================================================ */
export function renderNav(profile) {
  const el = document.getElementById('nav');
  if (!el || !profile) return;
  initTheme();

  const initial = ((profile.full_name || profile.email || '?').trim()[0] || '?').toUpperCase();
  const roleIcon = profile.role === 'admin' ? 'shield-halved' : profile.role === 'faculty' ? 'chalkboard-user' : 'graduation-cap';
  const home = profile.role === 'admin' ? 'admin.html' : profile.role === 'faculty' ? 'faculty.html' : 'student.html';
  const currentPage = location.pathname.split('/').pop() || 'index.html';

  const items = profile.role === 'admin' ? [
    { href: 'admin.html', label: 'Dashboard', icon: 'fa-gauge-high' },
    { href: 'admin-bookings.html', label: 'Bookings', icon: 'fa-calendar-check' },
    { href: 'admin-timetable.html', label: 'Timetable', icon: 'fa-table' },
    { href: 'admin-rooms.html', label: 'Rooms', icon: 'fa-door-open' },
    { href: 'admin-users.html', label: 'Users', icon: 'fa-users' },
    { href: 'admin-settings.html', label: 'Settings', icon: 'fa-gear' },
    { href: 'student.html', label: 'Free rooms', icon: 'fa-building' },
    { href: 'admin-control.html', label: 'Control', icon: 'fa-sliders' },
  ] : profile.role === 'faculty' ? [
    { href: 'faculty.html', label: 'Dashboard', icon: 'fa-gauge-high' },
    { href: 'student.html', label: 'Free rooms', icon: 'fa-building' },
    { href: 'student-timetable.html', label: 'All timetable', icon: 'fa-table' },
    { href: 'profile.html', label: 'Profile', icon: 'fa-user' },
  ] : [
    { href: 'student.html', label: 'Free rooms', icon: 'fa-building' },
    { href: 'student-timetable.html', label: 'My timetable', icon: 'fa-table' },
    { href: 'profile.html', label: 'Profile', icon: 'fa-user' },
  ];

  el.innerHTML = `
    <div class="nav">
      <div class="nav-inner">
        <a href="${home}" class="nav-brand">LPU<span class="nav-brand-dot">.</span>Scheduler</a>
        <div class="nav-links">
          ${items.map(l => `<a href="${l.href}" class="nav-link ${currentPage === l.href ? 'active' : ''}"><i class="fas ${l.icon}"></i>${l.label}</a>`).join('')}
        </div>
        <div class="nav-actions">
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
        <button class="avatar-menu-item" id="themeMenuItem"></button>
        <div class="avatar-menu-divider"></div>
        <button class="avatar-menu-item avatar-menu-danger" id="logoutBtn"><i class="fas fa-right-from-bracket"></i> Sign out</button>
      </div>
    </div>`;

  document.querySelectorAll('[data-theme-toggle]').forEach(btn => { btn.onclick = toggleTheme; });
  const themeMenuItem = document.getElementById('themeMenuItem');
  if (themeMenuItem) {
    const paint = () => {
      const isDark = getCurrentTheme() === 'dark';
      themeMenuItem.innerHTML = isDark ? '<i class="fas fa-sun"></i> Light mode' : '<i class="fas fa-moon"></i> Dark mode';
    };
    paint();
    themeMenuItem.onclick = () => { toggleTheme(); paint(); };
  }
  updateThemeIcons();

  const avatarBtn = document.getElementById('avatarBtn');
  const avatarMenu = document.getElementById('avatarMenu');
  if (avatarBtn && avatarMenu) {
    avatarBtn.onclick = (e) => { e.stopPropagation(); avatarMenu.classList.toggle('open'); };
    document.addEventListener('click', (e) => {
      if (!avatarMenu.contains(e.target) && !avatarBtn.contains(e.target)) avatarMenu.classList.remove('open');
    });
  }
  document.getElementById('logoutBtn')?.addEventListener('click', signOut);
}