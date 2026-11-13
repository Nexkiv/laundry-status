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
    tile.className = tile.className.replace(/\b(free|in_use|finished|out_of_order|offline|no_data|format_changed)\b/g, "").trim();
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

  const states = rows.map(displayState);
  const working = states.filter((s) => s === "free" || s === "in_use" || s === "finished").length;
  const free = states.filter((s) => s === "free").length;
  const done = states.filter((s) => s === "finished").length;
  const summary = document.getElementById("summary");
  summary.replaceChildren();
  if (stale || rows.length === 0) {
    summary.textContent = "No live data right now.";
  } else {
    summary.append(el("strong", "", `${free} of ${working}`), " washers free");
    if (done) summary.append(` · ${done} probably done`);
  }
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
    console.error(err);
  }
}

async function main() {
  config = await (await fetch("config.public.json", { cache: "no-store" })).json();
  await refresh();
  setInterval(refresh, POLL_MS);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") refresh();
  });
}

main();
