// Laundry status page. Reads the public read-only views with the publishable key every 30 s.
// Every value from the database is inserted with textContent and every sentence is built here from
// number-coded states, so nothing stored can turn into markup on this page.
"use strict";

const POLL_MS = 30_000;
// A wash cycle never runs longer than this, so "in use" for longer means the cycle is over and the
// clothes haven't been taken out yet (the washer only reports "available" once the door opens).
// The board's own 3-hour rule still turns a never-opened washer into "out of order".
const CYCLE_MAX_MIN = 60;
const STATE_TEXT = {
  free: "free",
  in_use: "in use",
  finished: "probably done",
  out_of_order: "out of order",
  offline: "no signal",
  no_data: "no data yet",
  format_changed: "unreadable",
};
const EVENT_TEXT = {
  washer_free: (n) => `Washer ${n} freed up`,
  washer_taken: (n) => `Washer ${n} started`,
  listener_lost: () => "Scanner went offline",
  listener_back: () => "Scanner back online",
};

let config;
let freeNow = null;   // free washers in the latest data, for the notify hint
let canNotify = false;   // false until push is known to work here; the setup hint must then stay put
let hintShown = false;   // the status line holds the "N are free right now" hint, not a message
const STORE_KEY = "laundry-alert";

async function view(name, query = "") {
  const res = await fetch(`${config.SUPABASE_URL}/rest/v1/${name}${query}`, {
    headers: { apikey: config.SUPABASE_PUBLISHABLE_KEY },
    cache: "no-store",
  });
  if (!res.ok) throw new Error(`${name}: HTTP ${res.status}`);
  return res.json();
}

