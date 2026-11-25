// ============================================================
// LPU Scheduler — Centralized site-wide banner
// Loads message from system_settings.site_banner
// Handles: proper object, plain string, or double-encoded JSON string
// ============================================================
import { supabase, escapeHtml } from './core.js';

/* Normalizes any stored value into a banner config object */
function normalizeBanner(raw) {
  if (raw == null) return null;

  // Already an object
  if (typeof raw === 'object') {
    return {
      enabled: raw.enabled !== false,
      type: ['info','warning','danger','success'].includes(raw.type) ? raw.type : 'warning',
      message: typeof raw.message === 'string' ? raw.message : '',
      dismissible: raw.dismissible !== false,
    };
  }

  // Plain string — could be legacy message OR double-encoded JSON
  if (typeof raw === 'string') {
    const trimmed = raw.trim();
    if (!trimmed) return null;

    // Try parse as JSON
    try {
      const parsed = JSON.parse(trimmed);
      // If the parsed value is an object that looks like a banner config, use it
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        if ('message' in parsed || 'enabled' in parsed || 'type' in parsed) {
          return {
            enabled: parsed.enabled !== false,
            type: ['info','warning','danger','success'].includes(parsed.type) ? parsed.type : 'warning',
            message: typeof parsed.message === 'string' ? parsed.message : '',
            dismissible: parsed.dismissible !== false,
          };
        }
      }
    } catch { /* not JSON — fall through */ }

    // Legacy plain-string banner
    return {
      enabled: true,
      type: 'warning',
      message: trimmed,
      dismissible: true,
    };
  }

  return null;
}

(async () => {
  try {
    const { data } = await supabase
      .from('system_settings')
      .select('value')
      .eq('key', 'site_banner')
      .maybeSingle();

    if (!data) return;

    const cfg = normalizeBanner(data.value);
    if (!cfg) return;
    if (!cfg.enabled) return;
    if (!cfg.message || !cfg.message.trim()) return;

    const type = cfg.type;
    const dismissible = cfg.dismissible;

    // Session-scoped dismissal key — different message = shows again
    const sessionKey = 'sb-dismissed-' + cfg.message.slice(0, 80).replace(/\s+/g, '_');

    if (dismissible && sessionStorage.getItem(sessionKey) === '1') return;

    // Palette
    const palette = {
      info:    { bg: 'linear-gradient(90deg,#3B82F6,#2563EB)', shadow: 'rgba(37,99,235,0.35)',  icon: 'fa-circle-info' },
      warning: { bg: 'linear-gradient(90deg,#F59E0B,#D97706)', shadow: 'rgba(217,119,6,0.35)',  icon: 'fa-triangle-exclamation' },
      danger:  { bg: 'linear-gradient(90deg,#EF4444,#DC2626)', shadow: 'rgba(220,38,38,0.35)',  icon: 'fa-circle-exclamation' },
      success: { bg: 'linear-gradient(90deg,#22C55E,#16A34A)', shadow: 'rgba(22,163,74,0.35)',  icon: 'fa-circle-check' },
    };
    const p = palette[type] || palette.warning;

    // Inject styles once
    if (!document.getElementById('sbGlobalStyles')) {
      const style = document.createElement('style');
      style.id = 'sbGlobalStyles';
      style.textContent = `
        .sb-global {
          position: fixed; top: 0; left: 0; right: 0; z-index: 9998;
          padding: 11px 20px;
          color: #FFFFFF;
          font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
          font-size: 13px; font-weight: 500; line-height: 1.5;
          display: flex; align-items: center; justify-content: center; gap: 10px;
          text-align: center;
          animation: sbSlide 400ms cubic-bezier(0.16, 1, 0.3, 1);
        }
        .sb-global .sb-icon {
          font-size: 15px; flex-shrink: 0;
          animation: sbPulse 2s ease-in-out infinite;
        }
        .sb-global .sb-text { flex: 1; max-width: 900px; overflow-wrap: break-word; }
        .sb-global .sb-close {
          background: rgba(255,255,255,0.2);
          border: 1px solid rgba(255,255,255,0.35);
          color: #FFFFFF; border-radius: 6px;
          padding: 4px 10px; font-size: 11px; font-weight: 600;
          cursor: pointer; transition: all 150ms ease; flex-shrink: 0;
          font-family: inherit;
        }
        .sb-global .sb-close:hover { background: rgba(255,255,255,0.35); border-color: rgba(255,255,255,0.5); }
        @keyframes sbSlide {
          from { transform: translateY(-100%); opacity: 0; }
          to   { transform: translateY(0);     opacity: 1; }
        }
        @keyframes sbPulse {
          0%,100% { opacity: 1; transform: scale(1); }
          50%      { opacity: 0.75; transform: scale(1.1); }
        }
        body.has-sb { padding-top: var(--sb-h, 44px) !important; }
        body.has-sb .nav { top: var(--sb-h, 44px) !important; }
        @media (max-width: 640px) {
          .sb-global { font-size: 12px; padding: 9px 14px; gap: 8px; }
          .sb-global .sb-text { font-size: 11.5px; }
        }
      `;
      document.head.appendChild(style);
    }

    // Create banner
    const banner = document.createElement('div');
    banner.className = 'sb-global';
    banner.style.background = p.bg;
    banner.style.boxShadow = `0 2px 12px ${p.shadow}`;
    banner.innerHTML = `
      <i class="fas ${p.icon} sb-icon"></i>
      <div class="sb-text">${escapeHtml(cfg.message)}</div>
      ${dismissible ? `<button class="sb-close" type="button">Dismiss</button>` : ''}
    `;
    document.body.appendChild(banner);
    document.body.classList.add('has-sb');

    function syncHeight() {
      document.body.style.setProperty('--sb-h', banner.offsetHeight + 'px');
    }
    requestAnimationFrame(syncHeight);
    window.addEventListener('resize', syncHeight);
    setTimeout(syncHeight, 300);

    if (dismissible) {
      banner.querySelector('.sb-close').onclick = () => {
        banner.remove();
        document.body.classList.remove('has-sb');
        document.body.style.paddingTop = '';
        document.body.style.removeProperty('--sb-h');
        sessionStorage.setItem(sessionKey, '1');
      };
    }
  } catch (err) {
    console.warn('[banner] load failed:', err);
  }
})();