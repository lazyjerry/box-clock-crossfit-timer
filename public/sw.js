const CACHE_NAME = 'box-clock-v5';
const APP_SHELL = ['./', './index.html', './styles.css', './app.js', './timer-core.mjs', './timer-worker.js', './manifest.webmanifest', './icon.svg'];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key)))).then(() => self.clients.claim()));
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET' || new URL(event.request.url).origin !== self.location.origin) return;
  const networkFirst = event.request.mode === 'navigate' || ['script', 'style', 'worker', 'manifest'].includes(event.request.destination);
  const updateCache = (response) => {
    if (response.ok) caches.open(CACHE_NAME).then((cache) => cache.put(event.request, response.clone()));
    return response;
  };
  if (networkFirst) {
    event.respondWith(fetch(event.request).then(updateCache).catch(() => caches.match(event.request).then((cached) => cached || caches.match('./index.html'))));
    return;
  }
  event.respondWith(caches.match(event.request).then((cached) => cached || fetch(event.request).then(updateCache).catch(() => caches.match('./index.html'))));
});
