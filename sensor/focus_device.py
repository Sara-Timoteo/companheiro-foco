"""Focus Companion - device simulator.

Plays the role of the future hardware (Raspberry Pi + dimmable LED + noise sensor).
Structure mirrors a FreeRTOS design: sensor -> analyzer (threshold) -> gatekeeper (alerts),
plus a focus-timer task. Commands arrive through a queue from the MQTT thread.

Privacy: only aggregated noise levels (dB) leave the device. No audio is recorded,
stored or transmitted. The person sets every threshold.
"""
import json
import logging
import os
import queue
import random
import time
from dataclasses import asdict, dataclass

log = logging.getLogger("focus-device")


def clamp(value, low, high):
    return max(low, min(high, value))


@dataclass
class Settings:
    noise_threshold_db: float = 65.0   # user-defined: what counts as "too noisy"
    noise_sustain_s: int = 8           # noise must last this long before an alert
    noise_alerts: bool = True          # the person can switch noise alerts off
    alert_cooldown_s: int = 90         # never nag: at most one noise alert per cooldown
    transition_warning_min: int = 5    # "X minutes left" cue (0 = off)


LIMITS = {
    "noise_threshold_db": (35, 95),
    "noise_sustain_s": (2, 60),
    "alert_cooldown_s": (10, 900),
    "transition_warning_min": (0, 30),
}


class NoiseSource:
    """Simulated sound level in dB. A real device would compute this locally from a mic."""

    def __init__(self, base_db=42.0, rng=None):
        self.base_db = base_db
        self.rng = rng or random.Random()
        self.spike_until = 0.0
        self.spike_db = 72.0

    def spike(self, now, seconds=30, db=72.0):
        self.spike_until = now + seconds
        self.spike_db = db

    def sample(self, now):
        target = self.spike_db if now < self.spike_until else self.base_db
        level = target + self.rng.gauss(0, 2.0)
        if self.rng.random() < 0.02:  # occasional short bang (door, dog, dropped mug)
            level = max(level, 78 + self.rng.gauss(0, 3))
        return round(clamp(level, 25, 100), 1)


class Analyzer:
    """Smooths readings and reports only *sustained* noise, so a single bang never interrupts."""

    HYSTERESIS_DB = 3.0
    ALPHA = 0.3

    def __init__(self, settings):
        self.s = settings
        self.avg = None
        self.above_since = None
        self.loud = False

    def update(self, db, now):
        self.avg = db if self.avg is None else self.ALPHA * db + (1 - self.ALPHA) * self.avg
        events = []
        if self.avg >= self.s.noise_threshold_db:
            if self.above_since is None:
                self.above_since = now
            if not self.loud and now - self.above_since >= self.s.noise_sustain_s:
                self.loud = True
                events.append("noise_high")
        else:
            self.above_since = None
            if self.loud and self.avg < self.s.noise_threshold_db - self.HYSTERESIS_DB:
                self.loud = False
                events.append("noise_ok")
        return events


class FocusTimer:
    """Focus block in (optionally accelerated) time. TIME_SCALE > 1 is for demos only."""

    def __init__(self, time_scale=1.0):
        self.time_scale = time_scale
        self.state = "idle"        # idle | running | paused | finished
        self.label = ""
        self.duration_s = 0
        self.remaining_s = 0.0
        self.warned = False

    def start(self, minutes, label):
        self.state, self.label = "running", label
        self.duration_s = int(minutes * 60)
        self.remaining_s = float(self.duration_s)
        self.warned = False

    def tick(self, dt, settings):
        if self.state != "running":
            return []
        self.remaining_s = max(0.0, self.remaining_s - dt * self.time_scale)
        events = []
        warn_s = settings.transition_warning_min * 60
        if (not self.warned and warn_s > 0 and self.duration_s > warn_s
                and 0 < self.remaining_s <= warn_s):
            self.warned = True
            events.append("transition")
        if self.remaining_s == 0:
            self.state = "finished"
            events.append("session_end")
        return events


MESSAGES = {
    "noise_high": "It's getting noisy around you. Headphones or a quieter spot might help.",
    "noise_ok": "Calmer now.",
    "transition": "{minutes} minutes left. A good moment to look for a stopping point.",
    "session_end": "Focus block done. Take a short break before the next thing.",
}


class Gatekeeper:
    """Single point that decides which alerts reach the person (FreeRTOS gatekeeper pattern)."""

    def __init__(self, settings, publish):
        self.s = settings
        self.publish = publish
        self.last_noise_alert = float("-inf")
        self.noise_alert_shown = False

    def submit(self, kind, now, **context):
        if kind == "noise_high":
            if not self.s.noise_alerts or now - self.last_noise_alert < self.s.alert_cooldown_s:
                return False
            self.last_noise_alert = now
            self.noise_alert_shown = True
        elif kind == "noise_ok":
            if not self.noise_alert_shown:
                return False
            self.noise_alert_shown = False
        self.publish("focus/alert", {
            "type": kind,
            "message": MESSAGES[kind].format(**context),
            "ts": time.time(),
        })
        return True


