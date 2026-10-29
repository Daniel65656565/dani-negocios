// Guarda la app en el teléfono para que abra rápido. Los datos siempre se piden al servidor.
const VERSION = "dani-negocios-20261029-073113";
const ARCHIVOS = ["./", "index.html", "supabase-config.js", "manifest.webmanifest", "icono-192.png", "icono-512.png", "frases.js", "charla.js", "caras/sonrisa_tr.webp", "caras/boca_tr.webp", "caras/escuchando_tr.webp", "caras/pensando_tr.webp", "caras/saludo_tr.webp"];
self.addEventListener("install", e => { e.waitUntil(caches.open(VERSION).then(c => c.addAll(ARCHIVOS)).then(() => self.skipWaiting())); });
self.addEventListener("activate", e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener("fetch", e => {
  const u = new URL(e.request.url);
  if (e.request.method !== "GET" || u.origin !== location.origin) return; // servidor y fuentes: siempre por internet
  if (u.pathname.endsWith("version.json")) return; // siempre de internet, nunca guardado
  e.respondWith(fetch(e.request).then(r => { if (r.ok && r.type === "basic") { const copia = r.clone(); caches.open(VERSION).then(c => c.put(e.request, copia)); } return r; }).catch(() => caches.match(e.request).then(r => r || caches.match("index.html"))));
});

// Notificaciones (avisos al teléfono): llegan cifradas desde la función "avisos".
self.addEventListener("push", e => {
  let d = {}; try { d = e.data ? e.data.json() : {}; } catch (_) { d = { b: e.data ? e.data.text() : "" }; }
  const titulo = d.t || "DANI Mi Negocio";
  e.waitUntil(self.registration.showNotification(titulo, {
    body: d.b || "", icon: "icono-192.png", badge: "icono-192.png", tag: (d.u || "") + "|" + (d.b || "").slice(0, 40),
    data: { u: d.u || "./" }, vibrate: [200, 100, 200], requireInteraction: titulo === "Recordatorio"
  }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const destino = new URL((e.notification.data && e.notification.data.u) || "./", self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(ws => {
    for (const w of ws) { if (w.url.startsWith(self.registration.scope) && "focus" in w) { w.navigate(destino).catch(() => {}); return w.focus(); } }
    return self.clients.openWindow(destino);
  }));
});
