#!/bin/bash
# Nach dem Build-Konflikt am 03.10.2026 begrenzen Containernamen parallele Builds.
# Ein Platz verfällt nach 45 Minuten; beendete Container werden abgeräumt.

slots=${BUILD_SLOTS:-2}
prefix=${BUILD_SLOT_PREFIX:-hetzner-build-slot}
max_wait=${BUILD_SLOT_MAX_WAIT:-2400}
ttl=${BUILD_SLOT_TTL:-2700}
owner_run=${GITHUB_RUN_ID:-}-${GITHUB_RUN_ATTEMPT:-}
owner_job=${GITHUB_JOB:-}

release() {
    [ -n "${BUILD_SLOT:-}" ] || return 0
    # Nach Prüfung nur die Container-ID löschen, damit ein Nachfolger sicher bleibt.
    info=$(docker inspect --format '{{.Id}} {{index .Config.Labels "run"}} {{index .Config.Labels "job"}}' "$BUILD_SLOT" 2>/dev/null) || return 0
    IFS=' ' read -r container_id run_label job_label <<EOF_INFO
$info
EOF_INFO
    if [ "$run_label" = "$owner_run" ] && [ "$job_label" = "$owner_job" ]; then
        docker rm -f "$container_id" >/dev/null || echo "::warning::Build-Platz $BUILD_SLOT konnte nicht freigegeben werden."
    else
        echo "Build-Platz $BUILD_SLOT gehört einem anderen Job und bleibt bestehen."
    fi
    return 0
}

show_holders() {
    i=1
    while [ "$i" -le "$slots" ]; do
        holder=$(docker inspect --format '{{index .Config.Labels "repo"}} ({{index .Config.Labels "run"}} / {{index .Config.Labels "job"}})' "$prefix-$i" 2>/dev/null) || holder='frei oder nicht erreichbar'
        echo "Build-Platz $prefix-$i: $holder"
        i=$((i + 1))
    done
}

acquire() {
    for value in "$slots" "$max_wait" "$ttl"; do
        case "$value" in
            ''|*[!0-9]*) echo '::warning::Ungültige Build-Platz-Konfiguration, Build läuft ohne Platz weiter.'; return 0 ;;
        esac
    done
    if [ "$slots" -eq 0 ] || [ "$ttl" -eq 0 ]; then
        echo '::warning::Plätze und Verfallszeit müssen positiv sein, Build läuft ohne Platz weiter.'
        return 0
    fi
    started=$(date +%s)
    next_log=$started
    failures=0
    while :; do
        slot_index=1
        while [ "$slot_index" -le "$slots" ]; do
            slot="$prefix-$slot_index"
            info=$(docker inspect --format '{{.Id}} {{.State.Running}}' "$slot" 2>/dev/null) || info=''
            IFS=' ' read -r container_id running <<EOF_INFO
$info
EOF_INFO
            if [ "$running" = 'false' ]; then
                docker rm -f "$container_id" >/dev/null 2>&1 || echo "Build-Platz $slot wurde inzwischen verändert oder konnte nicht entfernt werden."
            fi
            if result=$(docker run -d --name "$slot" \
                --label "repo=${GITHUB_REPOSITORY:-}" --label "run=$owner_run" \
                --label "job=$owner_job" --restart no alpine:3.20 sleep "$ttl" 2>&1); then
                if printf 'BUILD_SLOT=%s\n' "$slot" >> "$GITHUB_ENV"; then
                    echo "Build-Platz $slot übernommen."
                else
                    BUILD_SLOT=$slot release
                    echo '::warning::Build-Platz konnte nicht gespeichert werden, Build läuft ohne Platz weiter.'
                fi
                return 0
            fi
            # Namenskonflikte sind normales Warten; Pull-/Daemonfehler zählen separat.
            case "$result" in
                *'Conflict.'*|*'is already in use'*) failures=0 ;;
                *)
                    failures=$((failures + 1))
                    echo "Build-Platz $slot konnte nicht übernommen werden: $result"
                    if [ "$failures" -ge 3 ]; then
                        echo '::warning::Drei Docker-Fehler in Folge, Build läuft ohne Platz weiter.'
                        return 0
                    fi
                    ;;
            esac
            slot_index=$((slot_index + 1))
        done
        now=$(date +%s)
        elapsed=$((now - started))
        if [ "$elapsed" -ge "$max_wait" ]; then
            echo "::warning::Nach $max_wait Sekunden kein Build-Platz frei, Build läuft ohne Platz weiter."
            return 0
        fi
        if [ "$now" -ge "$next_log" ]; then
            show_holders
            next_log=$((now + 60))
        fi
        delay=$((max_wait - elapsed))
        [ "$delay" -le 10 ] || delay=10
        sleep "$delay"
    done
}

case "${1:-}" in
    acquire) acquire ;;
    release) release ;;
    *) echo 'Verwendung: build-slot.sh acquire|release' >&2; exit 2 ;;
esac
