#!/usr/bin/env bash
# Broker smoke test: mutual TLS + ACL. Run it while the stack is up.
set -uo pipefail
cd "$(dirname "$0")/.."

IMG=eclipse-mosquitto:2
CERTS="$PWD/certs/out"
pass=0; fail=0

# Run an MQTT client in a throwaway container as a given identity (sensor|dashboard|none).
mqtt() {
  local who=$1; shift
  local mounts=(-v "$CERTS/ca.crt:/c/ca.crt:ro") auth=()
  if [[ $who != none ]]; then
    mounts+=(-v "$CERTS/$who.crt:/c/id.crt:ro" -v "$CERTS/$who.key:/c/id.key:ro")
    auth=(--cert /c/id.crt --key /c/id.key)
  fi
  timeout 20 docker run --rm --network focus-net --user "$(id -u):$(id -g)" "${mounts[@]}" "$IMG" \
    "$@" -h mosquitto -p 8883 --cafile /c/ca.crt "${auth[@]}"
}

check() {
  if [[ $1 -eq 0 ]]; then echo "PASS  $2"; pass=$((pass+1)); else echo "FAIL  $2"; fail=$((fail+1)); fi
}

# Returns 0 if a message published by $1 on topic $3 reaches subscriber $2.
delivered() {
  local pub=$1 sub=$2 topic=$3 msg="smoke-$RANDOM" out
  out=$(mktemp)
  mqtt "$sub" mosquitto_sub -t "$topic" -C 1 -W 8 > "$out" 2>/dev/null &
  local pid=$!
  sleep 3
  mqtt "$pub" mosquitto_pub -t "$topic" -m "$msg" -q 1 >/dev/null 2>&1
  wait "$pid"
  grep -qx "$msg" "$out"; local r=$?
  rm -f "$out"; return $r
}

echo "Running broker smoke tests (about 30 s)..."

delivered sensor dashboard focus/noise
check $? "sensor publishes noise readings; dashboard receives them"

delivered dashboard sensor focus/control
check $? "dashboard sends control commands; sensor receives them"

mqtt none mosquitto_pub -t focus/noise -m intruder >/dev/null 2>&1
[[ $? -ne 0 ]]; check $? "client without a certificate is rejected (mutual TLS)"

delivered sensor sensor focus/control
[[ $? -ne 0 ]]; check $? "sensor cannot forge control commands (ACL)"

echo "$pass passed, $fail failed"
exit "$fail"
