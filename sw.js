// ============================================================
// LPU Scheduler — Service Worker
// Cache-first for static assets, network-first for HTML
// Never cache Supabase API calls
// ============================================================

const CACHE_VERSION = 'lpu-scheduler-v3';
const CACHE_STATIC = CACHE_VERSION + '-static';
const CACHE_PAGES  = CACHE_VERSION + '-pages';

// Files to pre-cache on install
const PRECACHE = [
  './',
  './index.html',
  './login.html',
  './credits.html',
  './css/style.css',
  './css/admin.css',
  './css/mobile-app.css',
  './js/config.js',
  './js/core.js',
  './js/pwa.js',
  './js/banner.js',
  './icons/icon-192.svg',
  './icons/icon-512.svg',
];

// Supabase + external — never cache, always network
const NETWORK_ONLY = [
  'supabase.co',
  'challenges.cloudflare.com',
  'cdn.jsdelivr.net',
  'fonts.googleapis.com',
  'fonts.gstatic.com',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_STATIC).then(cache => {
      return Promise.allSettled(PRECACHE.map(url => cache.add(url).catch(() => {})));
    }).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(
      keys.filter(k => !k.startsWith(CACHE_VERSION)).map(k => caches.delete(k))
    )).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Only handle GET requests
  if (req.method !== 'GET') return;

  // Skip cross-origin non-asset requests
  for (const domain of NETWORK_ONLY) {
    if (url.hostname.includes(domain)) {
      return; // Network only — let browser handle
    }
  }

  // Skip other-origin requests entirely
  if (url.origin !== location.origin) return;

  // HTML navigation — network first, cache fallback
  if (req.mode === 'navigate' || req.destination === 'document') {
    event.respondWith(
      fetch(req).then(res => {
        const clone = res.clone();
        caches.open(CACHE_PAGES).then(cache => cache.put(req, clone)).catch(() => {});
        return res;
      }).catch(() => {
        return caches.match(req).then(cached => {
          if (cached) return cached;
          return caches.match('./index.html');
        });
      })
    );
    return;
  }

  // Static assets (CSS, JS, images, fonts) — cache first, update in background
  if (['style', 'script', 'image', 'font'].includes(req.destination)) {
    event.respondWith(
      caches.match(req).then(cached => {
        const networkFetch = fetch(req).then(res => {
          if (res.ok) {
            const clone = res.clone();
            caches.open(CACHE_STATIC).then(cache => cache.put(req, clone)).catch(() => {});
          }
          return res;
        }).catch(() => cached);
        return cached || networkFetch;
      })
    );
    return;
  }

  // Everything else — network first
  event.respondWith(
    fetch(req).catch(() => caches.match(req))
  );
});

// Allow page to trigger skip waiting
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});