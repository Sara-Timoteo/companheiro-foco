# STRIDE threat model

One page for Focus Companion (Hackathon for a Cause 2026). This note
builds on Sara Timóteo's design in the repository and on Diogo's
Wireshark capture of the running stack. It does not change that design.

## System and trust boundaries

Three containers on one machine, on two Docker networks: `focus-backend` (internal) and `focus-net` (for published services). Diogo's
capture saw three hosts on `172.18.0.x` (the Compose bridge), TLS
records of about 128 and 364 bytes, and a keepalive every 30 seconds.
That matches the MQTT keepalive set by the sensor and the dashboard.

Sara's controls, already on `main`:

- Mosquitto with mutual TLS on 8883 only, bound to `127.0.0.1`. There
  is no 1883 listener. `allow_anonymous false`, `require_certificate`,
  `use_identity_as_username`, and an ACL that lets the sensor publish
  readings and receive `focus/control`, and the dashboard do the inverse.
- The CA private key stays on the host (`certs/out/`, gitignored). The
  broker container receives only `ca.crt`, `server.crt` and `server.key`.
  Each app container mounts only its own client certificate and key.
- Broker persistence is off. The optional focus record is off by
  default and stays in this browser, with retention, export and delete.
- Containers run as the host user, with a read-only root filesystem,
  `cap_drop: [ALL]` and `no-new-privileges`.
- The dashboard is served over HTTPS on `https://localhost:8443`, with
  a CA that can only sign for localhost. The browser does not speak
  MQTT and never holds a broker key.

The microphone and the clock are simulated today. A real microphone
path must keep the same rule: only a dB value leaves the device.

## Table

| Component | Threat | Mitigation | Status |
| --- | --- | --- | --- |
| Broker | **S** Spoofing: a fake broker, or a client that claims to be the sensor or dashboard | Server certificate with SAN `mosquitto`, `localhost`, `127.0.0.1`; mutual TLS; CN becomes the MQTT username; anonymous clients refused | Done in Sara's design. Diogo's capture shows TLS, not plaintext MQTT |
| Broker | **T** Tampering: readings changed on the wire | MQTT over TLS on 8883. Captured records were TLS application data (about 128 and 364 bytes), not a readable JSON payload | Done. Confirmed by Diogo's capture |
| Broker | **R** Repudiation: no proof of who published a value | The connection presents a certificate whose CN becomes the username. There is no signed application audit log | Accepted residual for the hackathon |
| Broker | **I** Information disclosure: plaintext MQTT, payload logs, extra ports, leaked keys | No 1883 listener; no `log_type debug` or `all`; 8883 bound to loopback; CA key kept out of the container; keys not committed; each container mounts only its own key | Done in Sara's design |
| Broker | **D** Denial of service: flood the listener from the host or internet | Loopback bind; this change adds CPU, memory and PID limits. No MQTT-layer rate limit | Exposure is already limited; rate limit is a residual |
| Broker | **E** Elevation of privilege: publish or subscribe beyond role, or break out of the container | ACL per identity; non-root; `cap_drop: [ALL]`; read-only root; `no-new-privileges`. This change pins the image digest, adds tmpfs and cgroup limits, and puts the sensor only on the internal network | Done: digest pins, tmpfs, cgroup limits, sensor only on the internal network |
| Sensor | **S** Spoofing: impersonate the sensor | Client certificate `CN=sensor` required by the broker | Done |
| Sensor | **T** Tampering: alter published values in transit | Covered by broker TLS (see Diogo's capture) | Done for transit |
| Sensor | **I** Information disclosure: raw audio, identifiers, extra mounted secrets | Publishes an aggregate dB value, timer and cue events; no audio; no device id; mounts `ca.crt`, `sensor.crt` and `sensor.key` only | Done. A real microphone path must keep this rule |
| Sensor | **D** Denial of service: publish in a tight loop | Interval publish, gatekeeper cooldowns, and container resource limits added here | Done |
| Sensor | **E** Elevation of privilege: write `focus/control`, or reach the host | ACL denies the sensor write access to `focus/control`; the sensor has no internet egress and shares `focus-backend` only with the broker; the dashboard is on `focus-net` only, so the sensor cannot reach /api/control | Done |
| Dashboard | **S** Spoofing: impersonate the dashboard, or a browser that pretends to be a broker client | Dashboard client certificate `CN=dashboard`. The browser talks HTTPS to the dashboard only | Done |
| Dashboard | **T** Tampering: change values shown to the user, or inject script | Transit from the broker is TLS. The page sends same-origin JSON, uses a command allow-list, and a Content Security Policy | Done in Sara's design |
| Dashboard | **I** Information disclosure: UI reachable beyond this machine, or broker opened to the browser | Bind `127.0.0.1:8443`; HTTPS with a localhost-only CA; browser has no MQTT credentials | Done in Sara's design |
| Dashboard | **D** Denial of service: request flood against the UI | Published only on loopback; container resource limits added here | Done |
| Dashboard | **E** Elevation of privilege: dashboard forges sensor readings, or container breakout | ACL denies dashboard write access to sensor topics; non-root; read-only root; `cap_drop: [ALL]` | Done |
| Data at rest | **I** Stored sensory data (ADHD-sensitive) or secrets in git | Broker persistence is off. The focus record stays in this browser, off by default. `.gitignore` covers `certs/out`, keys and `.env` | Done in Sara's design |
| Data at rest | **T** Tampering with stored history | No server-side store. Browser storage is under the person's control | Residual: a local user of the same browser profile can edit it |
| Data at rest | **D** Disk fill from persistence | Broker persistence off; browser record has a retention cap | Done |

keepalive of 30 seconds, seen in the capture, is the MQTT keepalive in
`sensor/focus_device.py` and `dashboard/server.py`. It is a liveness
check, not stored history.
