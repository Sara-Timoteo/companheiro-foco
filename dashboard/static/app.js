// Focus Companion dashboard.
// The noise graph lives only in this page. The focus record is opt-in and stays in this browser.
"use strict";
const $ = (id) => document.getElementById(id);
const HISTORY_SECONDS = 120;
const noiseHistory = [];   // in-memory only, cleared on reload
let threshold = 65;
let settingsLoaded = false;
let timerState = "idle";
let lastTimer = null;
let lastNoise = null;

async function send(command) {
  try {
    const res = await fetch("/api/control", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(command),
    });
    if (!res.ok) showAlert({ type: "error", message: "The device did not answer. Check the connection." });
  } catch {
    showAlert({ type: "error", message: "The device did not answer. Check the connection." });
  }
}

function fmt(seconds) {
  const s = Math.max(0, Math.round(seconds));
  return `${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

// focus block
function renderTimer(t) {
  trackSession(t);
  lastTimer = t;
  timerState = t.state;
  const lamp = $("lamp");
  const pct = t.state === "idle" ? 0 : Math.round(t.fraction_remaining * 100);
  $("lamp-fill").style.height = `${pct}%`;
  lamp.dataset.state = t.state;
  lamp.dataset.cue = String(t.state === "running" &&
    t.settings.transition_warning_min > 0 && t.remaining_s <= t.settings.transition_warning_min * 60);

  const subs = { idle: "No block running", running: "left in this block",
                 paused: "paused", finished: "Block finished. Time for a break." };
  $("time").textContent = t.state === "idle" ? "--:--" : fmt(t.remaining_s);
  $("time-sub").textContent = subs[t.state] || "";
  $("task").textContent = t.state === "idle" ? "" : t.label;
  const minutesLeft = Math.ceil(t.remaining_s / 60);
  lamp.setAttribute("aria-label", t.state === "idle" ? "Focus light: no block running"
    : `Focus light ${pct}% full, about ${minutesLeft} minutes left`);

  $("btn-start").hidden = t.state === "running" || t.state === "paused";
  $("btn-pause").hidden = t.state !== "running";
  $("btn-resume").hidden = t.state !== "paused";
  $("btn-stop").hidden = t.state === "idle" || t.state === "finished";

  $("demo-badge").hidden = !(t.time_scale > 1);
  $("demo-badge").textContent = `Demo mode: time runs ${t.time_scale}× faster`;

  threshold = t.settings.noise_threshold_db;
  $("text-summary").textContent = statusText();
  if (!settingsLoaded) { loadSettings(t.settings); settingsLoaded = true; }
}

$("start-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const minutes = Number(new FormData(e.target).get("minutes") || 25);
  send({ cmd: "start", minutes, label: $("label").value.trim() });
});
$("btn-pause").addEventListener("click", () => send({ cmd: "pause" }));
$("btn-resume").addEventListener("click", () => send({ cmd: "resume" }));
$("btn-stop").addEventListener("click", () => send({ cmd: "stop" }));
$("btn-spike").addEventListener("click", () => send({ cmd: "simulate", event: "noise_spike", seconds: 30 }));

// gentle cues
const ICONS = { noise_high: "〰", noise_ok: "○", transition: "⏳", session_end: "✓", error: "!" };
const TITLES = { noise_high: "Noise", noise_ok: "Calmer", transition: "Transition coming",
                 session_end: "Block done", error: "Connection" };

function showAlert(a) {
  if (a.type === "noise_high" && current) current.noise_cues += 1;
  if (a.type === "noise_ok") {
    document.querySelectorAll(".alert.noise_high").forEach((el) => el.remove());
  }
  const li = document.createElement("li");
  li.className = `alert ${a.type}`;
  const icon = document.createElement("span");
  icon.className = "icon"; icon.setAttribute("aria-hidden", "true");
  icon.textContent = ICONS[a.type] || "•";
  const p = document.createElement("p");
  const strong = document.createElement("strong");
  strong.textContent = `${TITLES[a.type] || "Note"}: `;
  p.append(strong, a.message);
  const ok = document.createElement("button");
  ok.type = "button"; ok.textContent = "OK";
  ok.setAttribute("aria-label", `Dismiss: ${TITLES[a.type] || "note"}`);
  ok.addEventListener("click", () => { li.remove(); updateEmpty(); });
  li.append(icon, p, ok);
  $("alerts").prepend(li);
  // "calmer" fades on its own; everything else stays until dismissed
  if (a.type === "noise_ok") setTimeout(() => { li.remove(); updateEmpty(); }, 10000);
  updateEmpty();
  if (a.type !== "noise_ok" && a.type !== "error") cueOutLoud(a);
}
function updateEmpty() { $("no-cues").hidden = $("alerts").children.length > 0; }

// sound
function pctOf(db) { return Math.min(100, Math.max(0, ((db - 30) / 70) * 100)); }

function renderNoise(n) {
  lastNoise = n;
  threshold = n.threshold_db;
  $("noise-db").textContent = n.avg_db.toFixed(0);
  $("noise-word").textContent = n.loud ? "Noisy" : "Calm";
  $("noise-status").dataset.loud = String(n.loud);
  $("meter").dataset.loud = String(n.loud);
  $("meter").setAttribute("aria-valuenow", n.avg_db.toFixed(0));
  $("meter").setAttribute("aria-valuetext", `${n.avg_db.toFixed(0)} decibels, ${n.loud ? "noisy" : "calm"}`);
  $("meter-bar").style.width = `${pctOf(n.avg_db)}%`;
  $("meter-limit").style.left = `${pctOf(n.threshold_db)}%`;
  $("text-summary").textContent = statusText();
  noiseHistory.push(n.avg_db);
  if (noiseHistory.length > HISTORY_SECONDS) noiseHistory.shift();
  drawSpark();
}

function drawSpark() {
  const c = $("spark"), ctx = c.getContext("2d");
  const css = getComputedStyle(document.documentElement);
  const w = c.width, h = c.height;
  const y = (db) => h - (pctOf(db) / 100) * h;
  ctx.clearRect(0, 0, w, h);
  ctx.setLineDash([6, 6]); ctx.strokeStyle = css.getPropertyValue("--muted"); ctx.lineWidth = 2;
  ctx.beginPath(); ctx.moveTo(0, y(threshold)); ctx.lineTo(w, y(threshold)); ctx.stroke();
  ctx.setLineDash([]); ctx.strokeStyle = css.getPropertyValue("--accent"); ctx.lineWidth = 3;
  ctx.beginPath();
  noiseHistory.forEach((db, i) => {
    const x = (i / (HISTORY_SECONDS - 1)) * w;
    i ? ctx.lineTo(x, y(db)) : ctx.moveTo(x, y(db));
  });
  ctx.stroke();
}

// settings
function loadSettings(s) {
  $("threshold").value = s.noise_threshold_db;
  $("threshold-out").value = Math.round(s.noise_threshold_db);
  $("warning").value = String(s.transition_warning_min);
  $("cooldown").value = String(s.alert_cooldown_s);
  $("noise-alerts").checked = s.noise_alerts;
}
$("threshold").addEventListener("input", (e) => { $("threshold-out").value = e.target.value; });
$("settings-form").addEventListener("submit", (e) => {
  e.preventDefault();
  send({
    cmd: "settings",
    noise_threshold_db: Number($("threshold").value),
    transition_warning_min: Number($("warning").value),
    alert_cooldown_s: Number($("cooldown").value),
    noise_alerts: $("noise-alerts").checked,
  });
  $("settings-saved").textContent = "Saved on this device.";
  setTimeout(() => { $("settings-saved").textContent = ""; }, 4000);
});

// focus record (opt-in, this browser only)
const RECORD_KEY = "focus-companion.record";
const DAY = 86400000;
let record = loadRecord();
let current = null;     // block in progress, kept in memory until it ends
let lastState = null;

function loadRecord() {
  try {
    const r = JSON.parse(localStorage.getItem(RECORD_KEY));
    if (r && Array.isArray(r.blocks)) return r;
  } catch { /* storage blocked or corrupted */ }
  return { enabled: false, keepDays: 30, blocks: [] };
}

function saveRecord() {
  record.blocks = record.blocks.filter((b) => Date.now() - b.start < record.keepDays * DAY);
  try {
    if (record.enabled || record.blocks.length) localStorage.setItem(RECORD_KEY, JSON.stringify(record));
    else localStorage.removeItem(RECORD_KEY);
  } catch { /* storage not available: keep working without a record */ }
  renderRecord();
}

function trackSession(t) {
  const active = t.state === "running" || t.state === "paused";
  if (active && (!current || lastState === "finished" || lastState === "idle")) {
    const elapsed = (t.duration_s - t.remaining_s) / (t.time_scale || 1);
    current = { start: Date.now() - elapsed * 1000, label: t.label,
                planned_min: Math.round(t.duration_s / 60), pauses: 0, noise_cues: 0 };
  }
  if (current) {
    if (lastState === "running" && t.state === "paused") current.pauses += 1;
    current.focused_min = Math.round((t.duration_s - t.remaining_s) / 60);
    if (!active && lastState && lastState !== t.state) {
      current.result = t.state === "finished" ? "finished" : "stopped early";
      if (record.enabled) { record.blocks.push(current); saveRecord(); }
      current = null;
    }
  }
  lastState = t.state;
}

function partOfDay(ts) {
  const h = new Date(ts).getHours();
  return h >= 5 && h < 12 ? "morning" : h < 18 ? "afternoon" : "evening";
}

function renderRecord() {
  $("rec-on").checked = record.enabled;
  $("rec-days").value = String(record.keepDays);
  const week = record.blocks.filter((b) => Date.now() - b.start < 7 * DAY);
  const done = week.filter((b) => b.result === "finished");
  const minutes = week.reduce((sum, b) => sum + (b.focused_min || 0), 0);
  const byPart = {};
  done.forEach((b) => { const p = partOfDay(b.start); byPart[p] = (byPart[p] || 0) + b.focused_min; });
  const best = Object.entries(byPart).sort((a, b) => b[1] - a[1])[0];

  const plural = (n, one, many) => (n === 1 ? one : many);
  const early = week.length - done.length;
  const stats = [[done.length, plural(done.length, "block finished", "blocks finished")],
                 [early, "stopped early"],
                 [minutes, plural(minutes, "minute focused", "minutes focused")]];
  if (done.length >= 3 && best) stats.push([best[0], "works best for you"]);
  $("rec-stats").replaceChildren(...stats.map(([value, text]) => {
    const li = document.createElement("li");
    const strong = document.createElement("strong");
    strong.textContent = value;
    li.append(strong, ` ${text}`);
    return li;
  }));

  const rows = record.blocks.slice(-10).reverse().map((b) => {
    const tr = document.createElement("tr");
    const when = new Date(b.start).toLocaleString([], { weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false });
    [when, b.label || "-", `${b.focused_min} of ${b.planned_min} min`, b.result].forEach((v) => {
      const td = document.createElement("td");
      td.textContent = v;
      tr.append(td);
    });
    return tr;
  });
  $("rec-table").tBodies[0].replaceChildren(...rows);
  $("rec-table").hidden = rows.length === 0;
  $("rec-empty").hidden = rows.length > 0;
  $("rec-empty").textContent = record.enabled ? "No blocks recorded yet." : "Recording is off.";
}

function note(text) {
  $("rec-msg").textContent = text;
  setTimeout(() => { $("rec-msg").textContent = ""; }, 5000);
}

$("rec-on").addEventListener("change", (e) => {
  record.enabled = e.target.checked;
  if (!record.enabled && record.blocks.length &&
      confirm("Recording is now off. Delete the blocks already saved too?")) {
    record.blocks = [];
  }
  saveRecord();
  note(record.enabled ? "Recording on. Saved only in this browser." : "Recording off.");
});
$("rec-days").addEventListener("change", (e) => {
  record.keepDays = Number(e.target.value);
  saveRecord();
});
$("rec-delete").addEventListener("click", () => {
  if (!confirm("Delete your whole focus record from this browser?")) return;
  record.blocks = [];
  saveRecord();
  note("Deleted.");
});
$("rec-export").addEventListener("click", () => {
  // prefix cells that a spreadsheet could read as a formula
  const cell = (v) => {
    let s = String(v ?? "");
    if (/^[=+\-@]/.test(s)) s = `'${s}`;
    return `"${s.replace(/"/g, '""')}"`;
  };
  const header = ["start", "task", "planned_min", "focused_min", "pauses", "noise_cues", "result"];
  const lines = record.blocks.map((b) => [new Date(b.start).toISOString(), b.label, b.planned_min,
    b.focused_min, b.pauses, b.noise_cues, b.result].map(cell).join(","));
  const blob = new Blob([[header.join(","), ...lines].join("\n")], { type: "text/csv" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "focus-record.csv";
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
});
saveRecord();