function clock(iso) {
  return new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function minutesSince(iso) {
  return Math.max(0, Math.floor((Date.now() - Date.parse(iso)) / 60_000));
}

// What a person should see: the database state, except a long "in use" is shown as "probably done".
function displayState(r) {
  if (!r) return "no_data";
  if (r.state === "in_use" && r.state_since && minutesSince(r.state_since) > CYCLE_MAX_MIN) return "finished";
  return r.state;
}

// Tile text: minutes only while a load is running; "+" when the start was before a scanner restart.
function tileTag(state, r) {
  if (state === "in_use") return r.state_since ? `${minutesSince(r.state_since)}m${r.since_restart ? "+" : ""}` : "";
  if (state === "finished") return "done?";
  if (state === "out_of_order") return "✕";
  if (state === "free") return "";
  return "?";
}

function listText(state, r) {
  const base = STATE_TEXT[state] || state;
  if (state === "in_use" && r.state_since) {
    const min = minutesSince(r.state_since);
    return r.since_restart ? `${base} · at least ${min} min` : `${base} · ${min} min`;
  }
  return base;
}

function renderMachines(rows, stale) {
  const byNum = new Map(rows.map((r) => [r.machine, r]));
  for (const tile of document.querySelectorAll(".tile.washer")) {
    const n = Number(tile.dataset.machine);
    const r = byNum.get(n);
    const state = displayState(r);
    tile.classList.remove(...Object.keys(STATE_TEXT));
    tile.classList.add(state);
    tile.replaceChildren(el("span", "num", String(n)));
    const tag = tileTag(state, r);
    if (tag) tile.append(el("span", "tag", tag));
    const sentence = `Washer ${n}: ${listText(state, r)}`;
    tile.setAttribute("role", "img");
    tile.setAttribute("aria-label", sentence);
    tile.title = sentence;
  }
  document.getElementById("room").classList.toggle("stale", stale);

  const list = document.getElementById("list");
  list.replaceChildren();
  for (let n = 1; n <= 6; n++) {
    const r = byNum.get(n);
    const state = displayState(r);
    const li = el("li");
    li.append(el("span", "", `Washer ${n}`));
    li.append(el("span", `state ${state}`, listText(state, r)));
    list.append(li);
  }

  const live = !stale && rows.length > 0;
  const states = rows.map(displayState);
  const working = states.filter((s) => s === "free" || s === "in_use" || s === "finished").length;
  const free = states.filter((s) => s === "free").length;
  const done = states.filter((s) => s === "finished").length;
  const summary = document.getElementById("summary");
  summary.replaceChildren();
  if (!live) {
    summary.textContent = "No live data right now.";
  } else {
    summary.append(el("strong", "", `${free} of ${working}`), " washers free");
    if (done) summary.append(` · ${done} probably done`);
  }
  freeNow = live ? free : null;
  updateNotifyHint();
}

function renderScanner(scanner) {
  const banner = document.getElementById("banner");
  const s = scanner[0];
  if (!s) {
    banner.textContent = "The scanner hasn't reported yet.";
    banner.hidden = false;
    return true;
  }
  if (s.stale || s.listener !== "online") {
    const why = s.stale ? `No update since ${clock(s.last_snapshot_at)}` : "The laundry-room sensor isn't reporting";
    banner.textContent = `${why}, so these states may be out of date.`;
    banner.hidden = false;
    return true;
  }
  banner.hidden = true;
  return false;
}

function renderActivity(events) {
  const ul = document.getElementById("activity");
  ul.replaceChildren();
  const known = events.filter((e) => EVENT_TEXT[e.event]).slice(0, 12);
  if (known.length === 0) {
    ul.append(el("li", "muted", "Nothing in the last 24 hours."));
    return;
  }
  for (const e of known) {
    const li = el("li");
    li.append(el("span", "", EVENT_TEXT[e.event](e.machine)));
    const t = el("time", "", clock(e.at));
    t.dateTime = e.at;
    li.append(t);
    ul.append(li);
  }
}

async function refresh() {
  try {
    const [scanner, machines, events] = await Promise.all([
      view("scanner_status"),
      view("machine_status", "?order=machine"),
      view("recent_events"),
    ]);
    const stale = renderScanner(scanner);
    renderMachines(machines, stale);
    renderActivity(events);
  } catch (err) {
    const banner = document.getElementById("banner");
    banner.textContent = "Can't reach the status service right now. Retrying…";
    banner.hidden = false;
    freeNow = null;
    updateNotifyHint();
    console.error(err);
  }
}

// ---------------------------------------------------------------- one-shot alerts (Web Push)
// The browser subscribes, the database stores "N or more free" for 3 hours, and when enough washers
// are free it sends one alert and forgets the subscription. Nothing about the person is stored.

function pushSupported() {
  return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
}

function isIos() {
  return /iPhone|iPad|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
}

function keyBytes(b64url) {
  const b64 = (b64url + "=".repeat((4 - (b64url.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

// A subscription is tied to the VAPID public key it was made with. After a key rotation the
// browser still holds the old one, and pushes to it fail without any error on this page.
function madeWithKey(sub, key) {
  const old = sub.options && sub.options.applicationServerKey;
  if (!old) return false;
  const a = new Uint8Array(old);
  return a.length === key.length && a.every((b, i) => b === key[i]);
}

function readAlert() {
  try {
    const a = JSON.parse(localStorage.getItem(STORE_KEY) || "null");
    return a && a.until > Date.now() ? a : null;
  } catch {
    return null;
  }
}

function writeAlert(a) {
  try {
    if (a) localStorage.setItem(STORE_KEY, JSON.stringify(a));
    else localStorage.removeItem(STORE_KEY);
  } catch {
    /* private mode: the alert still works, the page just won't remember it */
  }
}

function setStatus(text, isHint = false) {
  const p = document.getElementById("notify-status");
  p.textContent = text;
  p.hidden = !text;
  hintShown = isHint;
}

function updateNotifyHint() {
  const btn = document.getElementById("notify-btn");
  if (!canNotify || btn.classList.contains("cancel")) return;
  const want = Number(document.getElementById("want").value);
  if (freeNow !== null && freeNow >= want) setStatus(`${freeNow} ${freeNow === 1 ? "is" : "are"} free right now.`, true);
  else if (hintShown) setStatus("");
}

// Forget the saved alert once it has fired (the service worker unsubscribes when it shows it).
async function syncAlert(reg) {
  if (!(await reg.pushManager.getSubscription())) writeAlert(null);
}

async function showArmed(reg) {
  await syncAlert(reg);
  const btn = document.getElementById("notify-btn");
  const want = document.getElementById("want");
  const a = readAlert();
  if (a) {
    want.value = String(a.want);
    want.disabled = true;
    btn.textContent = "Cancel alert";
    btn.classList.add("cancel");
    setStatus(`You'll get one alert when ${a.want}+ washers are free (until ${clock(a.until)}).`);
  } else {
    const wasArmed = btn.classList.contains("cancel");
    want.disabled = false;
    btn.textContent = "Notify me";
    btn.classList.remove("cancel");
    if (wasArmed || hintShown) setStatus("");   // keep other messages, e.g. "Alerts are blocked…"
    updateNotifyHint();
  }
}

async function setupNotify() {
  const form = document.getElementById("notify");
  form.hidden = false;
  const btn = document.getElementById("notify-btn");

  // Safari on iPhone only allows alerts from a Home Screen app, so in the browser the whole
  // control is disabled and the setup hint stays visible.
  if (!pushSupported()) {
    btn.disabled = true;
    document.getElementById("want").disabled = true;
    setStatus(isIos()
      ? "On iPhone: tap Share → Add to Home Screen, then open Laundry from your Home Screen to get alerts."
      : "This browser can't show alerts.");
    return;
  }
  canNotify = true;
  document.getElementById("want").addEventListener("change", updateNotifyHint);
  const reg = await navigator.serviceWorker.register("sw.js");
  await showArmed(reg);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && !btn.disabled) showArmed(reg).catch(console.error);
  });

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    btn.disabled = true;
    try {
      const existing = await reg.pushManager.getSubscription();
      if (btn.classList.contains("cancel")) {
        if (existing) await existing.unsubscribe();   // the server copy expires on its own; pushes to it fail harmlessly
        writeAlert(null);
        await showArmed(reg);
        setStatus("Alert canceled.");
        return;
      }
      if ((await Notification.requestPermission()) !== "granted") {
        setStatus("Alerts are blocked. Allow notifications for this site in your browser settings.");
        return;
      }
      const key = keyBytes(config.VAPID_PUBLIC_KEY);
      let sub = existing;
      if (sub && !madeWithKey(sub, key)) {
        await sub.unsubscribe();
        sub = null;
      }
      if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
      const want = Number(document.getElementById("want").value);
      const res = await fetch(`${config.SUPABASE_URL}/rest/v1/rpc/subscribe_push`, {
        method: "POST",
        headers: { apikey: config.SUPABASE_PUBLISHABLE_KEY, "Content-Type": "application/json" },
        body: JSON.stringify({ sub: { ...sub.toJSON(), min_free: want } }),
      });
      if (!res.ok) {
        setStatus(res.status === 429 ? "Too many alerts right now. Try again in a minute." : "Couldn't set the alert. Try again.");
        return;
      }
      const { expires_in_minutes: minutes } = await res.json();
      writeAlert({ want, until: Date.now() + minutes * 60_000 });
      await showArmed(reg);
    } catch (err) {
      console.error(err);
      setStatus("Couldn't set the alert. Try again.");
    } finally {
      btn.disabled = false;
    }
  });
}

async function main() {
  try {
    const res = await fetch("config.public.json", { cache: "no-store" });
    if (!res.ok) throw new Error(`config: HTTP ${res.status}`);
    config = await res.json();
  } catch (err) {
    const banner = document.getElementById("banner");
    banner.textContent = "Can't reach the status service right now. Retrying…";
    banner.hidden = false;
    console.error(err);
    setTimeout(main, POLL_MS);
    return;
  }
  document.getElementById("cycle-max").textContent = String(CYCLE_MAX_MIN);
  await refresh();
  setInterval(refresh, POLL_MS);
  setupNotify().catch((err) => console.error(err));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") refresh();
  });
}

main();
