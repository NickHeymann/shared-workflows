#!/usr/bin/env bash
# Trockenlauf des Shell-Teils von deploy-hetzner.yml mit einem Attrappen-Repo.
# Es wird kein Deploy ausgelöst: die run-Bloecke werden aus der YAML gezogen und lokal
# ausgeführt, die ssh-Skripte gegen ein temporaeres Verzeichnis.
#
# Aufruf: tests/test-quick-deploy.sh [workflow.yml]   (Standard: .github/workflows/deploy-hetzner.yml)
# Rotprobe: tests/test-quick-deploy.sh <alte Fassung der Datei> muss Fälle rot melden.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="${1:-$HERE/../.github/workflows/deploy-hetzner.yml}"
EXTRACT="$HERE/extract-step.rb"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qd-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok    $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FEHLT $1"; }
expect() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (erwartet '$2', erhalten '$3')"; fi
}

# ── Attrappen-Repo ────────────────────────────────────────────────────────────
ORIGIN="$WORK/origin.git"
SRC="$WORK/src"
git init -q --bare -b main "$ORIGIN"
git -C "$ORIGIN" config uploadpack.allowReachableSHA1InWant true
git init -q -b main "$SRC"
git -C "$SRC" config user.email t@example.invalid
git -C "$SRC" config user.name Test
commit() { # datei inhalt nachricht
  mkdir -p "$SRC/$(dirname "$1")"
  printf '%s\n' "$2" > "$SRC/$1"
  git -C "$SRC" add "$1"
  git -C "$SRC" commit -q -m "$3"
  git -C "$SRC" rev-parse HEAD
}
C0=$(commit resources/views/a.blade.php v0 "start")
C1=$(commit app/Mail/Kontakt.php php1 "PHP-Änderung (PR 78)")
C2=$(commit nginx.conf n1 "nginx.conf (Folge-Commit, der den Lauf überholt)")
C3=$(commit resources/views/b.blade.php v1 "Views")
C4=$(commit resources/css/app.css css "CSS")
git -C "$SRC" remote add origin "$ORIGIN"
git -C "$SRC" push -q origin main

# Runner-Klon wie actions/checkout mit fetch-depth 2
runner_clone() {
  rm -rf "$WORK/runner"
  git clone -q --depth 2 "file://$ORIGIN" "$WORK/runner"
}

run_check() { # basis_raw app_container  -> gibt quick=... aus
  runner_clone
  local out="$WORK/gh-output"
  : > "$out"
  local script="$WORK/check.sh"
  INPUT_APP_CONTAINER="$2" "$EXTRACT" "$WF" detect-changes check > "$script" || { echo "EXTRAKTIONSFEHLER"; return; }
  (cd "$WORK/runner" && GITHUB_OUTPUT="$out" APP_CONTAINER="$2" BASIS_RAW="$1" bash -e "$script" > "$WORK/check.log" 2>&1)
  local rc=$?
  if [ "$rc" -ne 0 ]; then echo "exit$rc"; return; fi
  grep -E '^quick=' "$out" | tail -n 1
}

echo "== detect-changes (Basis-Guard)"
expect "normaler Merge: Basis=Vorgänger, nur Views -> quick" "quick=true" \
  "$(run_check "QUICK_DEPLOY_BASIS=$C3" app)"
expect "normaler Merge: Basis=Vorgänger, PHP-Datei -> full" "quick=false" \
  "$(run_check "QUICK_DEPLOY_BASIS=$C0" app)"
# HEAD ist C4. Basis C1: dazwischen nginx.conf (C2) + Views + CSS, aber die PHP-Änderung von C1 selbst
# liegt vor der Basis. Der Fall "überholter Lauf": Basis C0, PHP-Commit C1 nie ausgerollt, HEAD C4.
expect "überholter Lauf: PHP-Commit liegt zwischen Basis und HEAD -> full" "quick=false" \
  "$(run_check "QUICK_DEPLOY_BASIS=$C0" app)"
