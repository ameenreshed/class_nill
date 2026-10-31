// ============================================================
// LPU Scheduler — lightweight PWA bootstrap
// Used by index.html, login.html, credits.html (which don't
// import the full core.js navigation stack)
// ============================================================

// Service worker registration
if ('serviceWorker' in navigator && location.protocol !== 'file:') {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('./sw.js').then(reg => {
      setInterval(() => { reg.update().catch(() => {}); }, 60 * 60 * 1000);
    }).catch(err => {
      console.warn('[PWA] SW registration failed:', err);
    });
  });
}

// Capture install prompt
window.deferredInstallPrompt = null;
window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
  window.deferredInstallPrompt = e;
});

// Online/offline indicator
function updateOnlineStatus() {
  let bar = document.querySelector('.offline-banner');
  if (navigator.onLine) {
    if (bar) bar.classList.remove('show');
  } else {
    if (!bar) {
      bar = document.createElement('div');
      bar.className = 'offline-banner';
      bar.innerHTML = '<i class="fas fa-wifi" style="opacity:.6"></i> You\'re offline';
      document.body.prepend(bar);
    }
    bar.classList.add('show');
  }
}
window.addEventListener('online', updateOnlineStatus);
window.addEventListener('offline', updateOnlineStatus);
updateOnlineStatus();