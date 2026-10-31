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
    const res = await fetch(`${SUPABASE_URL}/rest/v1/`, {
      headers: { apikey: SUPABASE_ANON_KEY }, cache: 'no-store',
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
const normT = s => String(s ?? '').slice(0, 8);
export function parseTimeOnDate(dateStr, timeStr) { return new Date(`${dateStr}T${normT(timeStr)}`); }
export function dayOfWeekNum(dateStr) { return new Date(`${dateStr}T12:00:00`).getDay(); }
export function dayName(dateStr) { return ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][dayOfWeekNum(dateStr)]; }
export function isSunday(dateStr) { return dayOfWeekNum(dateStr) === 0; }
export function humanDate(dateStr) {
  return new Date(`${dateStr}T12:00:00`).toLocaleDateString([], { weekday:'short', month:'short', day:'numeric' });
}
export function slotStateOnDate(slot, dateStr) {
  const today = todayISO();
  if (dateStr < today) return 'past-day';
  if (dateStr > today) return 'upcoming';
  const nowStr = formatTime(nowDate());
  if (nowStr >= normT(slot.end_time)) return 'ended';
  if (nowStr >= normT(slot.start_time)) return 'current';
  return 'upcoming';
}
export function minutesUntilStart(slot, dateStr) {
  if (dateStr < todayISO()) return 0;
  return Math.max(0, Math.ceil((parseTimeOnDate(dateStr, slot.start_time) - nowDate())/60000));
}
export function minutesUntilEnd(slot, dateStr) {
  if (dateStr !== todayISO()) return 0;
  return Math.max(0, Math.ceil((parseTimeOnDate(dateStr, slot.end_time) - nowDate())/60000));
}
export function currentSlot(slots, dateStr = todayISO()) {
  if (dateStr !== todayISO()) return null;
  const nowStr = formatTime(nowDate());
  return slots.find(s => nowStr >= normT(s.start_time) && nowStr < normT(s.end_time)) || null;
}

export function classifyCell({
  roomId, slotId, dateStr, timetable, bookings, calendarEntry, weekendOpen,
  unavailability = [],
}) {
  if (calendarEntry && calendarEntry.kind === 'holiday') {
    return { state:'holiday', label:'Holiday', reason: calendarEntry.label || 'Holiday' };
  }
  const sundayClosed = isSunday(dateStr)
    && !(calendarEntry && calendarEntry.kind === 'working_saturday')
    && !weekendOpen;
  if (sundayClosed) return { state:'closed', label:'Closed', reason:'Sunday' };
  const dow = dayOfWeekNum(dateStr);
  const tt = timetable.find(t =>
    t.room_id === roomId && t.slot_id === slotId
    && t.day_of_week === dow && t.is_active !== false);
  if (tt) {
    const onLeave = unavailability.some(u =>
      u.faculty_id === tt.faculty_id && u.date === dateStr
      && (u.slot_id === null || u.slot_id === slotId));
    if (onLeave) return { state:'free', label:'Free', reason:'Faculty on leave', detail: tt };
    return { state:'class', label:'Class', reason: tt.course_code || 'Class', detail: tt };
  }
  const bk = bookings.find(b =>
    b.room_id === roomId && b.slot_id === slotId
    && (b.status === 'pending' || b.status === 'approved'));
  if (bk) {
    const labelMap = { makeup:'Makeup', exam:'Exam', event:'Event', maintenance:'Maint', regular:'Class' };
    const stateMap = { makeup:'makeup', exam:'exam', event:'exam', maintenance:'maint', regular:'class' };
    return { state: stateMap[bk.type] || 'class', label: labelMap[bk.type] || 'Booked',
             reason: bk.reason || labelMap[bk.type] || 'Booked', detail: bk };
  }
  return { state:'free', label:'Free', reason:'No class, no booking' };
}

export async function loadBaseData() {
  const [{ data: rooms }, { data: slots }, { data: types }, { data: buildings }] = await Promise.all([
    supabase.from('rooms').select('*').eq('bookable', true).order('building').order('floor'),
    supabase.from('time_slots').select('*').eq('is_active', true).order('sort_order').order('start_time'),
    supabase.from('room_types').select('*').eq('is_active', true),
    supabase.from('buildings').select('*').eq('is_active', true).order('sort_order'),
  ]);
  return { rooms: rooms ?? [], slots: slots ?? [], types: types ?? [], buildings: buildings ?? [] };
}

export async function loadDataForDate(dateStr) {
  const dow = dayOfWeekNum(dateStr);
  const [{ data: tt }, { data: bk }, { data: cal }, { data: un }] = await Promise.all([
    supabase.from('timetable').select('*').eq('day_of_week', dow).eq('is_active', true),
    supabase.from('bookings').select('*').eq('book_date', dateStr).in('status', ['pending','approved']),
    supabase.from('academic_calendar').select('*').eq('date', dateStr).maybeSingle(),
    supabase.from('faculty_unavailability').select('*').eq('date', dateStr),
  ]);
  return { timetable: tt ?? [], bookings: bk ?? [], calendarEntry: cal ?? null, unavailability: un ?? [] };
}

let _settingsCache = null;
let _settingsCacheAt = 0;
export async function getSettings(force = false) {
  const now = Date.now();
  if (!force && _settingsCache && now - _settingsCacheAt < 30_000) return _settingsCache;
  try {
    const { data } = await supabase.from('system_settings').select('*');
    const map = {};
    (data ?? []).forEach(s => { map[s.key] = s.value; });
    _settingsCache = map; _settingsCacheAt = now;
    return map;
  } catch {
    _settingsCache = {}; _settingsCacheAt = now; return {};
  }
}
export function invalidateSettings() { _settingsCache = null; }

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
  el._t = setTimeout(() => el.classList.remove('show'), 3000);
  if (navigator.vibrate) {
    try { navigator.vibrate(kind === 'error' ? [30, 30, 30] : 15); } catch {}
  }
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
  return new Date(iso).toLocaleDateString([], { month:'short', day:'numeric' });
}
export function formatDateTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleDateString([], { month:'short', day:'numeric' }) + ' · '
       + d.toLocaleTimeString([], { hour:'2-digit', minute:'2-digit' });
}

