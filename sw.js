const CACHE_NAME = 'lpu-v1';
const STATIC_ASSETS = [
  '/', '/index.html', '/login.html', '/reset-password.html',
  '/student.html', '/faculty.html', '/faculty-makeup.html', '/profile.html',
  '/admin.html', '/admin-add.html', '/admin-rooms.html',
  '/admin-users.html', '/admin-bookings.html', '/admin-settings.html',
  '/css/style.css', '/js/core.js', '/js/config.js',
  '/manifest.json', '/icons/icon.svg',
  'https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm'
];
self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE_NAME)
      .then(c => c.addAll(STATIC_ASSETS.map(u => new Request(u, { cache: 'reload' }))))
      .catch(() => {})
      .then(() => self.skipWaiting())
  );
});
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET') return;
  if (url.hostname.includes('supabase.co')) return;
  e.respondWith(
    caches.match(e.request).then(cached => {
      const network = fetch(e.request).then(res => {
        if (res.ok && (url.origin === location.origin || url.hostname.includes('cloudflare') || url.hostname.includes('jsdelivr'))) {
          const clone = res.clone();
          caches.open(CACHE_NAME).then(c => c.put(e.request, clone));
        }
        return res;
      }).catch(() => cached);
      return cached || network;
    })
  );
});