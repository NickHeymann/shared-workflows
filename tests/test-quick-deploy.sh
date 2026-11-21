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
# C5 liegt nach C4 (neuer ausgerollter Stand); der Runner baut C4 (alter Rerun)
C5=$(commit resources/views/c.blade.php v2 "Views (neuerer Stand)")
git -C "$SRC" push -q origin main
git -C "$ORIGIN" update-ref refs/heads/main "$C4"
git -C "$ORIGIN" update-ref refs/heads/neuer "$C5"

# Runner-Klon wie actions/checkout mit fetch-depth 2
runner_clone() {
  rm -rf "$WORK/runner"
  git clone -q --depth 2 "file://$ORIGIN" "$WORK/runner"
}

run_check() { # basis_raw app_container  -> gibt quick=... aus
  runner_clone
  [ -n "${BREAK_REMOTE:-}" ] && git -C "$WORK/runner" remote set-url origin "file://$WORK/gibt-es-nicht.git"
  local out="$WORK/gh-output"
  : > "$out"
  local script="$WORK/check.sh"
  INPUT_APP_CONTAINER="$2" "$EXTRACT" "$WF" detect-changes check > "$script" || { echo "EXTRAKTIONSFEHLER"; return; }
  (cd "$WORK/runner" && GITHUB_OUTPUT="$out" APP_CONTAINER="$2" PUBLIC_VOLUME="${PUBLIC_VOLUME-/srv/public-volume}" BASIS_RAW="$1" bash -e "$script" > "$WORK/check.log" 2>&1)
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
expect "Basis nach dem PHP-Commit (C1 ausgerollt): Rest enthält nginx.conf (wird nicht ausgerollt) -> full" "quick=false" \
  "$(run_check "QUICK_DEPLOY_BASIS=$C1" app)"
expect "Basis nach nginx.conf (C2 ausgerollt): Rest nur Views/CSS -> quick" "quick=true" \
  "$(run_check "QUICK_DEPLOY_BASIS=$C2" app)"
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

# Schutz gegen alte Wiederholungen: HEAD ist C4
expect "alter Rerun: Basis ist neuer als HEAD (Vorfahr) -> Abbruch" "exit1" "$(run_check "QUICK_DEPLOY_BASIS=$C5" app)"
grep -q 'älter als der am Ziel' "$WORK/check.log" && ok "alter Rerun: klare Meldung" || fail "alter Rerun: keine klare Meldung"
expect "Rerun desselben Commits (Basis=HEAD) -> kein Abbruch" "quick=true" "$(run_check "QUICK_DEPLOY_BASIS=$C4" app)"
expect "Vorfahren-Prüfung greift vor der Einstufung (gilt für Quick und Full) -> Abbruch" "exit1" "$(run_check "QUICK_DEPLOY_BASIS=$C5" app)"
# Historie nicht nachladbar (flacher Klon, Origin nicht erreichbar): nicht deployen statt als "kein Vorfahr" werten
BREAK_REMOTE=1 run_check "QUICK_DEPLOY_BASIS=$C3" app > "$WORK/brk.out"; RCB=$(BREAK_REMOTE=1 run_check "QUICK_DEPLOY_BASIS=$C3" app)
expect "flache Historie, Nachladen scheitert -> Abbruch statt quick" "exit1" "$RCB"
grep -q 'Historie konnte nicht vollständig geladen' "$WORK/check.log" && ok "flache Historie: klare Meldung" || fail "flache Historie: keine klare Meldung"
# Basis wird auch bei Full gemeldet (Prüfung unter der Server-Sperre)
run_check "QUICK_DEPLOY_BASIS=$C0" app > /dev/null; grep -q "^base=$C0" "$WORK/gh-output" && ok "Basis-Ausgabe auch bei Full-Entscheidung" || fail "base fehlt bei Full-Entscheidung"
# nginx.conf: ehrliche Meldung
run_check "QUICK_DEPLOY_BASIS=$C1" app > /dev/null
grep -q 'nginx.conf hat sich geändert, wird aber NICHT ausgerollt' "$WORK/check.log" && ok "nginx.conf-Änderung: Lauf meldet, dass sie nicht ausgerollt wird" || fail "nginx.conf: keine ehrliche Meldung"
run_check "QUICK_DEPLOY_BASIS=$C3" app > /dev/null
grep -q 'nginx.conf' "$WORK/check.log" && fail "nginx-Hinweis ohne nginx-Änderung" || ok "ohne nginx.conf-Änderung kein nginx-Hinweis"

echo "== detect-changes (Quick-Liste, fail closed)"
# Je Fall ein eigenes Repo: Basis-Commit mit allen Dateien, zweiter Commit ändert/löscht/benennt um.
# Zeilen: "M pfad", "A pfad", "D pfad", "R alt neu". Ausgabe: quick=... und Log in $WORK/check.log
fc_case() { # aenderungen (zeilenweise)  [PUBLIC_VOLUME wird vererbt]
  local dir="$WORK/fc" line st a b
  rm -rf "$dir" "$WORK/fc-origin.git"
  git init -q --bare -b main "$WORK/fc-origin.git"
  git init -q -b main "$dir"
  git -C "$dir" config user.email t@example.invalid
  git -C "$dir" config user.name Test
  git -C "$dir" config core.excludesFile /dev/null
  git -C "$dir" remote add origin "$WORK/fc-origin.git"
  local base_files="resources/views/a.blade.php lang/de/a.php resources/css/app.css resources/js/app.js public/build/x.js public/images/a.png docker/x.conf scripts/x.sh docker-entrypoint.sh docker-compose.yml Dockerfile resources/markdown/a.md public/favicon.ico README.md nginx.conf app/A.php"
  local f
  for f in $base_files; do mkdir -p "$dir/$(dirname "$f")"; echo v0 > "$dir/$f"; done
  git -C "$dir" add -A; git -C "$dir" commit -q -m basis
  local B; B=$(git -C "$dir" rev-parse HEAD)
  while read -r st a b; do
    [ -z "$st" ] && continue
    case "$st" in
      M) echo v1 >> "$dir/$a" ;;
      A) mkdir -p "$dir/$(dirname "$a")"; echo neu > "$dir/$a" ;;
      D) rm -f "$dir/$a" ;;
      R) mkdir -p "$dir/$(dirname "$b")"; git -C "$dir" mv "$a" "$b" ;;
    esac
  done <<< "$1"
  git -C "$dir" add -A; git -C "$dir" commit -q -m aenderung --allow-empty
  git -C "$dir" push -q origin main
  rm -rf "$WORK/runner"; git clone -q --depth 2 "file://$WORK/fc-origin.git" "$WORK/runner"
  local out="$WORK/gh-output"; : > "$out"
  local script="$WORK/check.sh"
  INPUT_APP_CONTAINER=app "$EXTRACT" "$WF" detect-changes check > "$script" || { echo "EXTRAKTIONSFEHLER"; return; }
  (cd "$WORK/runner" && GITHUB_OUTPUT="$out" APP_CONTAINER=app PUBLIC_VOLUME="${PUBLIC_VOLUME-/srv/public-volume}" BASIS_RAW="QUICK_DEPLOY_BASIS=$B" bash -e "$script" > "$WORK/check.log" 2>&1) || { echo "exit$?"; return; }
  grep -E '^quick=' "$out" | tail -n 1
}
expect "nur docker/ -> full" "quick=false" "$(fc_case "M docker/x.conf")"
grep -q 'Full build required due to: docker/x.conf' "$WORK/check.log" && ok "docker/: Log nennt die auslösende Datei" || fail "docker/: Log nennt die Datei nicht"
expect "nur docker-entrypoint.sh -> full" "quick=false" "$(fc_case "M docker-entrypoint.sh")"
expect "nur docker-compose.yml -> full" "quick=false" "$(fc_case "M docker-compose.yml")"
expect "nur scripts/ -> full" "quick=false" "$(fc_case "M scripts/x.sh")"
grep -q 'Full build required due to: scripts/x.sh' "$WORK/check.log" && ok "scripts/: Log nennt die auslösende Datei" || fail "scripts/: Log nennt die Datei nicht"
expect "nur resources/js -> quick" "quick=true" "$(fc_case "M resources/js/app.js")"
expect "nur resources/css -> quick" "quick=true" "$(fc_case "M resources/css/app.css")"
expect "nur resources/views -> quick" "quick=true" "$(fc_case "M resources/views/a.blade.php")"
expect "nur resources/ ohne views/css/js (markdown) -> full" "quick=false" "$(fc_case "M resources/markdown/a.md")"
expect "nur public/images (geändert) -> quick" "quick=true" "$(fc_case "M public/images/a.png")"
expect "nur public/images (neu) -> quick" "quick=true" "$(fc_case "A public/images/b.png")"
expect "public/images gelöscht (Quick rollt Löschungen nicht aus) -> full" "quick=false" "$(fc_case "D public/images/a.png")"
expect "nur public/build -> quick" "quick=true" "$(fc_case "M public/build/x.js")"
expect "public/ sonst (favicon.ico) -> full" "quick=false" "$(fc_case "M public/favicon.ico")"
expect "lang/ -> quick" "quick=true" "$(fc_case "M lang/de/a.php")"
expect "letzte Datei in lang/ gelöscht (Verzeichnis weg, Upload entfällt) -> full" "quick=false" "$(fc_case "D lang/de/a.php")"
expect "Wurzeldatei (README.md) -> full" "quick=false" "$(fc_case "M README.md")"
expect "nginx.conf -> full" "quick=false" "$(fc_case "M nginx.conf")"
expect "Dockerfile -> full" "quick=false" "$(fc_case "M Dockerfile")"
expect "gemischt: views + docker/ -> full" "quick=false" "$(fc_case "M resources/views/a.blade.php
M docker/x.conf")"
expect "gemischt: views + css + js + images + lang -> quick" "quick=true" "$(fc_case "M resources/views/a.blade.php
M resources/css/app.css
M resources/js/app.js
M public/images/a.png
M lang/de/a.php")"
expect "Umbenennung aus app/ heraus nach views (alter Pfad zählt) -> full" "quick=false" "$(fc_case "R app/A.php resources/views/b.blade.php")"
expect "Umbenennung innerhalb views (alte View bliebe im Container, Quick kopiert nur additiv) -> full" "quick=false" "$(fc_case "R resources/views/a.blade.php resources/views/b.blade.php")"
grep -q 'Full build required due to: resources/views/a.blade.php' "$WORK/check.log" && ok "Umbenennung: Log nennt den alten Pfad" || fail "Umbenennung: Log nennt den alten Pfad nicht"
expect "View gelöscht -> full" "quick=false" "$(fc_case "D resources/views/a.blade.php")"
expect "public/build-Datei gelöscht -> full" "quick=false" "$(fc_case "D public/build/x.js")"
expect "css gelöscht -> full" "quick=false" "$(fc_case "D resources/css/app.css")"
expect "Löschung gemischt mit Views-Änderung -> full" "quick=false" "$(fc_case "M resources/views/a.blade.php
D public/images/a.png")"
expect "leere Dateiliste (Rerun desselben Stands) -> quick" "quick=true" "$(fc_case "")"
expect "ohne public-volume-path: resources/js -> full" "quick=false" "$(PUBLIC_VOLUME= fc_case "M resources/js/app.js")"
grep -q 'kein public-volume-path' "$WORK/check.log" && ok "ohne public-volume-path: Log nennt den Grund" || fail "ohne public-volume-path: kein Grund im Log"
expect "ohne public-volume-path: public/images -> full" "quick=false" "$(PUBLIC_VOLUME= fc_case "M public/images/a.png")"
expect "ohne public-volume-path: nur views -> quick" "quick=true" "$(PUBLIC_VOLUME= fc_case "M resources/views/a.blade.php")"
expect "Dateiname mit Umlaut unter views -> quick" "quick=true" "$(fc_case "A resources/views/über.blade.php")"
expect "Dateiname mit Anführungszeichen (von git gequotet, nicht sicher einstufbar) -> full" "quick=false" "$(fc_case 'A resources/views/a"b.blade.php')"

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
if [ -n "${FAKE_EVENTS:-}" ]; then   # Ereignisprotokoll fuer den Gleichzeitigkeitstest
  s="${FAKE_SLEEP:-0}"
  [ "$1 $2" = "compose pull" ] && [ ! -e "$FAKE_EVENTS.s${FAKE_RUN:-}" ] && { : > "$FAKE_EVENTS.s${FAKE_RUN:-}"; echo full-start >> "$FAKE_EVENTS"; sleep "$s"; }
  [ "$1 $2" = "compose up" ] && { sleep "$s"; echo "$FAKE_LABEL" > "$FAKE_STATE"; }
  [ "$1 $2" = "image prune" ] && echo full-end >> "$FAKE_EVENTS"
  [ "$1" = "cp" ] && [ ! -e "$FAKE_EVENTS.q" ] && { : > "$FAKE_EVENTS.q"; echo quick-start >> "$FAKE_EVENTS"; sleep "$s"; echo "quick-views" > "$FAKE_STATE.views"; }
  printf '%s ' "$@" | grep -q 'view:cache' && echo quick-end >> "$FAKE_EVENTS"