expect "Basis nach dem PHP-Commit (C1 ausgerollt): Rest nur nginx/Views/CSS -> quick" "quick=true" \
  "$(run_check "QUICK_DEPLOY_BASIS=$C1" app)"
expect "Basis = HEAD (Wiederholung desselben Commits) -> quick" "quick=true" \
  "$(run_check "QUICK_DEPLOY_BASIS=$C4" app)"
expect "Vermerk fehlt (leere Ausgabe) -> full" "quick=false" "$(run_check "" app)"
expect "Vermerk fehlt (nur Rauschen von ssh) -> full" "quick=false" "$(run_check "Welcome to server" app)"
expect "Vermerk leer -> full" "quick=false" "$(run_check "QUICK_DEPLOY_BASIS=" app)"
expect "Vermerk ungültig (kein SHA) -> full" "quick=false" "$(run_check "QUICK_DEPLOY_BASIS=nicht-ermittelbar" app)"
expect "Vermerk zu kurz -> full" "quick=false" "$(run_check "QUICK_DEPLOY_BASIS=${C3:0:12}" app)"
expect "Basis nicht abrufbar (unbekannter SHA) -> full" "quick=false" \
  "$(run_check "QUICK_DEPLOY_BASIS=0123456789abcdef0123456789abcdef01234567" app)"
expect "Vermerk mit Rauschen davor und danach wird gelesen -> quick" "quick=true" \
  "$(run_check "motd
QUICK_DEPLOY_BASIS=$C3
fertig" app)"
expect "kein app-container -> full (unverändert)" "quick=false" "$(run_check "QUICK_DEPLOY_BASIS=$C3" "")"

# Der Basis-Commit liegt außerhalb der Tiefe 2 und wird nachgeladen
runner_clone
git -C "$WORK/runner" cat-file -e "$C0^{commit}" 2>/dev/null && fail "Vorbedingung: C0 darf im flachen Klon nicht liegen" || ok "Vorbedingung: Basis liegt nicht im flachen Klon"

echo "== public/images-Guard"
run_has_images() { # mit|ohne
  rm -rf "$WORK/img"; mkdir -p "$WORK/img"
  [ "$1" = "mit" ] && mkdir -p "$WORK/img/public/images"
  local out="$WORK/gh-output-img"; : > "$out"
  "$EXTRACT" "$WF" quick-deploy has-images > "$WORK/img.sh" || { echo "EXTRAKTIONSFEHLER"; return; }
  (cd "$WORK/img" && GITHUB_OUTPUT="$out" bash -e "$WORK/img.sh" >/dev/null 2>&1)
  tail -n 1 "$out"
}
expect "public/images vorhanden -> exists=true" "exists=true" "$(run_has_images mit)"
expect "public/images fehlt -> exists=false (kein rsync-Abbruch)" "exists=false" "$(run_has_images ohne)"
# Upload-Schritt läuft nur mit dem Flag
UPLOAD_IF=$(ruby -ryaml -e 'wf=YAML.load_file(ARGV[0]); s=wf["jobs"]["quick-deploy"]["steps"].find{|x| x["name"]=="Upload public images"}; puts s && s["if"]' "$WF")
expect "Upload public images ist an has-images gebunden" "steps.has-images.outputs.exists == 'true'" "$UPLOAD_IF"

echo "== Server-Skripte (Basis-Vermerk), echte Skripte gegen Attrappen von docker, curl, timeout"
BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/docker" <<'FAKE'
#!/bin/bash
# Attrappe: protokolliert Aufrufe, prueft den Vermerk zum Zeitpunkt der Aufrufe.
echo "docker $*" >> "$FAKE_LOG"
case "$1 $2" in
  "compose pull"|"compose up") echo "marker-bei-$1-$2=$([ -e "$MARKER" ] && echo da || echo weg)" >> "$FAKE_LOG" ;;