export function bookingTypeAllowed(settings, type) {
  const map = { makeup:'allow_faculty_makeup', exam:'allow_faculty_exam', event:'allow_faculty_event' };
  const key = map[type];
  return !key || settings[key] !== false;
}

const THEME_KEY = 'theme';
export function getCurrentTheme() {
  return document.documentElement.getAttribute('data-theme') || 'light';
}
function updateThemeIcons() {
  const isDark = getCurrentTheme() === 'dark';
  document.querySelectorAll('[data-theme-toggle]').forEach(btn => {
    btn.innerHTML = isDark ? '<i class="fas fa-sun"></i>' : '<i class="fas fa-moon"></i>';
  });
  // Update mobile sheet theme label if present
  const masThemeLabel = document.querySelector('#masThemeToggle .mas-item-label');
  const masThemeIcon = document.querySelector('#masThemeToggle .mas-item-icon i');
  if (masThemeLabel) {
    masThemeLabel.textContent = isDark ? 'Light mode' : 'Dark mode';
    if (masThemeIcon) {
      masThemeIcon.className = isDark ? 'fas fa-sun' : 'fas fa-moon';
    }
  }
  // Update desktop theme menu item
  const themeMenuItem = document.getElementById('themeMenuItem');
  if (themeMenuItem) {
    themeMenuItem.innerHTML = isDark
      ? '<i class="fas fa-sun"></i> Light mode'
      : '<i class="fas fa-moon"></i> Dark mode';
  }
}
export function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute('content', theme === 'dark' ? '#0B1220' : '#EA580C');
  updateThemeIcons();
}
export function setTheme(theme, persist = true) {
  applyTheme(theme);
  if (persist) { try { localStorage.setItem(THEME_KEY, theme); } catch {} }
}
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
  if (profile.is_active === false) {
    try { await supabase.auth.signOut(); } catch {}
    location.replace(`${BASE}login.html?err=suspended`);
    return null;
  }
  if (allowed && !allowed.includes(profile.role)) {
    location.replace(`${BASE}${profile.role}.html`);
    return null;
  }
  syncServerTime();
  return { session, profile };
}

export async function signOut() {
  try { await supabase.auth.signOut(); } catch {}
  location.replace(`${BASE}login.html`);
}

/* ============================================================
   NAVIGATION — desktop popover + mobile bottom sheet
   ============================================================ */
