#!/usr/bin/env bash
# Trockenlauf von server-config-files (Full-Deploy-Skript aus deploy-hetzner.yml) gegen ein
# temporäres Verzeichnis mit Attrappen für docker, flock, sha256sum und chmod/chown --reference
# (läuft auf macOS und Linux). Es wird kein Deploy ausgelöst.
#
# Aufruf: tests/test-server-config.sh [workflow.yml]   (Standard: .github/workflows/deploy-hetzner.yml)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="${1:-$HERE/../.github/workflows/deploy-hetzner.yml}"
EXTRACT="$HERE/extract-step.rb"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sc-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok    $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FEHLT $1"; }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (erwartet '$2', erhalten '$3')"; fi; }

BIN="$WORK/bin"; mkdir -p "$BIN"
if ! command -v sha256sum >/dev/null 2>&1; then
  printf '#!/bin/bash\nexec shasum -a 256 "$@"\n' > "$BIN/sha256sum"
fi
cat > "$BIN/chmod" <<'FAKE'
#!/bin/bash
if [[ "$1" == --reference=* ]]; then ref="${1#--reference=}"; m=$(stat -c %a "$ref" 2>/dev/null || stat -f %Lp "$ref"); exec "$REAL_CHMOD" "$m" "$2"; fi
exec "$REAL_CHMOD" "$@"
FAKE
cat > "$BIN/chown" <<'FAKE'
#!/bin/bash
if [[ "$1" == --reference=* ]]; then exit 0; fi
exec "$REAL_CHOWN" "$@"
FAKE
cat > "$BIN/flock" <<'FAKE'
#!/bin/bash
# Attrappe: ohne echte Sperre (die Sperre prüft test-quick-deploy.sh), führt den Befehl aus
[ "$1" = "-w" ] && shift 2
shift
exec "$@"
FAKE
cat > "$BIN/timeout" <<'FAKE'
#!/bin/bash
shift; exec "$@"
FAKE
cat > "$BIN/docker" <<'FAKE'
#!/bin/bash
echo "docker $*" >> "$FAKE_LOG"
case "$1 $2" in
  "compose config") [ "${FAKE_FAIL:-}" = "config" ] && exit 1; printf 'app\nnginx\n'; exit 0 ;;
  "compose pull") [ "${FAKE_FAIL:-}" = "pull" ] && exit 1; exit 0 ;;
  "compose up")
    [ "${FAKE_FAIL:-}" = "up" ] && exit 1
    [ -n "${FAKE_UP_CLOBBER:-}" ] && echo "von compose verändert" > "$FAKE_UP_CLOBBER"
    exit 0 ;;
esac
if [ "$1" = "inspect" ]; then
  case "$*" in *State.Running*) [ "${FAKE_NGINX_DOWN:-}" = "1" ] && echo false || echo true ;; *) printf '%s\n' "${FAKE_LABEL-}" ;; esac
  exit 0
fi
if [ "$1" = "exec" ]; then
  case "$*" in
    *"nginx -t"*) [ "${FAKE_NGINX_T_FAIL:-}" = "1" ] && { echo "nginx: [emerg] simuliert" >&2; exit 1; }; exit 0 ;;
    *sha256sum*) echo "${FAKE_NGINX_HASH:-0}  /etc/nginx/nginx.conf"; exit 0 ;;
  esac
