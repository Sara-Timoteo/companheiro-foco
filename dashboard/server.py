# Dashboard backend: MQTT (mTLS, "dashboard" identity) <-> browser.
#   GET  /            static UI
#   GET  /events      server-sent events (noise, timer, alert, status)
#   POST /api/control commands, checked and forwarded to focus/control
# Nothing is written to disk. Only the last timer/noise message is kept in memory.

import json
import logging
import os
import queue
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import paho.mqtt.client as mqtt

log = logging.getLogger("focus-dashboard")

STATIC_DIR = Path(__file__).parent / "static"
STATIC_FILES = {"/": "index.html", "/index.html": "index.html",
                "/app.js": "app.js", "/style.css": "style.css", "/sw.js": "sw.js",
                "/manifest.webmanifest": "manifest.webmanifest", "/icon.svg": "icon.svg"}
CONTENT_TYPES = {".html": "text/html; charset=utf-8",
                 ".js": "text/javascript; charset=utf-8",
                 ".css": "text/css; charset=utf-8",
                 ".webmanifest": "application/manifest+json",
                 ".svg": "image/svg+xml"}
SECURITY_HEADERS = {
    "Content-Security-Policy": "default-src 'self'; frame-ancestors 'none'; "
                               "base-uri 'none'; form-action 'self'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
}
SUBSCRIPTIONS = ("focus/noise", "focus/timer", "focus/alert")
# command -> allowed fields
ALLOWED_COMMANDS = {
    "start": {"minutes", "label"},
    "pause": set(),
    "resume": set(),
    "stop": set(),
    "snooze_break": set(),
    "settings": {"noise_threshold_db", "noise_sustain_s", "noise_alerts",
                 "alert_cooldown_s", "transition_warning_min", "break_reminder_min"},
    "simulate": {"event", "seconds"},
}
MAX_BODY = 2048


class Hub:
    def __init__(self):
        self.lock = threading.Lock()
        self.clients = set()
        self.latest = {}

    def subscribe(self):
        q = queue.Queue(maxsize=200)
        with self.lock:
            self.clients.add(q)
            snapshot = list(self.latest.values())
        return q, snapshot

    def unsubscribe(self, q):
        with self.lock:
            self.clients.discard(q)

    def broadcast(self, name, payload):
        event = (name, payload)
        with self.lock:
            if name != "alert":  # alerts are not replayed
                self.latest[name] = event
            for q in self.clients:
                try:
                    q.put_nowait(event)
                except queue.Full:
                    pass


hub = Hub()
mqtt_client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="focus-dashboard")


class Handler(BaseHTTPRequestHandler):
    server_version = "FocusCompanion"
    sys_version = ""

    def log_message(self, fmt, *args):  # keep client IPs out of the logs
        log.debug("%s %s", self.command, self.path)

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/events":
            return self.stream_events()
        if path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return
        name = STATIC_FILES.get(path)
        if not name:
            return self.send_json(404, {"error": "not found"})
        data = (STATIC_DIR / name).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", CONTENT_TYPES[Path(name).suffix])
        self.send_header("Content-Length", str(len(data)))
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def stream_events(self):
        q, snapshot = hub.subscribe()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.write_event("status", {"mqtt": mqtt_client.is_connected()})
            for name, payload in snapshot:
                self.write_event(name, payload)
            while True:
                try:
                    name, payload = q.get(timeout=15)
                    self.write_event(name, payload)
                except queue.Empty:
                    self.wfile.write(b": keep-alive\n\n")
                    self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            hub.unsubscribe(q)

    def write_event(self, name, payload):
        self.wfile.write(f"event: {name}\ndata: {json.dumps(payload)}\n\n".encode())
        self.wfile.flush()

    def do_POST(self):
        if self.path != "/api/control":
            return self.send_json(404, {"error": "not found"})
        # same-origin JSON only (CSRF)
        origin = self.headers.get("Origin")
        if origin and origin.split("://", 1)[-1] != self.headers.get("Host"):
            return self.send_json(403, {"error": "cross-origin request refused"})
        if not self.headers.get("Content-Type", "").startswith("application/json"):
            return self.send_json(415, {"error": "JSON only"})
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            return self.send_json(413, {"error": "body too large or empty"})
        try:
            body = json.loads(self.rfile.read(length))
            allowed = ALLOWED_COMMANDS[body["cmd"]]
        except (ValueError, KeyError, TypeError):
            return self.send_json(400, {"error": "unknown command"})
        command = {"cmd": body["cmd"], **{k: v for k, v in body.items() if k in allowed}}
        if not mqtt_client.is_connected():
            return self.send_json(503, {"error": "device link down"})
        mqtt_client.publish("focus/control", json.dumps(command), qos=1)
        return self.send_json(202, {"ok": True})


def run_mqtt(host, port):
    def on_connect(c, userdata, flags, reason_code, properties):
        log.info("Connected to %s:%s over mutual TLS (%s)", host, port, reason_code)
        for topic in SUBSCRIPTIONS:
            c.subscribe(topic, qos=1)
        hub.broadcast("status", {"mqtt": True})

    def on_disconnect(c, userdata, flags, reason_code, properties):
        log.warning("Disconnected from broker (%s)", reason_code)
        hub.broadcast("status", {"mqtt": False})

    def on_message(c, userdata, msg):
        try:
            hub.broadcast(msg.topic.split("/", 1)[1], json.loads(msg.payload))
        except ValueError:
            log.warning("Dropped non-JSON message on %s", msg.topic)

    mqtt_client.tls_set(ca_certs=os.getenv("MQTT_CA", "/certs/ca.crt"),
                        certfile=os.getenv("MQTT_CERT", "/certs/client.crt"),
                        keyfile=os.getenv("MQTT_KEY", "/certs/client.key"))
    mqtt_client.on_connect = on_connect
    mqtt_client.on_disconnect = on_disconnect
    mqtt_client.on_message = on_message
    while True:
        try:
            mqtt_client.connect(host, port, keepalive=30)
            break
        except OSError as exc:
            log.warning("Broker not reachable yet (%s); retrying in 3 s", exc)
            time.sleep(3)
    mqtt_client.loop_forever()


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    host = os.getenv("MQTT_HOST", "mosquitto")
    port = int(os.getenv("MQTT_PORT", "8883"))
    threading.Thread(target=run_mqtt, args=(host, port), daemon=True).start()
    http_port = int(os.getenv("HTTP_PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", http_port), Handler)
    server.daemon_threads = True
    scheme = "http"
    cert, key = os.getenv("WEB_CERT"), os.getenv("WEB_KEY")
    if cert and key and os.path.exists(cert):
        ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(cert, key)
        # handshake in the request thread, so a slow client cannot block new connections
        server.socket = ctx.wrap_socket(server.socket, server_side=True,
                                        do_handshake_on_connect=False)
        scheme = "https"
    log.info("Dashboard on %s://localhost:%s", scheme, http_port)
    server.serve_forever()


if __name__ == "__main__":
    main()