// view and sound preferences (only how the page looks, kept in this browser)
const PREFS_KEY = "focus-companion.prefs";
let prefs = { view: "standard", sound: "off" };
try { prefs = { ...prefs, ...JSON.parse(localStorage.getItem(PREFS_KEY)) }; } catch { /* defaults */ }

function applyPrefs() {
  document.body.dataset.view = prefs.view;
  const radio = document.querySelector(`input[name="view"][value="${prefs.view}"]`);
  if (radio) radio.checked = true;
  $("sound").value = prefs.sound;
  try { localStorage.setItem(PREFS_KEY, JSON.stringify(prefs)); } catch { /* not saved */ }
}
document.querySelectorAll('input[name="view"]').forEach((r) =>
  r.addEventListener("change", () => { prefs.view = r.value; applyPrefs(); }));
$("sound").addEventListener("change", (e) => {
  prefs.sound = e.target.value;
  applyPrefs();
  if (prefs.sound === "chime") chime("transition");
  if (prefs.sound === "voice") speak("Cues will be read aloud.");
});
$("btn-read").addEventListener("click", () => speak(statusText()));
applyPrefs();

function statusText() {
  const parts = [];
  const t = lastTimer;
  if (!t || t.state === "idle") parts.push("No focus block running.");
  else if (t.state === "finished") parts.push("Block finished. Time for a break.");
  else {
    const left = Math.ceil(t.remaining_s / 60);
    const total = Math.round(t.duration_s / 60);
    const task = t.label ? ` on ${t.label}` : "";
    parts.push(t.state === "paused" ? `Paused${task}. ${left} of ${total} minutes left.`
                                    : `Focusing${task}. ${left} of ${total} minutes left.`);
  }
  if (lastNoise) {
    parts.push(`The room is ${lastNoise.loud ? "noisy" : "calm"}, about ${Math.round(lastNoise.avg_db)} decibels. ` +
               `Your limit is ${Math.round(lastNoise.threshold_db)}.`);
  }
  return parts.join(" ");
}