export async function renderNav(profile) {
  const el = document.getElementById('nav');
  if (!el || !profile) return;
  initTheme();

  const initial = ((profile.full_name || profile.email || '?').trim()[0] || '?').toUpperCase();
  const roleIcon = profile.role === 'admin' ? 'shield-halved' : 'chalkboard-user';
  const home = profile.role === 'admin' ? 'admin.html' : 'faculty.html';
  const currentPage = location.pathname.split('/').pop() || home;
  const isDark = getCurrentTheme() === 'dark';

  const topItems = profile.role === 'admin' ? [
    { href:'admin.html',           label:'Dashboard',  icon:'fa-gauge-high',     active: currentPage === 'admin.html' },
    { href:'admin-timetable.html', label:'Timetable',  icon:'fa-table',          active: currentPage === 'admin-timetable.html' },
    { href:'admin-bookings.html',  label:'Bookings',   icon:'fa-calendar-check', active: currentPage === 'admin-bookings.html' },
    { href:'admin-faculty.html',   label:'Users',      icon:'fa-users',          active: currentPage === 'admin-faculty.html' },
    { href:'admin-import.html',    label:'Import',     icon:'fa-file-import',    active: currentPage === 'admin-import.html' },
    { href:'free-rooms.html',      label:'Free rooms', icon:'fa-building',       active: currentPage === 'free-rooms.html' },
    { href:'admin-settings.html',  label:'Settings',   icon:'fa-gear',           active: currentPage === 'admin-settings.html' },
  ] : [
    { href:'faculty.html',   label:'Dashboard',  icon:'fa-gauge-high', active: currentPage === 'faculty.html' },
    { href:'free-rooms.html',label:'Free rooms', icon:'fa-building',   active: currentPage === 'free-rooms.html' },
    { href:'profile.html',   label:'Profile',    icon:'fa-user',       active: currentPage === 'profile.html' },
  ];

  const bottomItems = profile.role === 'admin' ? [
    { href:'admin.html',          label:'Home',      icon:'fa-house',          active: currentPage === 'admin.html' },
    { href:'admin-timetable.html',label:'Schedule',  icon:'fa-table',          active: currentPage === 'admin-timetable.html' },
    { href:'admin-bookings.html', label:'Bookings',  icon:'fa-calendar-check', active: currentPage === 'admin-bookings.html' },
    { href:'admin-faculty.html',  label:'Users',     icon:'fa-users',          active: currentPage === 'admin-faculty.html' },
    { more: true,                 label:'More',      icon:'fa-ellipsis' },
  ] : [
    { href:'faculty.html',   label:'Home',    icon:'fa-house',       active: currentPage === 'faculty.html' },
    { href:'free-rooms.html',label:'Rooms',   icon:'fa-building',    active: currentPage === 'free-rooms.html' },
    { href:'profile.html',   label:'Profile', icon:'fa-circle-user', active: currentPage === 'profile.html' },
  ];

  const moreItems = profile.role === 'admin' ? [
    { href:'admin-import.html',   label:'Import CSV',       icon:'fa-file-import' },
    { href:'free-rooms.html',     label:'Free rooms',       icon:'fa-building' },
    { href:'admin-rooms.html',    label:'Rooms & buildings',icon:'fa-door-open' },
    { href:'admin-slots.html',    label:'Time slots',       icon:'fa-clock' },
    { href:'admin-calendar.html', label:'Calendar',         icon:'fa-calendar-days' },
    { href:'profile.html',        label:'Profile',          icon:'fa-user' },
    { href:'admin-settings.html', label:'Settings',         icon:'fa-gear' },
  ] : [];

  el.innerHTML = `
    <div class="nav">
      <div class="nav-inner">
        <a href="${home}" class="nav-brand">LPU<span class="nav-brand-dot">.</span>Scheduler</a>
        <div class="nav-links">
          ${topItems.map(l => `<a href="${l.href}" class="nav-link ${l.active ? 'active' : ''}"><i class="fas ${l.icon}"></i>${l.label}</a>`).join('')}
        </div>
        <div class="nav-actions">
          <button class="nav-icon-btn" data-theme-toggle aria-label="Toggle theme"></button>
          <button class="nav-avatar-btn" id="avatarBtn" aria-label="Account menu">
            <span class="avatar-sm">${escapeHtml(initial)}</span>
          </button>
        </div>
      </div>

      <!-- ===== Desktop popover (hidden on mobile via CSS) ===== -->
      <div class="avatar-menu" id="avatarMenu" role="menu">
        <div class="avatar-menu-header">
          <div class="avatar-menu-avatar">${escapeHtml(initial)}</div>
          <div class="avatar-menu-header-info">
            <div class="avatar-menu-name">${escapeHtml(profile.full_name || profile.email)}</div>
            <div class="avatar-menu-email">${escapeHtml(profile.email)}</div>
            <div class="avatar-menu-role">
              <span class="badge badge-${profile.role}"><i class="fas fa-${roleIcon}"></i>${profile.role}</span>
            </div>
          </div>
        </div>
        <div class="avatar-menu-divider"></div>
        <a href="profile.html" class="avatar-menu-item" role="menuitem"><i class="fas fa-user"></i> Profile</a>
        <button class="avatar-menu-item install-app-item" id="installAppBtn" role="menuitem"><i class="fas fa-download"></i> Install app</button>
        <button class="avatar-menu-item" id="themeMenuItem" role="menuitem">${isDark ? '<i class="fas fa-sun"></i> Light mode' : '<i class="fas fa-moon"></i> Dark mode'}</button>
        <div class="avatar-menu-divider"></div>
        <button class="avatar-menu-item avatar-menu-danger" id="logoutBtn" role="menuitem"><i class="fas fa-right-from-bracket"></i> Sign out</button>
      </div>
    </div>

    <!-- ===== Mobile bottom nav ===== -->
    <div class="mobile-bottom-nav" id="mobileBottomNav">
      <div class="mobile-bottom-nav-items">
        ${bottomItems.map(l => l.more ? `
          <button class="mobile-nav-item mobile-nav-more" id="moreBtn" type="button">
            <i class="fas ${l.icon}"></i>
            <span>${l.label}</span>
          </button>
        ` : `
          <a href="${l.href}" class="mobile-nav-item ${l.active ? 'active' : ''}">
            <i class="fas ${l.icon}"></i>
            <span>${l.label}</span>
          </a>
        `).join('')}
      </div>
    </div>

    <!-- ===== Mobile "More" sheet ===== -->
    <div class="more-sheet-backdrop" id="moreSheetBackdrop"></div>
    <div class="more-sheet" id="moreSheet">
      <div class="more-sheet-handle"></div>
      ${moreItems.map(m => `
        <a href="${m.href}" class="more-sheet-item ${currentPage === m.href ? 'active' : ''}">
          <i class="fas ${m.icon}"></i>
          <span>${m.label}</span>
        </a>
      `).join('') || '<div style="padding:20px;text-align:center;color:var(--text-muted);font-size:13px">No additional pages</div>'}
      <div class="more-sheet-divider"></div>
      <button class="more-sheet-item" id="moreThemeToggle">
        <i class="fas fa-moon"></i><span>Toggle theme</span>
      </button>
      <button class="more-sheet-item" id="moreSignOut" style="color:var(--danger)">
        <i class="fas fa-right-from-bracket" style="background:var(--danger-soft);color:var(--danger)"></i>
        <span>Sign out</span>
      </button>
    </div>

    <!-- ===== NEW: Mobile account sheet (separate from desktop popover) ===== -->
    <div class="mobile-account-backdrop" id="mobileAccountBackdrop"></div>
    <div class="mobile-account-sheet" id="mobileAccountSheet" role="dialog" aria-label="Account menu" aria-modal="true">
      <div class="mas-handle"></div>
      <div class="mas-header">
        <div class="mas-avatar">${escapeHtml(initial)}</div>
        <div class="mas-info">
          <div class="mas-name">${escapeHtml(profile.full_name || profile.email)}</div>
          <div class="mas-email">${escapeHtml(profile.email)}</div>
          <div class="mas-role">
            <span class="badge badge-${profile.role}"><i class="fas fa-${roleIcon}"></i>${profile.role}</span>
          </div>
        </div>
      </div>
      <div class="mas-list">
        <a href="profile.html" class="mas-item" role="menuitem">
          <span class="mas-item-icon"><i class="fas fa-user"></i></span>
          <span class="mas-item-label">Profile</span>
          <i class="fas fa-chevron-right mas-item-chevron"></i>
        </a>
        <button class="mas-item install-app-item" id="masInstallApp" type="button" role="menuitem">
          <span class="mas-item-icon"><i class="fas fa-download"></i></span>
          <span class="mas-item-label">Install app</span>
          <i class="fas fa-chevron-right mas-item-chevron"></i>
        </button>
        <button class="mas-item" id="masThemeToggle" type="button" role="menuitem">
          <span class="mas-item-icon"><i class="fas ${isDark ? 'fa-sun' : 'fa-moon'}"></i></span>
          <span class="mas-item-label">${isDark ? 'Light mode' : 'Dark mode'}</span>
        </button>
      </div>
      <div class="mas-sep"></div>
      <div class="mas-list">
        <button class="mas-item mas-item-danger" id="masSignOut" type="button" role="menuitem">
          <span class="mas-item-icon"><i class="fas fa-right-from-bracket"></i></span>
          <span class="mas-item-label">Sign out</span>
        </button>
      </div>
    </div>
  `;

  /* ============================================================
     THEME TOGGLE (all variants)
     ============================================================ */
  document.querySelectorAll('[data-theme-toggle]').forEach(btn => { btn.onclick = toggleTheme; });
  document.getElementById('themeMenuItem')?.addEventListener('click', toggleTheme);
  document.getElementById('masThemeToggle')?.addEventListener('click', toggleTheme);
  document.getElementById('moreThemeToggle')?.addEventListener('click', () => {
    toggleTheme();
    closeMoreSheet();
  });
  updateThemeIcons();

  /* ============================================================
     AVATAR BUTTON → opens desktop popover OR mobile sheet
     ============================================================ */
  const avatarBtn = document.getElementById('avatarBtn');
  const avatarMenu = document.getElementById('avatarMenu');
  const mobileSheet = document.getElementById('mobileAccountSheet');
  const mobileBackdrop = document.getElementById('mobileAccountBackdrop');
  const isMobile = () => window.matchMedia('(max-width: 900px)').matches;

  let savedScrollY = 0;

  function openDesktopMenu() {
    avatarMenu?.classList.add('open');
  }
  function closeDesktopMenu() {
    avatarMenu?.classList.remove('open');
  }

  function openMobileSheet() {
    if (!mobileSheet || !mobileBackdrop) return;
    savedScrollY = window.scrollY;
    document.body.style.position = 'fixed';
    document.body.style.top = `-${savedScrollY}px`;
    document.body.style.width = '100%';
    document.body.style.overflow = 'hidden';
    mobileBackdrop.classList.add('open');
    mobileSheet.classList.add('open');
    if (navigator.vibrate) try { navigator.vibrate(8); } catch {}
  }
  function closeMobileSheet() {
    if (!mobileSheet || !mobileBackdrop) return;
    mobileSheet.classList.remove('open');
    mobileBackdrop.classList.remove('open');
    document.body.style.position = '';
    document.body.style.top = '';
    document.body.style.width = '';
    document.body.style.overflow = '';
    window.scrollTo(0, savedScrollY);
  }

  if (avatarBtn) {
    avatarBtn.onclick = (e) => {
      e.stopPropagation();
      if (isMobile()) {
        if (mobileSheet?.classList.contains('open')) closeMobileSheet();
        else openMobileSheet();
      } else {
        if (avatarMenu?.classList.contains('open')) closeDesktopMenu();
        else openDesktopMenu();
      }
    };
  }

  /* ---- Backdrop click closes mobile sheet ---- */
  mobileBackdrop?.addEventListener('click', closeMobileSheet);

  /* ---- Escape closes everything ---- */
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      closeDesktopMenu();
      closeMobileSheet();
    }
  });

  /* ---- Click outside closes desktop popover (desktop only) ---- */
  document.addEventListener('click', (e) => {
    if (isMobile()) return;
    if (avatarMenu && avatarBtn && !avatarMenu.contains(e.target) && !avatarBtn.contains(e.target)) {
      closeDesktopMenu();
    }
  });

  /* ---- Resize → close whatever doesn't belong to the new viewport ---- */
  window.addEventListener('resize', () => {
    if (isMobile()) closeDesktopMenu();
    else closeMobileSheet();
  });

  /* ---- Mobile sheet: tap nav items closes sheet, then acts ---- */
  mobileSheet?.querySelectorAll('a.mas-item, button.mas-item').forEach(item => {
    if (item.id === 'masThemeToggle') return; // theme toggle stays open
    item.addEventListener('click', () => {
      closeMobileSheet();
    });
  });

  /* ---- Mobile sheet: swipe-down-to-close ---- */
  if (mobileSheet) {
    let touchStartY = 0;
    let touchStartTime = 0;
    let currentDelta = 0;

    mobileSheet.addEventListener('touchstart', (e) => {
      touchStartY = e.touches[0].clientY;
      touchStartTime = Date.now();
      currentDelta = 0;
      mobileSheet.style.transition = 'none';
    }, { passive: true });

    mobileSheet.addEventListener('touchmove', (e) => {
      const delta = e.touches[0].clientY - touchStartY;
      if (delta > 0) {
        currentDelta = delta;
        mobileSheet.style.transform = `translateY(${delta}px)`;
      }
    }, { passive: true });

    mobileSheet.addEventListener('touchend', (e) => {
      mobileSheet.style.transition = '';
      mobileSheet.style.transform = '';
      const deltaTime = Date.now() - touchStartTime;
      const shouldClose = currentDelta > 120 || (currentDelta > 50 && deltaTime < 300);
      if (shouldClose) closeMobileSheet();
    }, { passive: true });
  }

  /* ============================================================
     MORE SHEET (mobile bottom nav)
     ============================================================ */
  const moreBtn = document.getElementById('moreBtn');
  const moreSheet = document.getElementById('moreSheet');
  const moreBackdrop = document.getElementById('moreSheetBackdrop');

  function openMoreSheet() {
    moreSheet?.classList.add('open');
    moreBackdrop?.classList.add('open');
    if (navigator.vibrate) try { navigator.vibrate(8); } catch {}
  }
  function closeMoreSheet() {
    moreSheet?.classList.remove('open');
    moreBackdrop?.classList.remove('open');
  }

  moreBtn?.addEventListener('click', openMoreSheet);
  moreBackdrop?.addEventListener('click', closeMoreSheet);
  document.getElementById('moreSignOut')?.addEventListener('click', signOut);

  /* ============================================================
     SIGN OUT
     ============================================================ */
  document.getElementById('logoutBtn')?.addEventListener('click', signOut);
  document.getElementById('masSignOut')?.addEventListener('click', signOut);

  /* ============================================================
     PWA INSTALL — wire up desktop + mobile buttons
     ============================================================ */
  const installBtnDesktop = document.getElementById('installAppBtn');
  const installBtnMobile = document.getElementById('masInstallApp');

  function refreshInstallButtons() {
    if (window.deferredInstallPrompt) {
      installBtnDesktop?.classList.add('available');
      installBtnMobile?.classList.add('available');
    }
  }
  refreshInstallButtons();
  window.addEventListener('pwainstallready', refreshInstallButtons);

  async function triggerInstall() {
    const p = window.deferredInstallPrompt;
    if (!p) return;
    p.prompt();
    const { outcome } = await p.userChoice;
    if (outcome === 'accepted') {
      installBtnDesktop?.classList.remove('available');
      installBtnMobile?.classList.remove('available');
    }
    window.deferredInstallPrompt = null;
  }

  installBtnDesktop?.addEventListener('click', triggerInstall);
  installBtnMobile?.addEventListener('click', triggerInstall);

  /* ============================================================
     HAPTIC FEEDBACK
     ============================================================ */
  document.querySelectorAll('.mobile-nav-item').forEach(item => {
    item.addEventListener('touchstart', () => {
      if (navigator.vibrate) try { navigator.vibrate(8); } catch {}
    }, { passive: true });
  });
}

