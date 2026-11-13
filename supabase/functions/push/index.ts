// Sends one Web Push to each subscription the database hands over (laundry.notify_free).
// It holds no database key and reads nothing: the database decides who gets an alert and deletes
// those subscriptions itself. Callers must present the shared hook secret (Vault + function secret).
import webpush from "npm:web-push@3.6.7";

const HOOK_SECRET = Deno.env.get("PUSH_HOOK_SECRET") ?? "";
webpush.setVapidDetails(
  "https://nexkiv.github.io/laundry-status/",
  Deno.env.get("VAPID_PUBLIC_KEY") ?? "",
  Deno.env.get("VAPID_PRIVATE_KEY") ?? "",
);

// Same allowlist as the database check: only real browser push services, never an arbitrary URL.
const PUSH_HOST = /^https:\/\/(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)\//;

function sameSecret(a: string, b: string): boolean {
  if (!a || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST" || !HOOK_SECRET || !sameSecret(req.headers.get("x-hook-secret") ?? "", HOOK_SECRET)) {
    return new Response("forbidden", { status: 403 });
  }
  let body: { free?: unknown; subscriptions?: unknown };
  try {
    body = await req.json();
  } catch {
    return new Response("bad json", { status: 400 });
  }
  const free = body.free;
  const subs = body.subscriptions;
  if (typeof free !== "number" || !Number.isInteger(free) || free < 1 || free > 6 ||
      !Array.isArray(subs) || subs.length > 500) {
    return new Response("bad request", { status: 400 });
  }
  const payload = JSON.stringify({
    title: free === 1 ? "A washer is free" : `${free} washers are free`,
    body: "Tap to see the laundry room.",
  });
  let sent = 0, failed = 0;
  await Promise.all(subs.map(async (s: any) => {
    if (typeof s?.endpoint !== "string" || !PUSH_HOST.test(s.endpoint)) { failed++; return; }
    try {
      // TTL 10 min: an alert that arrives later than that is no longer true.
      await webpush.sendNotification(s, payload, { TTL: 600, urgency: "high" });
      sent++;
    } catch {
      failed++;  // e.g. 410 Gone: the browser dropped the subscription. Nothing to clean up.
    }
  }));
  return Response.json({ sent, failed });
});