esac
[ "$1" = "cp" ] && echo "marker-bei-cp=$([ -e "$MARKER" ] && echo da || echo weg)" >> "$FAKE_LOG"
[ "$1" = "cp" ] && [ "${FAKE_FAIL:-}" = "cp" ] && exit 1
if [ "$1" = "compose" ] && [ "$2" = "config" ]; then printf 'app\nredis\n'; exit 0; fi
if [ "$1" = "compose" ] && [ "$2" = "up" ] && [ "${FAKE_FAIL:-}" = "up" ]; then exit 1; fi
if [ "$1" = "inspect" ]; then
  [ "${FAKE_FAIL:-}" = "inspect" ] && exit 1
  printf '%s\n' "${FAKE_LABEL-}"; exit 0
fi
if [ "$1" = "exec" ] && printf '%s ' "$@" | grep -q 'kill -USR2' && [ "${FAKE_USR2_FAIL:-}" = "1" ]; then exit 1; fi
exit 0
FAKE
cat > "$BIN/curl" <<'FAKE'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
[ -n "$out" ] && echo ok > "$out"
printf '%s' "${FAKE_CURL_CODE:-200}"
FAKE
cat > "$BIN/timeout" <<'FAKE'
#!/bin/bash
shift; exec "$@"
FAKE
chmod +x "$BIN"/*

SHA_VALUE="$C4"
OTHER="1111111111111111111111111111111111111111"   # Revision eines anderen Laufs im Image-Label

run_quick() { # fail usr2fail curlcode vorhandener-vermerk -> schreibt $SERVER/app, Rueckgabe: exit-Code
  SERVER="$WORK/server-quick"; rm -rf "$SERVER" "$WORK/qd"; mkdir -p "$SERVER/app" "$WORK/qd/resources/views" "$WORK/qd/lang" "$WORK/qd/public/build" "$WORK/qd/public/images"
  [ -n "$4" ] && echo "$4" > "$SERVER/app/.quick-deploy-basis"
  : > "$WORK/fake.log"
  INPUT_DEPLOY_PATH="$SERVER/app" INPUT_APP_CONTAINER=app INPUT_PUBLIC_VOLUME_PATH="" GITHUB_SHA_VALUE="$SHA_VALUE" \
    "$EXTRACT" "$WF" quick-deploy "Apply + clear caches" --key script \
    | sed -e "s|/tmp/quick-deploy|$WORK/qd|g" -e "s|/tmp/opcache-reset.out|$WORK/opcache.out|g" > "$WORK/apply.sh"
  PATH="$BIN:$PATH" FAKE_LOG="$WORK/fake.log" MARKER="$SERVER/app/.quick-deploy-basis" FAKE_FAIL="$1" FAKE_USR2_FAIL="$2" FAKE_CURL_CODE="$3" \
    OPCACHE_RESET_URL="https://x.invalid/reset" DEPLOY_TOKEN=t HAS_IMAGES=false \
    bash -e "$WORK/apply.sh" > "$WORK/apply.out" 2>&1
}
marker() { cat "$1/.quick-deploy-basis" 2>/dev/null || echo "-"; }

run_quick "" 0 200 "$C1"; RC=$?
expect "Quick: Erfolg, Exit 0" "0" "$RC"
expect "Quick: Vermerk = github.sha nach Erfolg" "$C4" "$(marker "$SERVER/app")"
expect "Quick: alter Vermerk war vor dem ersten docker cp ungültig" "marker-bei-cp=weg" "$(grep 'marker-bei-cp' "$WORK/fake.log" | head -n 1)"
[ ! -e "$SERVER/app/.quick-deploy-basis.tmp" ] && ok "Quick: keine .tmp-Datei übrig" || fail "Quick: .tmp-Datei übrig"
run_quick "" 1 500 "$C1"; RC=$?
expect "Quick: Reset-URL 500 und USR2 scheitert -> kein Vermerk" "-" "$(marker "$SERVER/app")"
expect "Quick: ... Lauf bleibt wie bisher grün (Exit 0)" "0" "$RC"
run_quick "" 0 500 "$C1"; RC=$?
expect "Quick: Reset-URL 500, USR2 gelingt -> Vermerk" "$C4" "$(marker "$SERVER/app")"
run_quick cp 0 200 "$C1"; RC=$?
[ "$RC" -ne 0 ] && ok "Quick: docker cp scheitert -> Lauf rot" || fail "Quick: docker cp scheitert, Lauf nicht rot"
expect "Quick: ... und der alte Vermerk bleibt NICHT gültig" "-" "$(marker "$SERVER/app")"
expect "Quick: images nur mit HAS_IMAGES kopiert (Skript)" "1" "$(grep -c 'HAS_IMAGES" = "true"' "$WORK/apply.sh")"

run_full() { # fail label app-container vorhandener-vermerk
  SERVER="$WORK/server-full"; rm -rf "$SERVER"; mkdir -p "$SERVER/app"
  [ -n "$4" ] && echo "$4" > "$SERVER/app/.quick-deploy-basis"
  : > "$WORK/fake.log"
  INPUT_DEPLOY_PATH="$SERVER/app" INPUT_APP_CONTAINER="$3" GITHUB_SHA_VALUE="$SHA_VALUE" INPUT_STATEFUL_SERVICES="redis" INPUT_PRE_DEPLOY_COMMANDS="" INPUT_POST_DEPLOY_COMMANDS="" INPUT_EXTRA_DEPLOY_PATHS="" \
    "$EXTRACT" "$WF" full-deploy "Deploy to Hetzner" --key script > "$WORK/full.sh"
  PATH="$BIN:$PATH" FAKE_LOG="$WORK/fake.log" MARKER="$SERVER/app/.quick-deploy-basis" FAKE_FAIL="$1" FAKE_LABEL="$2" GHCR_TOKEN=x \
    bash "$WORK/full.sh" > "$WORK/full.out" 2>&1
}

run_full "" "$C4" app "$C1"; RC=$?
expect "Full: Erfolg, Exit 0" "0" "$RC"
expect "Full: Vermerk = Revision aus dem Container-Label" "$C4" "$(marker "$SERVER/app")"
expect "Full: alter Vermerk war vor docker compose pull ungültig" "marker-bei-compose-pull=weg" "$(grep 'marker-bei-compose-pull' "$WORK/fake.log" | head -n 1)"
run_full "" "$OTHER" app "$C1"; RC=$?
expect "Full: Vermerk folgt dem Image-Label, nicht github.sha (fremdes :latest)" "$OTHER" "$(marker "$SERVER/app")"
run_full "" "" app "$C1"; RC=$?
expect "Full: Label leer -> kein Vermerk (fail closed)" "-" "$(marker "$SERVER/app")"
run_full "" "<no value>" app "$C1"; RC=$?
expect "Full: Label ungültig -> kein Vermerk" "-" "$(marker "$SERVER/app")"
run_full inspect "$C4" app "$C1"; RC=$?
expect "Full: docker inspect scheitert -> kein Vermerk" "-" "$(marker "$SERVER/app")"
run_full up "$C4" app "$C1"; RC=$?
[ "$RC" -ne 0 ] && ok "Full: compose up scheitert -> Lauf rot" || fail "Full: compose up scheitert, Lauf nicht rot"
expect "Full: ... und der alte Vermerk bleibt NICHT gültig" "-" "$(marker "$SERVER/app")"
run_full "" "$C4" "" "$C1"; RC=$?
expect "Full ohne app-container: vorhandener Vermerk bleibt unberührt" "$C1" "$(marker "$SERVER/app")"
run_full "" "$C4" "" ""; RC=$?
expect "Full ohne app-container: kein Vermerk angelegt" "-" "$(marker "$SERVER/app")"

echo "== Build-Label"
BUILD_LABEL=$(ruby -ryaml -e 'wf=YAML.load_file(ARGV[0]); s=wf["jobs"]["full-deploy"]["steps"].find{|x| x["name"]=="Build and push Docker image"}; puts s["with"]["labels"]' "$WF")
expect "Build setzt das Revision-Label" "org.opencontainers.image.revision=\${{ github.sha }}" "$(printf '%s' "$BUILD_LABEL" | head -n 1)"

echo "== Ergebnis: $PASS ok, $FAIL fehlend"
[ "$FAIL" -eq 0 ]