fi
case "$1 $2" in
  "compose pull"|"compose up") echo "marker-bei-$1-$2=$([ -e "$MARKER" ] && echo da || echo weg)" >> "$FAKE_LOG" ;;
esac
[ "$1" = "cp" ] && echo "marker-bei-cp=$([ -e "$MARKER" ] && echo da || echo weg)" >> "$FAKE_LOG"
[ "$1" = "cp" ] && [ -n "${FAKE_CONCURRENT:-}" ] && echo "$FAKE_CONCURRENT" > "$MARKER"   # anderer Deploy schreibt mitten im Lauf seinen Vermerk
[ "$1" = "cp" ] && [ "${FAKE_FAIL:-}" = "cp" ] && exit 1
if [ "$1 $2" = "compose pull" ] && [ -n "${FAKE_PULL_FAILS:-}" ]; then
  n=$(cat "$FAKE_LOG.pulln" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_LOG.pulln"
  if [ "$n" -le "$FAKE_PULL_FAILS" ]; then
    echo "${FAKE_PULL_MSG:-NotFound: content digest sha256:abc: not found}" >&2
    [ -n "${FAKE_PULL_LONG:-}" ] && head -c 600000 /dev/zero | tr '\0' 'x' | fold -w 80 >&2
    exit 1
  fi
fi
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
cat > "$BIN/flock" <<'FAKE'
#!/usr/bin/env python3
# Attrappe fuer util-linux flock ("flock [-w SEK] FD" und "flock [-w SEK] DATEI BEFEHL..."), weil macOS kein flock hat.
import fcntl, os, subprocess, sys, time
a = sys.argv[1:]; w = None
if a and a[0] == "-w": w = float(a[1]); a = a[2:]
if a[0].isdigit():
    fd = int(a[0]); cmd = None
else:
    fd = os.open(a[0], os.O_RDWR | os.O_CREAT, 0o644); cmd = a[1:]
end = time.time() + (w if w is not None else 1e9)
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(subprocess.call(cmd, close_fds=True) if cmd else 0)
    except OSError:
        if time.time() >= end: sys.exit(1)
        time.sleep(0.05)
FAKE
chmod +x "$BIN"/*
# Rotprobe-Schalter: TEST_NOLOCK=1 entfernt die Sperre aus den Skripten
nolock() { if [ -n "${TEST_NOLOCK:-}" ]; then sed -E 's/flock -w "\$wait_s" "\$lp\/.deploy.lock" //'; else cat; fi; }
shortwait() { sed -E 's/(acquire_deploy_lock "[^"]*") [0-9]+/\1 1/'; }

SHA_VALUE="$C4"
OTHER="1111111111111111111111111111111111111111"   # Revision eines anderen Laufs im Image-Label

run_quick() { # fail usr2fail curlcode vorhandener-vermerk -> schreibt $SERVER/app, Rueckgabe: exit-Code
  SERVER="$WORK/server-quick"; rm -rf "$SERVER" "$WORK/qd"; mkdir -p "$SERVER/app" "$WORK/qd/resources/views" "$WORK/qd/lang" "$WORK/qd/public/build" "$WORK/qd/public/images"
  [ -n "$4" ] && echo "$4" > "$SERVER/app/.quick-deploy-basis"
  : > "$WORK/fake.log"
  INPUT_DEPLOY_PATH="$SERVER/app" INPUT_APP_CONTAINER=app INPUT_PUBLIC_VOLUME_PATH="" GITHUB_SHA_VALUE="$SHA_VALUE" \
    "$EXTRACT" "$WF" quick-deploy "Apply + clear caches" --key script \
    | sed -e "s|/tmp/quick-deploy-RUN-1|$WORK/qd|g" -e "s|/tmp/opcache-reset.out|$WORK/opcache.out|g" | nolock > "$WORK/apply.sh"
  PATH="$BIN:$PATH" FAKE_LOG="$WORK/fake.log" MARKER="$SERVER/app/.quick-deploy-basis" FAKE_FAIL="$1" FAKE_USR2_FAIL="$2" FAKE_CURL_CODE="$3" \
    FAKE_CONCURRENT="${QUICK_CONCURRENT:-}" EXPECTED_BASE="${QUICK_EXPECTED-$4}" \
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
QUICK_EXPECTED="$C0" run_quick "" 0 200 "$C1"; RC=$?
[ "$RC" -ne 0 ] && ok "Quick: Vermerk am Ziel weicht von der Entscheidungsgrundlage ab -> Lauf rot" || fail "Quick: abweichende Basis nicht abgelehnt"
expect "Quick: ... nichts kopiert (kein docker cp)" "0" "$(grep -c '^docker cp' "$WORK/fake.log")"
expect "Quick: ... und kein Vermerk" "-" "$(marker "$SERVER/app")"
run_quick "" 0 200 ""; RC=$?
[ "$RC" -ne 0 ] && ok "Quick: Vermerk inzwischen gelöscht (anderer Deploy) -> Lauf rot, nichts kopiert" || fail "Quick: fehlender Vermerk nicht abgelehnt"
expect "Quick: ... kein docker cp" "0" "$(grep -c '^docker cp' "$WORK/fake.log")"
QUICK_CONCURRENT="$OTHER" run_quick "" 0 200 "$C1"; RC=$?
expect "Quick: schreibt der Full-Deploy eines anderen Laufs mitten drin seinen Vermerk, wird er nicht überschrieben" "$OTHER" "$(marker "$SERVER/app")"
expect "Quick: images nur mit HAS_IMAGES kopiert (Skript)" "1" "$(grep -c 'HAS_IMAGES" = "true"' "$WORK/apply.sh")"

run_full() { # fail label app-container vorhandener-vermerk  (FULL_EXTRA: Extra-Pfade, je mit altem Vermerk)
  SERVER="$WORK/server-full"; rm -rf "$SERVER"; mkdir -p "$SERVER/app" "$SERVER/staging"
  [ -n "$4" ] && echo "$4" > "$SERVER/app/.quick-deploy-basis"
  [ -n "${FULL_EXTRA:-}" ] && echo "$C1" > "$SERVER/staging/.quick-deploy-basis"
  : > "$WORK/fake.log"
  INPUT_DEPLOY_PATH="$SERVER/app" INPUT_APP_CONTAINER="$3" GITHUB_SHA_VALUE="$SHA_VALUE" INPUT_STATEFUL_SERVICES="redis" INPUT_PRE_DEPLOY_COMMANDS="" INPUT_POST_DEPLOY_COMMANDS="" INPUT_EXTRA_DEPLOY_PATHS="${FULL_EXTRA:+$SERVER/staging}" \
    "$EXTRACT" "$WF" full-deploy "Deploy to Hetzner" --key script | nolock > "$WORK/full.sh"
  PATH="$BIN:$PATH" FAKE_LOG="$WORK/fake.log" MARKER="$SERVER/app/.quick-deploy-basis" FAKE_FAIL="$1" FAKE_LABEL="$2" GHCR_TOKEN=x EXPECTED_BASE="${EXP_OVERRIDE-$4}" \
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
FULL_EXTRA=1 run_full up "$C4" app "$C1"; RC=$?
expect "Full: Vermerk eines Extra-Pfads wird vor der ersten Änderung ebenfalls ungültig (auch bei Abbruch)" "-" "$(marker "$SERVER/staging")"
FULL_EXTRA=1 run_full "" "$C4" app "$C1"; RC=$?
expect "Full: Extra-Pfad bekommt keinen eigenen Vermerk" "-" "$(marker "$SERVER/staging")"
EXP_OVERRIDE="$C0" run_full "" "$C4" app "$C1"; RC=$?
[ "$RC" -ne 0 ] && grep -q 'Basis-Vermerk am Ziel' "$WORK/full.out" && ok "Full: Vermerk am Ziel weicht von der geprüften Basis ab -> Abbruch" || fail "Full: Basisabweichung wird nicht erkannt (Exit $RC)"
expect "Full: ... Vermerk unverändert, nichts ausgerollt" "$C1" "$(marker "$SERVER/app")"
expect "Full: ... kein compose pull" "0" "$(grep -c 'compose pull' "$WORK/fake.log")"
EXP_OVERRIDE="" run_full "" "$C4" app "$C1"; RC=$?
[ "$RC" -ne 0 ] && ok "Full: Vermerk erschien nach der Prüfung (erwartet: keiner) -> Abbruch" || fail "Full: neu erschienener Vermerk wird ignoriert"
echo "kaputt" > /dev/null
run_full "" "$C4" "" "$C1"; RC=$?
expect "Full ohne app-container: vorhandener Vermerk bleibt unberührt" "$C1" "$(marker "$SERVER/app")"
run_full "" "$C4" "" ""; RC=$?
expect "Full ohne app-container: kein Vermerk angelegt" "-" "$(marker "$SERVER/app")"

echo "== Sperre je deploy-path (flock)"
conc_setup() { # schreibt $WORK/c-apply.sh und $WORK/c-full.sh gegen $SERVER/app
  SERVER="$WORK/server-conc"; rm -rf "$SERVER" "$WORK/qd"; mkdir -p "$SERVER/app" "$WORK/qd/resources/views" "$WORK/qd/lang" "$WORK/qd/public/build" "$WORK/qd/public/images"
  echo "$C1" > "$SERVER/app/.quick-deploy-basis"
  : > "$WORK/fake.log"; : > "$WORK/events"; rm -f "$WORK/events.q" "$WORK/state" "$WORK/state.views"
  INPUT_DEPLOY_PATH="$SERVER/app" INPUT_APP_CONTAINER=app INPUT_PUBLIC_VOLUME_PATH="" GITHUB_SHA_VALUE="$SHA_VALUE" \
    "$EXTRACT" "$WF" quick-deploy "Apply + clear caches" --key script \
    | sed -e "s|/tmp/quick-deploy-RUN-1|$WORK/qd|g" -e "s|/tmp/opcache-reset.out|$WORK/opcache.out|g" | nolock > "$WORK/c-apply.sh"
  INPUT_DEPLOY_PATH="$SERVER/app" INPUT_APP_CONTAINER=app GITHUB_SHA_VALUE="$SHA_VALUE" INPUT_STATEFUL_SERVICES="redis" INPUT_PRE_DEPLOY_COMMANDS="" INPUT_POST_DEPLOY_COMMANDS="" INPUT_EXTRA_DEPLOY_PATHS="" \
    "$EXTRACT" "$WF" full-deploy "Deploy to Hetzner" --key script | nolock > "$WORK/c-full.sh"
}
conc_env() { PATH="$BIN:$PATH" FAKE_LOG="$WORK/fake.log" MARKER="$SERVER/app/.quick-deploy-basis" FAKE_EVENTS="$WORK/events" FAKE_STATE="$WORK/state" FAKE_SLEEP=1 FAKE_LABEL="$OTHER" EXPECTED_BASE="$C1" env "$@"; }
conc_setup
# Quick (Basis C1) startet zuerst, der Full-Deploy mit anderer Revision kommt waehrend dessen dazu
( conc_env EXPECTED_BASE="$C1" OPCACHE_RESET_URL="https://x.invalid/reset" DEPLOY_TOKEN=t HAS_IMAGES=false bash -e "$WORK/c-apply.sh" > "$WORK/c-apply.out" 2>&1; echo $? > "$WORK/c-apply.rc" ) &
PID_Q=$!
sleep 0.4
( conc_env GHCR_TOKEN=x bash "$WORK/c-full.sh" > "$WORK/c-full.out" 2>&1; echo $? > "$WORK/c-full.rc" ) &
PID_F=$!
wait "$PID_Q" "$PID_F"
# Ereignisse duerfen sich nie ueberlappen: auf "X-start" folgt sofort "X-end"
OVERLAP=$(awk '/-start/{d++; if(d>1) bad=1} /-end/{d--} END{print bad?"ueberlappt":"getrennt"}' "$WORK/events")
expect "zwei gleichzeitige Läufe (Quick und Full) überlappen nie" "getrennt" "$OVERLAP"
[ "$(cat "$WORK/c-full.rc")" -ne 0 ] && grep -q 'Basis-Vermerk am Ziel' "$WORK/c-full.out" && ok "Full nach dem Quick: Basis hat sich geändert -> bricht laut ab (nichts ausgerollt)" || fail "Full prüft die Basis unter der Sperre nicht (Exit $(cat "$WORK/c-full.rc"))"
expect "... Full hat nichts ausgerollt (kein compose pull)" "0" "$(grep -c 'compose pull' "$WORK/fake.log")"
FINAL="$(marker "$SERVER/app")"
if [ "$FINAL" = "$SHA_VALUE" ] || [ "$FINAL" = "-" ] || [ "$FINAL" = "$OTHER" ]; then ok "Vermerk passt zum ausgerollten Stand (Quick-Revision, leer oder Revision des Full-Deploys: $FINAL)"; else fail "Vermerk $FINAL passt nicht zum Stand (PHP aus $(cat "$WORK/state" 2>/dev/null))"; fi
[ "$(cat "$WORK/state" 2>/dev/null)" != "$OTHER" ] && ok "der Stand am Ziel stammt vom Quick-Deploy, nicht vom abgebrochenen Full" || fail "Full hat trotz geänderter Basis ausgerollt"
ls "$SERVER/app" | grep -q 'tmp' && fail "temporäre Vermerk-Dateien übrig" || ok "keine temporären Vermerk-Dateien übrig"

# Frist: ein zweiter Lauf scheitert laut, wenn die Sperre gehalten wird
conc_setup
( exec 9>"$SERVER/app/.deploy.lock"; PATH="$BIN:$PATH" flock 9; sleep 4 ) &
PID_H=$!
sleep 0.5
shortwait < "$WORK/c-apply.sh" > "$WORK/c-apply-kurz.sh"
conc_env EXPECTED_BASE="$C1" OPCACHE_RESET_URL=x DEPLOY_TOKEN=t HAS_IMAGES=false bash -e "$WORK/c-apply-kurz.sh" > "$WORK/c-apply.out" 2>&1; RC=$?
if [ -n "${TEST_NOLOCK:-}" ]; then fail "Frist (ohne Sperre nicht prüfbar)"; else
[ "$RC" -ne 0 ] && grep -q 'Deploy-Sperre' "$WORK/c-apply.out" && ok "Quick: Sperre nicht erhalten -> laute Fehlermeldung, Exit $RC" || fail "Quick: kein lauter Fehler bei gehaltener Sperre (Exit $RC)"
expect "Quick: ... nichts ausgerollt" "0" "$(grep -c '^docker cp' "$WORK/fake.log")"
expect "Quick: ... Vermerk unverändert" "$C1" "$(marker "$SERVER/app")"
shortwait < "$WORK/c-full.sh" > "$WORK/c-full-kurz.sh"
conc_env GHCR_TOKEN=x bash "$WORK/c-full-kurz.sh" > "$WORK/c-full.out" 2>&1; RC=$?
[ "$RC" -ne 0 ] && grep -q 'Deploy-Sperre' "$WORK/c-full.out" && ok "Full: Sperre nicht erhalten -> laute Fehlermeldung, Exit $RC" || fail "Full: kein lauter Fehler bei gehaltener Sperre (Exit $RC)"
expect "Full: ... nichts ausgerollt (kein compose pull)" "0" "$(grep -c 'compose pull' "$WORK/fake.log")"
fi
wait "$PID_H" 2>/dev/null

# Sperr-Deskriptoren werden nicht an Hintergrundprozesse aus pre-deploy-commands vererbt
genfull() { # main extra pre -> $WORK/g-full.sh
  INPUT_DEPLOY_PATH="$1" INPUT_APP_CONTAINER=app GITHUB_SHA_VALUE="$SHA_VALUE" INPUT_STATEFUL_SERVICES="redis" INPUT_PRE_DEPLOY_COMMANDS="$3" INPUT_POST_DEPLOY_COMMANDS="$3" INPUT_EXTRA_DEPLOY_PATHS="$2" \
    "$EXTRACT" "$WF" full-deploy "Deploy to Hetzner" --key script | nolock > "$4"
}
conc_setup
genfull "$SERVER/app" "" "sleep 6 &" "$WORK/g-full.sh"
conc_env GHCR_TOKEN=x bash "$WORK/g-full.sh" > "$WORK/g-full.out" 2>&1; RC=$?
expect "Full mit Hintergrundprozess in pre/post-deploy-commands: Exit 0" "0" "$RC"
( exec 9>"$SERVER/app/.deploy.lock"; PATH="$BIN:$PATH" flock -w 4 9 ); RC=$?
if [ -n "${TEST_NOLOCK:-}" ]; then :; else expect "Sperre ist nach dem Skriptende frei, obwohl ein Hintergrundprozess weiterläuft" "0" "$RC"; fi

# Extra-Pfade werden mitgesperrt
conc_setup; mkdir -p "$SERVER/staging"
( exec 9>"$SERVER/staging/.deploy.lock"; PATH="$BIN:$PATH" flock 9; sleep 4 ) &
PID_H=$!
sleep 0.5
genfull "$SERVER/app" "$SERVER/staging" "" "$WORK/g-full.sh"
shortwait < "$WORK/g-full.sh" > "$WORK/g-full-kurz.sh"
conc_env GHCR_TOKEN=x bash "$WORK/g-full-kurz.sh" > "$WORK/g-full.out" 2>&1; RC=$?
if [ -z "${TEST_NOLOCK:-}" ]; then
[ "$RC" -ne 0 ] && grep -q 'staging/.deploy.lock' "$WORK/g-full.out" && ok "Extra-Pfad gesperrt gehalten -> Full scheitert laut mit dem Pfad in der Meldung" || fail "Extra-Pfad-Sperre wird nicht beachtet (Exit $RC)"
expect "... nichts ausgerollt (kein compose pull)" "0" "$(grep -c 'compose pull' "$WORK/fake.log")"
fi
wait "$PID_H" 2>/dev/null

# Zwei Full-Deploys mit vertauschten Haupt- und Extra-Pfaden verklemmen nicht und laufen nacheinander
conc_setup; mkdir -p "$SERVER/staging"
genfull "$SERVER/app" "$SERVER/staging" "" "$WORK/g-full-1.sh"
genfull "$SERVER/staging" "$SERVER/app" "" "$WORK/g-full-2.sh"
( conc_env FAKE_RUN=1 GHCR_TOKEN=x bash "$WORK/g-full-1.sh" > "$WORK/g1.out" 2>&1; echo $? > "$WORK/g1.rc" ) &
P1=$!
( conc_env FAKE_RUN=2 GHCR_TOKEN=x bash "$WORK/g-full-2.sh" > "$WORK/g2.out" 2>&1; echo $? > "$WORK/g2.rc" ) &
P2=$!
wait "$P1" "$P2"
expect "vertauschte Haupt-/Extra-Pfade: beide Läufe enden mit Exit 0 (keine Verklemmung)" "0 0" "$(cat "$WORK/g1.rc") $(cat "$WORK/g2.rc")"
OVERLAP=$(awk '/-start/{d++; if(d>1) bad=1} /-end/{d--} END{print bad?"ueberlappt":"getrennt"}' "$WORK/events")
expect "vertauschte Haupt-/Extra-Pfade: Läufe überlappen nicht" "getrennt" "$OVERLAP"

# Fehler beim Rückmelde-Verzeichnis der Sperre: laut scheitern, nie hängen, nie ohne Sperre weiterlaufen
BIN2="$WORK/bin2"; mkdir -p "$BIN2"
cat > "$BIN2/mktemp" <<'FAKE'
#!/bin/bash
case "${FAKE_MKTEMP:-}" in
  fail) exit 1 ;;
  readonly) d="${FAKE_MKTEMP_DIR}"; mkdir -p "$d"; chmod 500 "$d"; echo "$d" ;;
  *) exec /usr/bin/mktemp "$@" ;;
esac
FAKE
chmod +x "$BIN2/mktemp"
if [ -z "${TEST_NOLOCK:-}" ]; then
for mode in fail readonly; do
  conc_setup
  START=$(date +%s)
  PATH="$BIN2:$PATH" FAKE_MKTEMP="$mode" FAKE_MKTEMP_DIR="$WORK/ro-$mode" conc_env EXPECTED_BASE="$C1" OPCACHE_RESET_URL=x DEPLOY_TOKEN=t HAS_IMAGES=false bash -e "$WORK/c-apply.sh" > "$WORK/c-apply.out" 2>&1; RC=$?
  chmod 700 "$WORK/ro-$mode" 2>/dev/null
  [ "$RC" -ne 0 ] && grep -qE 'Deploy-Sperre|mktemp' "$WORK/c-apply.out" && ok "Quick: Sperr-Rückmeldung '$mode' -> laute Fehlermeldung, kein Weiterlaufen ohne Sperre" || fail "Quick: Sperr-Rückmeldung '$mode' wird nicht abgefangen (Exit $RC)"
  [ $(( $(date +%s) - START )) -lt 60 ] && ok "Quick: '$mode' hängt nicht" || fail "Quick: '$mode' hängt"
  expect "Quick: '$mode' -> nichts ausgerollt" "0" "$(grep -c '^docker cp' "$WORK/fake.log")"
done
fi
grep -q 'mktemp -d' "$WORK/c-apply.sh" && ok "Rückmeldung der Sperre liegt in einem privaten mktemp -d Verzeichnis" || fail "kein mktemp -d"

# Staging-Verzeichnis je Lauf und Repo getrennt, Aufräumen auch bei Fehler
STG=$(ruby -ryaml -e 'wf=YAML.load_file(ARGV[0]); puts wf["jobs"]["quick-deploy"].dig("env","STAGING_DIR").to_s' "$WF")
case "$STG" in *needs.detect-changes.outputs.stage*github.run_attempt*) ok "Staging-Verzeichnis kommt aus dem Namensschritt je Aufruf plus aktuellem Versuch: $STG" ;; *) fail "Staging-Verzeichnis nicht je Lauf getrennt: '$STG'" ;; esac
[ "$(grep -c '/tmp/quick-deploy[^-]' "$WF")" = "0" ] && ok "kein fester Pfad /tmp/quick-deploy mehr" || fail "fester Pfad /tmp/quick-deploy vorhanden"
CLEAN_IF=$(ruby -ryaml -e 'wf=YAML.load_file(ARGV[0]); s=wf["jobs"]["quick-deploy"]["steps"].find{|x| x["name"].to_s.include?("Remove staging")}; puts s ? s["if"] : "fehlt"' "$WF")
expect "Aufräumschritt für das Staging läuft immer (if: always())" "always()" "$CLEAN_IF"

# compose pull: begrenzte Wiederholung nur bei NotFound: content digest
echo "== compose pull Wiederholung"
rm -f "$WORK/fake.log.pulln"
FAKE_PULL_FAILS=1 PULL_RETRY_WAIT=0 run_full "" "$C4" app "$C1"; RC=$?
expect "Pull: ein NotFound-Fehler, zweiter Versuch gelingt -> Exit 0" "0" "$RC"
expect "Pull: genau zwei Pull-Versuche" "2" "$(grep -c '^docker compose pull' "$WORK/fake.log")"
grep -q 'Versuch 1 von 3' "$WORK/full.out" && ok "Pull: laute Warnung mit Versuchszähler" || fail "Pull: keine Warnung"
expect "Pull: Vermerk nach Erfolg geschrieben" "$C4" "$(marker "$SERVER/app")"
rm -f "$WORK/fake.log.pulln"
FAKE_PULL_FAILS=9 PULL_RETRY_WAIT=0 run_full "" "$C4" app "$C1"; RC=$?
[ "$RC" -ne 0 ] && ok "Pull: dauerhaft NotFound -> Lauf rot nach 3 Versuchen" || fail "Pull: dauerhafter Fehler wird verschluckt"
expect "Pull: genau drei Versuche, dann Schluss" "3" "$(grep -c '^docker compose pull' "$WORK/fake.log")"
grep -q 'scheiterte 3 Mal' "$WORK/full.out" && ok "Pull: laute Fehlermeldung" || fail "Pull: keine Fehlermeldung nach 3 Versuchen"
expect "Pull: ... kein Vermerk (nichts ausgerollt)" "-" "$(marker "$SERVER/app")"
rm -f "$WORK/fake.log.pulln"
FAKE_PULL_FAILS=9 FAKE_PULL_MSG="unauthorized: authentication required" PULL_RETRY_WAIT=0 run_full "" "$C4" app "$C1"; RC=$?
[ "$RC" -ne 0 ] && ok "Pull: anderer Fehler -> Lauf rot" || fail "Pull: anderer Fehler wird verschluckt"
expect "Pull: anderer Fehler wird NICHT wiederholt (ein Versuch)" "1" "$(grep -c '^docker compose pull' "$WORK/fake.log")"
rm -f "$WORK/fake.log.pulln"
FAKE_PULL_FAILS=1 FAKE_PULL_LONG=1 PULL_RETRY_WAIT=0 run_full "" "$C4" app "$C1"; RC=$?
expect "Pull: Fehler steht VOR 600 kB Ausgabe (SIGPIPE-Fall) -> trotzdem Wiederholung, Exit 0" "0" "$RC"
expect "Pull: ... zwei Versuche" "2" "$(grep -c '^docker compose pull' "$WORK/fake.log")"
rm -f "$WORK/fake.log.pulln"

echo "== Build-Label"
BUILD_LABEL=$(ruby -ryaml -e 'wf=YAML.load_file(ARGV[0]); s=wf["jobs"]["full-deploy"]["steps"].find{|x| x["name"]=="Build and push Docker image"}; puts s["with"]["labels"]' "$WF")
expect "Build setzt das Revision-Label" "org.opencontainers.image.revision=\${{ github.sha }}" "$(printf '%s' "$BUILD_LABEL" | head -n 1)"

echo "== Ergebnis: $PASS ok, $FAIL fehlend"
[ "$FAIL" -eq 0 ]