fi
exit 0
FAKE
REAL_CHMOD="$(command -v chmod)"; REAL_CHOWN="$(command -v chown)"
chmod +x "$BIN"/*
export REAL_CHMOD REAL_CHOWN

hash_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

setup() { # -> $SRV (deploy-path), $STG (Staging am Ziel), alte Dateien am Ziel, neue im Staging
  SRV="$WORK/srv"; STG="$WORK/stage"
  rm -rf "$SRV" "$STG"; mkdir -p "$SRV" "$STG"
  printf 'compose alt\n' > "$SRV/docker-compose.yml"; chmod 600 "$SRV/docker-compose.yml"
  printf 'nginx alt\n' > "$SRV/nginx.conf"
  printf 'compose neu\n' > "$STG/docker-compose.yml"
  printf 'nginx neu\n' > "$STG/nginx.conf"
  HC=$(hash_of "$STG/docker-compose.yml"); HN=$(hash_of "$STG/nginx.conf")
  : > "$WORK/fake.log"
}
run_full() { # extra-env... (Namen=Wert) -> Exit-Code des Deploy-Skripts; Ausgabe in $WORK/full.out
  INPUT_DEPLOY_PATH="$SRV" INPUT_APP_CONTAINER=app INPUT_STATEFUL_SERVICES="" GITHUB_SHA_VALUE="" \
    INPUT_NGINX_CONFIG_CONTAINER="${NGINX_CONTAINER-nickheymann-nginx}" INPUT_NGINX_CONFIG_FILE="${NGINX_FILE-nginx.conf}" \
    NEEDS_CONFIG_HASHES="docker-compose.yml=$HC,nginx.conf=$HN" CFG_STAGE_VALUE="$STG" \
    "$EXTRACT" "$WF" full-deploy "Deploy to Hetzner" --key script > "$WORK/full.sh"
  env "$@" PATH="$BIN:$PATH" FAKE_LOG="$WORK/fake.log" GHCR_TOKEN=x EXPECTED_BASE="" bash "$WORK/full.sh" > "$WORK/full.out" 2>&1
}
content() { cat "$SRV/docker-compose.yml" "$SRV/nginx.conf" | tr '\n' '|'; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

echo "== Erfolg: einspielen, sichern, Modus erhalten, verifizieren"
setup
run_full FAKE_NGINX_HASH="$HN" FAKE_LABEL=1111111111111111111111111111111111111111; RC=$?
expect "Exit 0" "0" "$RC"
expect "Dateien am Ziel sind die neuen" "compose neu|nginx neu|" "$(content)"
expect "Modus der bisherigen Datei erhalten" "600" "$(mode_of "$SRV/docker-compose.yml")"
expect "Sicherung der alten Compose-Datei mit Zeitstempel" "compose alt" "$(cat "$SRV"/docker-compose.yml.bak-*-deploy)"
expect "compose up lief nach dem Einspielen" "1" "$(grep -c '^docker compose up' "$WORK/fake.log" | head -1 | awk '{print ($1>0)}')"
grep -q 'alle Dateien am Ziel entsprechen dem Commit' "$WORK/full.out" && ok "Verifikation meldet Übereinstimmung" || fail "keine Verifikationsmeldung"
grep -q 'nginx -t -c /tmp/nginx-deploy-test.conf' "$WORK/fake.log" && ok "nginx -t vor dem Einspielen" || fail "kein nginx -t vor dem Einspielen"

echo "== Unveränderte Dateien: keine Sicherung, kein nginx -t"
setup; cp "$STG/docker-compose.yml" "$SRV/docker-compose.yml"; cp "$STG/nginx.conf" "$SRV/nginx.conf"
run_full FAKE_NGINX_HASH="$HN" FAKE_LABEL=1111111111111111111111111111111111111111; RC=$?
expect "Exit 0" "0" "$RC"
expect "keine Sicherung angelegt" "0" "$(find "$SRV" -name '*.bak-*' | wc -l | tr -d ' ')"
grep -q 'nginx-deploy-test.conf' "$WORK/fake.log" && fail "nginx -t trotz unveränderter Datei" || ok "kein nginx -t bei unveränderter Datei"

echo "== nginx -t schlägt fehl: nichts verändert, kein compose pull"
setup
run_full FAKE_NGINX_T_FAIL=1; RC=$?
[ "$RC" -ne 0 ] && ok "Lauf rot" || fail "Lauf nicht rot"
expect "Dateien unverändert" "compose alt|nginx alt|" "$(content)"
expect "kein compose pull" "0" "$(grep -c '^docker compose pull' "$WORK/fake.log")"

echo "== nginx-Container läuft nicht: nichts verändert"
setup
run_full FAKE_NGINX_DOWN=1; RC=$?
[ "$RC" -ne 0 ] && ok "Lauf rot" || fail "Lauf nicht rot"
expect "Dateien unverändert" "compose alt|nginx alt|" "$(content)"

echo "== Fehler nach dem Einspielen, vor compose up: Rückrollen"
for step in pull config; do
  setup
  run_full FAKE_FAIL="$step"; RC=$?
  [ "$RC" -ne 0 ] && ok "$step scheitert: Lauf rot" || fail "$step scheitert: Lauf nicht rot"
  expect "$step scheitert: Dateien zurückgerollt" "compose alt|nginx alt|" "$(content)"
  expect "$step scheitert: Modus zurückgerollt" "600" "$(mode_of "$SRV/docker-compose.yml")"
done

echo "== Fehler von compose up: neue Dateien bleiben (Container laufen mit ihnen), Lauf rot"
setup
run_full FAKE_FAIL=up; RC=$?
[ "$RC" -ne 0 ] && ok "Lauf rot" || fail "Lauf nicht rot"
expect "Dateien bleiben die neuen" "compose neu|nginx neu|" "$(content)"

echo "== Abweichung nach compose up: Lauf rot"
setup
run_full FAKE_UP_CLOBBER="$SRV/docker-compose.yml" FAKE_NGINX_HASH="$HN"; RC=$?
[ "$RC" -ne 0 ] && ok "Lauf rot" || fail "Lauf nicht rot (Abweichung nicht erkannt)"
grep -q 'weicht nach dem Deploy vom Commit ab' "$WORK/full.out" && ok "Meldung nennt die Abweichung" || fail "keine Meldung"
echo "== Container hat die alte nginx.conf geladen: Lauf rot"
setup
run_full FAKE_NGINX_HASH=deadbeef; RC=$?
[ "$RC" -ne 0 ] && ok "Lauf rot" || fail "Lauf nicht rot (veralteter Container nicht erkannt)"
grep -q 'nicht die ausgelieferte' "$WORK/full.out" && ok "Meldung nennt den Container" || fail "keine Meldung"

echo "== Symlink im Zielpfad: nichts außerhalb des deploy-path"
setup
mkdir -p "$WORK/draussen"; printf 'fremd\n' > "$WORK/draussen/nginx.conf"
rm -f "$SRV/nginx.conf"; ln -s "$WORK/draussen" "$SRV/conf"
mkdir -p "$STG/conf"; printf 'nginx neu\n' > "$STG/conf/nginx.conf"
HN=$(hash_of "$STG/conf/nginx.conf")
INPUT_DEPLOY_PATH="$SRV" INPUT_APP_CONTAINER=app INPUT_STATEFUL_SERVICES="" INPUT_NGINX_CONFIG_CONTAINER="" INPUT_NGINX_CONFIG_FILE="" \
  NEEDS_CONFIG_HASHES="conf/nginx.conf=$HN" CFG_STAGE_VALUE="$STG" "$EXTRACT" "$WF" full-deploy "Deploy to Hetzner" --key script > "$WORK/full.sh"
env PATH="$BIN:$PATH" FAKE_LOG="$WORK/fake.log" GHCR_TOKEN=x EXPECTED_BASE="" bash "$WORK/full.sh" > "$WORK/full.out" 2>&1; RC=$?
[ "$RC" -ne 0 ] && ok "Lauf rot" || fail "Lauf nicht rot"
expect "Datei außerhalb unverändert" "fremd" "$(cat "$WORK/draussen/nginx.conf")"
expect "keine Sicherung außerhalb" "0" "$(find "$WORK/draussen" -name '*.bak-*' | wc -l | tr -d ' ')"
expect "kein compose pull" "0" "$(grep -c '^docker compose pull' "$WORK/fake.log")"

echo "== Ergebnis: $PASS ok, $FAIL fehlend"
[ "$FAIL" -eq 0 ]
