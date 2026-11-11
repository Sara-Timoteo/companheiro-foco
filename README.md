# Focus Companion (Companheiro de Foco)

A local-first, private focus companion for adults with ADHD.
Hackathon for a Cause 2026 · Brainstorm challenge (Portuguese ADHD Association).

- **Visual timer**: the light drains as time passes (time blindness)
- **Gentle transition cues**: "5 minutes left" (task switching)
- **Noise alert**: user-defined thresholds (sensory overload)
- **Privacy by design**: everything runs locally, MQTT over mutual TLS (8883), no cloud

## Structure
- `mosquitto/`: MQTT broker with mutual TLS
- `sensor/`: Python simulator (noise + focus time)
- `dashboard/`: accessible web dashboard (WCAG; colour is never the only signal)
- `certs/`: script to generate the CA and certificates (keys are never committed)
- `docs/`: threat model, pitch, notes
