# Scaling from one home to a school or support centre

Focus Companion is built as a local stack on one machine: one broker,
one device identity, one dashboard, and no cloud. That is the right
shape for a single home. This note sketches how the same design can
grow to a school or a support centre without sending sensory data off
site.

## Keep a broker at each site

Each home, classroom or centre runs its own broker on the local
network. Devices and the dashboard at that site talk only to that
broker. There is no shared cloud broker and no telemetry uplink. If
two sites need to compare notes, people export a record they chose to
keep, rather than streaming live noise or focus data through a third
party.

## One certificate per device

Mutual TLS already treats the certificate CN as the MQTT username.
At a larger site, issue a distinct client certificate for every
physical device and every dashboard instance, still from the site's
own CA. The CA key stays on the site, off the devices, the same way
`certs/out/ca.key` never enters a container today. Lost or replaced
hardware does not revoke that certificate today: there is no crlfile
or OCSP, so a stolen cert stays valid until it expires (90 days)
unless a CRL is added and crlfile is set. Rotating a shared password
is still avoided, because each device has its own certificate.

## ACL per room

The current ACL is two identities (sensor and dashboard) and four
topics (`focus/noise`, `focus/timer`, `focus/alert`, `focus/control`).
In a centre, give each room or group a topic prefix, for example
`room-3/focus/#`, and grant each device write access only inside its
prefix. A dashboard used in that room gets read access to the same
prefix, and write access only to that room's `focus/control`. A
corridor display can be read-only. Staff in room 3 should not see or
steer room 4.

## What stays the same

- No audio leaves the device: only an aggregate dB value, timer and
  cue events.
- History stays optional, local, and off by default.
- Ports that must be published stay on the site's own machines, not on
  the public internet.
- The person, or the site, still sets every threshold and can switch
  cues off.

A multi-site product would also need certificate issuance, revocation
and a way to name rooms. Those are operational steps around this
stack, not a reason to move the broker into the cloud.
