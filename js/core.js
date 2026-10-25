import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

// Re-export so pages can `import { SUPABASE_URL } from './js/core.js'`
export { SUPABASE_URL, SUPABASE_ANON_KEY };

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
export const BASE = new URL('.', location.href).href;

/* ---------- helpers ---------- */
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
}

export function nowDate() { return new Date(); }

export function todayISO() {
  const d = nowDate();
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}

export function formatTime(d) {
  return `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}:${String(d.getSeconds()).padStart(2,'0')}`;
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
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' }) +
    ' · ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

/* ---------- theme ---------- */
const THEME_KEY = 'theme';
export function getCurrentTheme() { return document.documentElement.getAttribute('data-theme') || 'light'; }

function updateThemeIcons() {
  const isDark = getCurrentTheme() === 'dark';
  document.querySelectorAll('[data-theme-toggle]').forEach(btn => {
    btn.innerHTML = isDark ? '<i class="fas fa-sun"></i>' : '<i class="fas fa-moon"></i>';
  });
}

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

export function initTheme() {
  const stored = localStorage.getItem(THEME_KEY);
  const systemDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  applyTheme(stored || (systemDark ? 'dark' : 'light'));
}

/* ---------- auth ---------- */
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

  return { session, profile };
}

export async function signOut() {
  try { await supabase.auth.signOut(); } catch {}
  location.href = `${BASE}login.html`;
}

/* ---------- nav bar ---------- */
export function renderNav(profile) {
  const el = document.getElementById('nav');
  if (!el || !profile) return;

  initTheme();

  const initial = ((profile.full_name || profile.email || '?').trim()[0] || '?').toUpperCase();
  const roleIcon =
    profile.role === 'admin' ? 'shield-halved' :
    profile.role === 'faculty' ? 'chalkboard-user' : 'graduation-cap';

  const home =
    profile.role === 'admin' ? 'admin.html' :
    profile.role === 'faculty' ? 'faculty.html' : 'student.html';

  el.innerHTML = `
    <div class="nav">
      <div class="nav-inner">
        <a href="${home}" class="nav-brand">LPU<span class="nav-brand-dot">.</span>Scheduler</a>
        <div class="nav-links">
          <a href="${home}" class="nav-link active"><i class="fas fa-gauge-high"></i>Dashboard</a>
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
            <span class="badge badge-${profile.role}">
              <i class="fas fa-${roleIcon}"></i>${profile.role}
            </span>
          </div>
        </div>
        <div class="avatar-menu-divider"></div>
        <button class="avatar-menu-item" id="themeMenuItem"></button>
        <div class="avatar-menu-divider"></div>
        <button class="avatar-menu-item avatar-menu-danger" id="logoutBtn">
          <i class="fas fa-right-from-bracket"></i> Sign out
        </button>
      </div>
    </div>`;

  document.querySelectorAll('[data-theme-toggle]').forEach(btn => { btn.onclick = toggleTheme; });

  const themeMenuItem = document.getElementById('themeMenuItem');
  if (themeMenuItem) {
    const paint = () => {
      const isDark = getCurrentTheme() === 'dark';
      themeMenuItem.innerHTML = isDark
        ? '<i class="fas fa-sun"></i> Light mode'
        : '<i class="fas fa-moon"></i> Dark mode';
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
      if (!avatarMenu.contains(e.target) && !avatarBtn.contains(e.target)) {
        avatarMenu.classList.remove('open');
      }
    });
  }

  document.getElementById('logoutBtn')?.addEventListener('click', signOut);
}