let audioCtx = null;
function chime(type) {
  try {
    audioCtx = audioCtx || new AudioContext();
    const notes = type === "noise_high" ? [440, 392] : type === "session_end" ? [392, 523] : [523, 659];
    notes.forEach((freq, i) => {
      const osc = audioCtx.createOscillator();
      const gain = audioCtx.createGain();
      const start = audioCtx.currentTime + i * 0.35;
      osc.type = "sine";
      osc.frequency.value = freq;
      gain.gain.setValueAtTime(0, start);
      gain.gain.linearRampToValueAtTime(0.08, start + 0.05);   // quiet on purpose
      gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.6);
      osc.connect(gain).connect(audioCtx.destination);
      osc.start(start);
      osc.stop(start + 0.65);
    });
  } catch { /* no audio available */ }
}

function speak(text) {
  if (!("speechSynthesis" in window)) return;
  speechSynthesis.cancel();
  const u = new SpeechSynthesisUtterance(text);
  u.lang = "en";
  u.rate = 0.95;
  speechSynthesis.speak(u);
}

function cueOutLoud(a) {
  if (prefs.sound === "chime") chime(a.type);
  if (prefs.sound === "voice") speak(`${TITLES[a.type] || ""}. ${a.message}`);
}

// installable app (PWA); live data is never cached
if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});

// live link
function setLink(ok) {
  $("link").dataset.ok = String(ok);
  $("link-text").textContent = ok ? "Encrypted link to device (mutual TLS)" : "Device link down. Reconnecting…";
}
const events = new EventSource("/events");
events.addEventListener("timer", (e) => renderTimer(JSON.parse(e.data)));
events.addEventListener("noise", (e) => renderNoise(JSON.parse(e.data)));
events.addEventListener("alert", (e) => showAlert(JSON.parse(e.data)));
events.addEventListener("status", (e) => setLink(JSON.parse(e.data).mqtt));
events.onerror = () => setLink(false);