class Device:
    def __init__(self, publish, time_scale=1.0, rng=None):
        self.publish = publish
        self.settings = Settings()
        self.noise = NoiseSource(rng=rng)
        self.analyzer = Analyzer(self.settings)
        self.timer = FocusTimer(time_scale)
        self.gatekeeper = Gatekeeper(self.settings, publish)

    def handle(self, cmd, now):
        """Apply a command from focus/control. Everything is validated and clamped."""
        try:
            kind = cmd.get("cmd")
            if kind == "start":
                minutes = clamp(int(cmd.get("minutes", 25)), 1, 180)
                label = str(cmd.get("label", ""))[:80]
                self.timer.start(minutes, label)
            elif kind == "pause" and self.timer.state == "running":
                self.timer.state = "paused"
            elif kind == "resume" and self.timer.state == "paused":
                self.timer.state = "running"
            elif kind == "stop":
                self.timer.state = "idle"
            elif kind == "settings":
                for key, (low, high) in LIMITS.items():
                    if key in cmd:
                        cast = type(getattr(self.settings, key))
                        setattr(self.settings, key, cast(clamp(float(cmd[key]), low, high)))
                if isinstance(cmd.get("noise_alerts"), bool):
                    self.settings.noise_alerts = cmd["noise_alerts"]
            elif kind == "simulate" and cmd.get("event") == "noise_spike":
                self.noise.spike(now, seconds=clamp(int(cmd.get("seconds", 30)), 1, 300))
            else:
                log.warning("Ignored command: %r", cmd)
                return
            log.info("Command applied: %s", kind)
        except (TypeError, ValueError, AttributeError) as exc:
            log.warning("Invalid command %r: %s", cmd, exc)
        self.publish_state()

    def publish_state(self):
        t = self.timer
        self.publish("focus/timer", {
            "state": t.state,
            "label": t.label,
            "duration_s": t.duration_s,
            "remaining_s": round(t.remaining_s, 1),
            "fraction_remaining": round(t.remaining_s / t.duration_s, 4) if t.duration_s else 0,
            "time_scale": t.time_scale,
            "settings": asdict(self.settings),
            "ts": time.time(),
        }, retain=True)

    def tick(self, now, dt):
        db = self.noise.sample(now)
        for event in self.analyzer.update(db, now):
            self.gatekeeper.submit(event, now)
        for event in self.timer.tick(dt, self.settings):
            self.gatekeeper.submit(event, now, minutes=self.settings.transition_warning_min)
        self.publish("focus/noise", {
            "db": db,
            "avg_db": round(self.analyzer.avg, 1),
            "threshold_db": self.settings.noise_threshold_db,
            "loud": self.analyzer.loud,
            "ts": time.time(),
        })
        self.publish_state()


def main():
    import paho.mqtt.client as mqtt

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    host = os.getenv("MQTT_HOST", "mosquitto")
    port = int(os.getenv("MQTT_PORT", "8883"))
    time_scale = float(os.getenv("TIME_SCALE", "1"))
    commands = queue.Queue()

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="focus-sensor")
    client.tls_set(ca_certs=os.getenv("MQTT_CA", "/certs/ca.crt"),
                   certfile=os.getenv("MQTT_CERT", "/certs/client.crt"),
                   keyfile=os.getenv("MQTT_KEY", "/certs/client.key"))

    def on_connect(c, userdata, flags, reason_code, properties):
        log.info("Connected to %s:%s over mutual TLS (%s)", host, port, reason_code)
        c.subscribe("focus/control", qos=1)

    def on_message(c, userdata, msg):
        try:
            payload = json.loads(msg.payload)
            if isinstance(payload, dict):
                commands.put(payload)
        except ValueError:
            log.warning("Dropped non-JSON command")

    client.on_connect = on_connect
    client.on_message = on_message

    def publish(topic, payload, retain=False):
        client.publish(topic, json.dumps(payload), qos=1 if topic != "focus/noise" else 0,
                       retain=retain)

    while True:
        try:
            client.connect(host, port, keepalive=30)
            break
        except OSError as exc:
            log.warning("Broker not reachable yet (%s); retrying in 3 s", exc)
            time.sleep(3)
    client.loop_start()

    device = Device(publish, time_scale=time_scale)
    log.info("Device simulator running (time scale x%s)", time_scale)
    last = time.monotonic()
    while True:
        time.sleep(1)
        now = time.monotonic()
        while not commands.empty():
            device.handle(commands.get_nowait(), now)
        device.tick(now, now - last)
        last = now


if __name__ == "__main__":
    main()
