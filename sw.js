// Service worker: shows the one-shot "washers free" alert, then drops the subscription, because the
// server has already deleted it (each alert is sent once). Scope is /laundry-status/ only.
"use strict";

self.addEventListener("push", (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = {};
  }
  const title = typeof data.title === "string" ? data.title.slice(0, 80) : "Laundry";
  const body = typeof data.body === "string" ? data.body.slice(0, 160) : "";
  event.waitUntil(Promise.all([
    self.registration.showNotification(title, { body, icon: "icon-192.png", badge: "icon-192.png", tag: "laundry-free" }),
    self.registration.pushManager.getSubscription().then((s) => s && s.unsubscribe()),
  ]));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((wins) => {
    for (const w of wins) if (w.url.includes("/laundry-status/")) return w.focus();
    return self.clients.openWindow("./");
  }));
});