/* ============================================================
   PWA — service worker + install prompt + offline banner
   ============================================================ */
let _pwaInitialized = false;
export function initPWA() {
  if (_pwaInitialized) return;
  _pwaInitialized = true;

  if ('serviceWorker' in navigator && location.protocol !== 'file:') {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('./sw.js').then(reg => {
        setInterval(() => { reg.update().catch(() => {}); }, 60 * 60 * 1000);
      }).catch(err => {
        console.warn('[PWA] SW registration failed:', err);
      });
    });
  }

  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault();
    window.deferredInstallPrompt = e;
    document.querySelectorAll('.install-app-item').forEach(el => el.classList.add('available'));
    window.dispatchEvent(new Event('pwainstallready'));
  });

  window.addEventListener('appinstalled', () => {
    window.deferredInstallPrompt = null;
    document.querySelectorAll('.install-app-item').forEach(el => el.classList.remove('available'));
  });

  function updateOnlineStatus() {
    let bar = document.querySelector('.offline-banner');
    if (navigator.onLine) {
      if (bar) bar.classList.remove('show');
    } else {
      if (!bar) {
        bar = document.createElement('div');
        bar.className = 'offline-banner';
        bar.innerHTML = '<i class="fas fa-wifi" style="opacity:.6"></i> You\'re offline — some features may not work';
        document.body.prepend(bar);
      }
      bar.classList.add('show');
    }
  }
  window.addEventListener('online', updateOnlineStatus);
  window.addEventListener('offline', updateOnlineStatus);
  updateOnlineStatus();
}

initPWA();