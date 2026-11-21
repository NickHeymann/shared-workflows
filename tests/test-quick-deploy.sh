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
git init -q --bare "$ORIGIN"
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

echo "== Server-Skripte (Basis-Vermerk schreiben)"
SERVER="$WORK/server"; mkdir -p "$SERVER/app"
SHA_VALUE="$C4"
# Quick-Deploy: nur der Teil ab BASIS_FILE= (der Rest braucht docker)
INPUT_DEPLOY_PATH="$SERVER/app" GITHUB_SHA_VALUE="$SHA_VALUE" "$EXTRACT" "$WF" quick-deploy "Apply + clear caches" --key script > "$WORK/apply.sh" || fail "Extraktion Apply-Skript"
if grep -q 'BASIS_FILE=' "$WORK/apply.sh"; then
  sed -n '/BASIS_FILE=/,$p' "$WORK/apply.sh" > "$WORK/apply-tail.sh"
  (bash -e "$WORK/apply-tail.sh" >/dev/null 2>&1)
  expect "Quick-Deploy schreibt Basis-Vermerk" "$C4" "$(cat "$SERVER/app/.quick-deploy-basis" 2>/dev/null)"
  [ ! -e "$SERVER/app/.quick-deploy-basis.tmp" ] && ok "Quick-Deploy: keine .tmp-Datei übrig" || fail "Quick-Deploy: .tmp-Datei übrig"
else
  fail "Quick-Deploy-Skript enthaelt keinen Basis-Vermerk"
fi
# Reihenfolge: der Vermerk steht NACH Kopieren und Cache-Reset, nicht davor
APPLY_LINES=$(grep -n -E 'docker cp /tmp/quick-deploy/resources/views|opcache|BASIS_FILE=' "$WORK/apply.sh" | tail -n 1 | cut -d: -f2- | cut -c1-12)
expect "Quick-Deploy: Vermerk ist die letzte Wirkung (nach cp und OPcache-Reset)" "BASIS_FILE=\"" "$APPLY_LINES"
expect "Quick-Deploy: images nur mit HAS_IMAGES kopiert" "1" "$(grep -c 'HAS_IMAGES" = "true"' "$WORK/apply.sh")"

# Full-Deploy: Vermerk nach compose_up/Extra-Pfaden, vor dem Aufräumen, nur mit app-container
INPUT_DEPLOY_PATH="$SERVER/full" INPUT_APP_CONTAINER=app GITHUB_SHA_VALUE="$SHA_VALUE" INPUT_STATEFUL_SERVICES="" INPUT_PRE_DEPLOY_COMMANDS="" INPUT_POST_DEPLOY_COMMANDS="" INPUT_EXTRA_DEPLOY_PATHS="" \
  "$EXTRACT" "$WF" full-deploy "Deploy to Hetzner" --key script > "$WORK/full.sh" || fail "Extraktion Full-Deploy-Skript"
if grep -q 'quick-deploy-basis' "$WORK/full.sh"; then
  L_UP=$(grep -n '^ *compose_up$' "$WORK/full.sh" | tail -n 1 | cut -d: -f1)
  L_EXTRA=$(grep -n 'Deploying to extra path' "$WORK/full.sh" | cut -d: -f1)
  L_BASIS=$(grep -n 'quick-deploy-basis.tmp' "$WORK/full.sh" | head -n 1 | cut -d: -f1)
  L_PRUNE=$(grep -n 'docker image prune' "$WORK/full.sh" | cut -d: -f1)
  [ -n "$L_BASIS" ] && [ "$L_BASIS" -gt "$L_UP" ] && [ "$L_BASIS" -gt "$L_EXTRA" ] && [ "$L_BASIS" -lt "$L_PRUNE" ] \
    && ok "Full-Deploy: Vermerk nach compose_up und Extra-Pfaden" || fail "Full-Deploy: Vermerk an falscher Stelle ($L_UP/$L_EXTRA/$L_BASIS/$L_PRUNE)"
  # Block ausführen (if ... fi)
  mkdir -p "$SERVER/full"
  sed -n '/^ *if \[ -n "app" \]; then/,/^ *fi$/p' "$WORK/full.sh" > "$WORK/full-tail.sh"
  (bash -e "$WORK/full-tail.sh" >/dev/null 2>&1)
  expect "Full-Deploy schreibt Basis-Vermerk (mit app-container)" "$C4" "$(cat "$SERVER/full/.quick-deploy-basis" 2>/dev/null)"
  # ohne app-container: nichts schreiben
  INPUT_DEPLOY_PATH="$SERVER/ohne" INPUT_APP_CONTAINER="" GITHUB_SHA_VALUE="$SHA_VALUE" INPUT_STATEFUL_SERVICES="" INPUT_PRE_DEPLOY_COMMANDS="" INPUT_POST_DEPLOY_COMMANDS="" INPUT_EXTRA_DEPLOY_PATHS="" \
    "$EXTRACT" "$WF" full-deploy "Deploy to Hetzner" --key script > "$WORK/full-ohne.sh"
  mkdir -p "$SERVER/ohne"
  sed -n '/^ *if \[ -n "" \]; then/,/^ *fi$/p' "$WORK/full-ohne.sh" > "$WORK/full-ohne-tail.sh"
  (bash -e "$WORK/full-ohne-tail.sh" >/dev/null 2>&1)
  [ ! -e "$SERVER/ohne/.quick-deploy-basis" ] && ok "Full-Deploy ohne app-container: kein Vermerk" || fail "Full-Deploy ohne app-container schreibt Vermerk"
else
  fail "Full-Deploy-Skript enthaelt keinen Basis-Vermerk"
fi

echo "== Ergebnis: $PASS ok, $FAIL fehlend"
[ "$FAIL" -eq 0 ]
