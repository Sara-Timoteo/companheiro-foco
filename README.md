# Focus Companion

A local, private focus companion for adults with ADHD.
Built for Hackathon for a Cause 2026, Brainstorm challenge (Portuguese ADHD Association).

It helps with three things that often get in the way:

- **Time blindness:** a light that drains as the focus block passes.
- **Hard transitions:** a gentle "5 minutes left" cue, and a body-break reminder after a long
  stretch of focus (hyperfocus), with a "Later (10 min)" option.
- **Sensory overload:** a cue when the room stays too loud for a while. A single bang is ignored on purpose.

The person sets every limit. Nothing leaves the computer.

## What works today

- Mosquitto broker with mutual TLS only (port 8883, bound to localhost), one certificate per service and an ACL.
- Device simulator (Python): noise level, focus timer, transition and body-break cues, and a gatekeeper
  that limits how often cues appear.
- Noise analyzer in portable C (fixed point, no heap). Unit-tested during `docker build` and used by the simulator.
- Accessible dashboard: visual timer, gentle cues, Standard / Calm / Text-only views, light and dark themes,
  cues read aloud, installable as an app (PWA).
- Optional focus record, off by default, kept only in the browser, with retention, CSV export and "delete everything".

## Simulated or not built yet

- The microphone and the clock are simulated. `TIME_SCALE=10` speeds time up for demos, and the dashboard
  shows a "Demo mode" badge when it does.
- Hardware: Raspberry Pi with a dimmable LED and a microphone, ESP32 sensor node (see `firmware/`).
- Phone app, watch vibration, sync between devices.

## Run it

Needs Docker Engine with Compose v2 (Linux or WSL2) and OpenSSL.

```bash
git clone https://github.com/Sara-Timoteo/companheiro-foco.git
cd companheiro-foco
./certs/gen-certs.sh        # private CA, server and client certificates in certs/out (git-ignored)
./certs/gen-web-cert.sh     # localhost-only CA and the dashboard's HTTPS certificate
printf 'HOST_UID=%s\nHOST_GID=%s\nTIME_SCALE=10\n' "$(id -u)" "$(id -g)" > .env
docker compose up -d --build
```

Open https://localhost:8443, start a block, and try the "Demo tools" panel.

## Tests

- `./scripts/broker-smoke-test.sh`: mutual TLS and ACL (4 checks, about 30 s).
- `make -C firmware/common`: C unit tests (they also run inside `docker build`).

## Settings (`.env`)

- `HOST_UID`, `HOST_GID`: user the containers run as. It must own `certs/out`.
- `TIME_SCALE`: `1` for real time, `10` for demos.
- `DASHBOARD_PORT`: dashboard port on localhost, `8443` by default. Change it if that port is taken on your machine.

## HTTPS without browser warnings

`gen-web-cert.sh` creates a second CA that can only sign certificates for `localhost` and `127.0.0.1`
(X.509 name constraints), so trusting it cannot be abused for any other site. On Windows, copy
`certs/out/web-ca.crt` to Downloads and run in PowerShell:

```powershell
certutil -user -addstore Root $env:USERPROFILE\Downloads\web-ca.crt
```

Remove it with `certutil -user -delstore Root "Focus Companion localhost-only CA"`.

## Layout

- `mosquitto/`: broker config and ACL
- `sensor/`: device simulator
- `firmware/`: C noise analyzer and its tests, base for the ESP32 node
- `dashboard/`: web backend (server-sent events + control API) and the accessible UI
- `certs/`: script that creates the CA and certificates
- `scripts/`: broker smoke test
- `docs/STRIDE.md`: one-page threat model, building on the current design and traffic capture
- `docs/scaling.md`: how the same local design could grow to a school or support centre

## Privacy and security

- No audio is recorded. Only sound levels in dB leave the sensor.
- Broker: mutual TLS only, no anonymous clients, ACL per identity, nothing stored on disk.
- Containers: non-root, read-only filesystem, no Linux capabilities, `no-new-privileges`, ports bound to 127.0.0.1.
- Browser link: HTTPS (TLS 1.2 or newer) with a certificate from a CA that can only sign for localhost.
- Dashboard: same-origin JSON only, command allow-list, Content Security Policy, no cookies.
  CSV export escapes cells that a spreadsheet could read as formulas.

## Team

Sara Timóteo (code), Diogo (cybersec) and Guilherme (infrastructure and code).
