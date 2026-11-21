# shared-workflows

Reusable GitHub Actions workflows for all NickHeymann projects.
**All CI/CD runs on a self-hosted Hetzner runner — no GitHub Actions minutes, no paid plan.**

## Why self-hosted

GitHub-hosted Actions minutes are billing-capped. Instead, every repo's build/test/deploy
runs on a self-hosted runner on the Hetzner server (`46.224.6.69`), one lean Docker
runner container per repo (~50 MB idle). This costs nothing per run.

`deploy-hetzner.yml` **defaults `runner: self-hosted`** — a repo using this workflow
needs no `runner:` input to get self-hosted CI.

---

## Onboarding a NEW project (do this once per repo)

1. **Provision a runner for the repo** (from your Mac, `gh` logged in):
   ```bash
   ~/.claude/scripts/ci/provision-runner.sh <repo-name>
   ```
   This registers a self-healing runner container (`gha-runner-<repo>`) on Hetzner.
   It uses a PAT (`gh auth token`) so it re-registers automatically after reboots —
   no expiring registration token to babysit.

2. **Set the two repo secrets** (the deploy job needs them):
   ```bash
   GHCR=$(~/.claude/scripts/credential-helper.sh github-ghcr)
   echo "$GHCR" | gh secret set GHCR_TOKEN --repo NickHeymann/<repo>
   # SSH_PRIVATE_KEY: the deploy key for root@46.224.6.69 (copy from a working repo if new)
   ```
   `GHCR_TOKEN` lets the server pull the freshly-built image from ghcr.io.
   **Expired `GHCR_TOKEN` is the #1 cause of `denied: denied` at the deploy step.**

3. **Reference the shared deploy workflow** in `.github/workflows/deploy.yml`:
   ```yaml
   jobs:
     deploy:
       uses: NickHeymann/shared-workflows/.github/workflows/deploy-hetzner.yml@main
       permissions: { contents: read, packages: write }
       with:
         image-name: nickheymann/<repo>
         deploy-path: /opt/apps/<repo>-production
         # runner: self-hosted is the DEFAULT — no need to set it.
       secrets: inherit
   ```

4. **If the repo has a `tests:` job**, use the containerized self-hosted pattern
   (template: `~/.claude/scripts/ci/TEMPLATE-test-job-self-hosted.yml`, or run
   `~/.claude/scripts/ci/migrate-deploy-yml.py .github/workflows/deploy.yml`).
   The lean runner host has no PHP/Node, so tests run in a `php:8.4-cli` container.

5. **If the repo has a `security-scan.yml`**, use the self-hosted version
   (`~/.claude/scripts/ci/TEMPLATE-security-scan-self-hosted.yml`) — it runs
   trivy/gitleaks/npm-audit as direct CLI calls (the GitHub-Marketplace security
   actions break on self-hosted due to artifact-upload path assumptions).

That's it. Push to `main` → build+test+deploy on Hetzner, zero Actions minutes.

---

## Key facts / gotchas (hard-won)

- **Runner = PAT-based, self-healing.** `provision-runner.sh` writes `ACCESS_TOKEN`
  (a PAT) into `/opt/apps/gha-runner-<repo>/.env`; the myoung34/github-runner image
  mints a fresh registration token on every start. A registration-token-based runner
  (the old way) dies after ~1h on restart with a 404 — don't use it.
- **`NickHeymann` is a User account, not an Org** → GitHub has no shared/org runners
  here. Hence one runner container per repo (cheap, ~50 MB idle each).
- **Containerized test job** uses a manual git checkout (not `actions/checkout`) because
  JS actions need node20 from the runner externals, unreachable inside a `container:` job
  under Docker-out-of-Docker. The checkout wipes the reused workdir (non-ephemeral runner)
  and passes the token via `http.extraheader`, never in the remote URL.
- **`memory_limit`** is set via an ini file in the test container (Pest runs each test in
  a subprocess; a per-process `-d memory_limit` does NOT propagate).
- **`--ignore-platform-reqs`** on `composer install` in CI: the lean container omits
  redis/pgsql/imagick etc. that locked deps declare; tests run on sqlite.
- **Server resources:** Ollama holds ~8 GB RAM and CPU spikes during inference, so CI
  builds are slow and should run roughly one at a time. Builds still complete (buildkit
  is disk-backed); they're just not fast.
- **Runner ops on the server:**
  ```bash
  docker ps --filter name=gha-runner            # list runners
  docker logs gha-runner-<repo> --tail 20       # runner log
  cd /opt/apps/gha-runner-<repo> && docker compose up -d   # restart
  ```

## Deploy startet Zustandsdienste nicht neu (`stateful-services`)

Bisher lief im Deploy `docker compose up -d --force-recreate` ohne Dienstliste und
erzeugte bei jedem Deploy auch Redis und Datenbanken neu. Folge: kurzzeitig
„Connection refused“, Queue-Worker und Scheduler verloren Läufe (EQUON, 16.11. bis 19.11.).

Neue optionale Eingabe `stateful-services` (Ausschlussliste, Dienstnamen aus der
`compose.yml`, durch Leerzeichen, Komma oder Zeilenumbruch getrennt). Standard:
`redis valkey keydb memcached postgres postgresql pgsql db database mysql mariadb mongo mongodb rabbitmq minio`.

Ablauf je Deploy-Pfad (auch `extra-deploy-paths`):

1. `docker compose up -d <Zustandsdienste>`: Compose erzeugt einen Dienst nur neu, wenn
   sich Image oder Konfiguration geändert haben, fehlende Dienste werden gestartet.
   Ein geändertes Redis- oder Postgres-Image wird also trotzdem übernommen.
2. `docker compose up -d --force-recreate --no-deps <übrige Dienste>`: Anwendungsdienste
   (app, queue, scheduler, ...) wie bisher zwangsweise neu.

`stateful-services: ''` stellt das alte Verhalten wieder her. Heißt der Redis- oder
Datenbankdienst eines Repos anders als in der Liste, den Namen in `stateful-services`
ergänzen (die Eingabe ersetzt den Standard, also die Standardliste mitgeben).
Verfügbar ab der Version, die diese Änderung trägt (siehe Tag-Liste im PR); ältere Tags
behalten das alte Verhalten.

## Quick-Deploy: Basis-Vermerk und Guards

Der Quick-Deploy (Views, Sprachdateien, CSS/JS, Bilder ohne Image-Build) ist nur aktiv,
wenn das Repo `app-container` setzt.

**Basis statt Vorgänger-Commit.** Früher verglich `detect-changes` nur `HEAD~1` mit `HEAD`.
Brach `concurrency: cancel-in-progress` (oder ein Handabbruch, ein Fehlschlag) den Lauf
für Commit A ab und der Folge-Commit B enthielt nur Views oder `nginx.conf`, übertrug der
Quick-Deploy von B nur B's Diff: die PHP-Änderungen von A kamen nie an, obwohl `main` grün
meldete (nickheymann-tall, 76681c7 und e0988ad, 21.11.2026).

Jetzt gilt ein Basis-Vermerk am Ziel (`<deploy-path>/.quick-deploy-basis`, nur bei gesetztem
`app-container`):

- Er wird **vor der ersten Änderung am Ziel gelöscht** (Full-Deploy vor `docker compose pull`,
  Quick-Deploy vor dem ersten `docker cp`). Bricht ein Lauf ab oder scheitert, bleibt kein
  veralteter Vermerk gültig.
- Er wird **erst nach vollständigem Erfolg neu geschrieben** (atomar über `.tmp` + `mv`):
  Full-Deploy nach compose up, post-deploy-commands und Extra-Pfaden, mit der Revision aus dem
  Label `org.opencontainers.image.revision` des laufenden App-Containers (der Build setzt es auf
  `github.sha`), also gebunden an das wirklich gestartete Image und nicht an einen Lauf, dessen
  `:latest` überschrieben wurde. Quick-Deploy nach Kopieren und gelungenem OPcache-Reset
  (scheitert der Reset, bleibt der Vermerk weg).
- Der Quick-Deploy beansprucht den Vermerk per atomarem Umbenennen und vergleicht ihn mit der
  Basis, auf der `detect-changes` entschieden hat. Hat ein anderer Deploy den Stand am Ziel
  inzwischen geändert (Vermerk weg oder anders), bricht er rot ab, ohne etwas auszurollen. Er
  überschreibt nie einen Vermerk, den ein anderer Deploy inzwischen gesetzt hat. Der Full-Deploy
  löscht zusätzlich die Vermerke seiner Extra-Pfade.
- Der gesamte schreibende Teil von Quick- und Full-Deploy läuft unter einer Sperre je Pfad
  (`flock` auf `<pfad>/.deploy.lock`, util-linux ist am Server vorhanden). Der Full-Deploy sperrt
  Hauptpfad und Extra-Pfade, sortiert (kein Verklemmen bei vertauschten Pfaden). Die Sperre hält
  ein eigener Hilfsprozess, der endet, sobald das Deploy-Skript endet: Hintergrundprozesse aus
  `pre-/post-deploy-commands` erben sie nicht. Ein zweiter Lauf wartet mit Frist (Quick 120 s,
  Full 300 s je Pfad) und scheitert danach laut, er läuft nie parallel. Ein nach einem
  GitHub-Abbruch weiterlaufendes Deploy-Skript hält die Sperre bis zu seinem Ende.
  Temporäre Vermerk-Dateien sind laufbezogen (`.tmp.<PID>`).
- Staging am Server je Lauf: `/tmp/quick-deploy-<run_id>-<run_attempt>-<Zufall>-a<aktueller Versuch>` (Name aus `detect-changes`, je Aufruf eindeutig, auch bei
  Matrix-Aufrufen und Teil-Reruns) statt eines festen Pfads, damit gleichzeitige Quick-Deploys nichts vertauschen. Ein Schritt
  `Remove staging dir on server` (`if: always()`) räumt es auch bei Fehler oder Abbruch auf.
- Schutz gegen alte Wiederholungen: Ist der zu deployende Commit ein Vorfahr des Vermerks
  (`git merge-base --is-ancestor`), bricht `detect-changes` mit klarer Meldung ab (gilt damit für
  Quick und Full, nur wenn ein Vermerk existiert). Gleicher Commit (Rerun desselben Stands) läuft
  normal. Lässt sich die Historie nicht vollständig laden, bricht der Lauf ab. Der Full-Deploy prüft unter der
  Server-Sperre erneut, dass der Vermerk noch der geprüfte ist (sonst Abbruch, Lauf wiederholen). Für einen bewussten Rückschritt: Revert-Commit pushen oder den Vermerk am Ziel löschen.
- `docker compose pull` wird bei dem Fehler `NotFound: content digest` (und `lease does not exist`) des
  containerd-Image-Speichers höchstens dreimal im Abstand von 15 Sekunden wiederholt, mit lauter
  Warnung je Versuch und Fehlermeldung nach dem dritten. Ursache ist ein gleichzeitiger
  `docker image prune` auf dem gemeinsamen Server, der die Lease eines laufenden Pulls löscht
  (moby/moby#53321). Jeder andere Pull-Fehler schlägt sofort fehl.
- **Hostweite Docker-Sperre** (eigentliche Ursache dieses Fehlers): Der Full-Deploy hält
  `/var/lock/docker-image.lock` **geteilt** (`flock -s`, Frist 300 s) von vor `docker compose pull` bis
  nach `compose up` und den Post-Deploy-Befehlen. Jedes Aufräumen (`docker image prune`, `builder prune`)
  muss sie **exklusiv** halten (`flock -x`) und wartet nur begrenzt: ist sie nicht frei, wird das Aufräumen
  übersprungen, statt in einen Deploy zu laufen. Das Aufräumen am Ende des Deploys folgt derselben Regel
  (Sperre geteilt freigeben, dann exklusiv mit 60 s Frist, bei Frist übersprungen mit Warnung). Hält ein
  Prune die Sperre länger als 300 s, bricht der Deploy laut ab, bevor etwas ausgerollt ist. Server-Skripte
  mit Prune (Cron, Aufräumskripte) müssen auf dieselbe Sperre umgestellt werden, sonst bleibt nur die
  Wiederholung oben als zweite Sicherung. Der Quick-Deploy zieht kein Deploy-Image und braucht die Sperre
  nicht. Grenze: die Schritte, die im Runner-Container laufen (Basis-Images `php`/`node` des Quick-Deploys,
  `alpine` des Build-Platzes), sehen die Sperre des Hosts nicht. Dort gilt nur die Wiederholung (Pull der
  Basis-Images mit höchstens drei Versuchen bei `NotFound: content digest`). Eine vollständige Lösung
  bräuchte `/run/lock` als Bind-Mount in den Runner-Containern (Serveränderung, offene Entscheidung).
- `nginx.conf` wird von keinem der beiden Deploys ausgerollt (am Server von Hand gepflegt). Ändert
  sich die Datei, meldet der Lauf das als Warnung und in der Zusammenfassung, statt sie still als
  ausgerollt zu führen.
- `detect-changes` liest den Vermerk per ssh und diffet `Basis..HEAD`. Der Full-Deploy läuft (fail
  closed), wenn der Vermerk fehlt, kein 40-stelliger SHA ist, nicht lesbar ist oder der
  Basis-Commit nicht abrufbar ist. Folge: der erste Deploy nach der Umstellung auf eine Version
  mit Basis-Vermerk ist immer ein Full-Deploy (Vermerk fehlt noch), ebenso der Deploy nach jedem
  abgebrochenen oder fehlgeschlagenen Lauf.

Eine Wiederholung eines alten Laufs setzt den Vermerk auf dessen Commit zurück (der Stand am
Ziel ist dann tatsächlich der alte); der nächste Push holt die Differenz nach.

**`public/images/` ist optional.** Wie `lang/` wird das Verzeichnis nur hochgeladen und
kopiert, wenn es im Repo existiert (master-admin hat keins im Git; ohne Guard brach der
rsync-Schritt ab).

Test (Trockenlauf des Shell-Teils gegen ein Attrappen-Repo, loest keinen Deploy aus):
`tests/test-quick-deploy.sh` (Voraussetzung: bash, git, ruby). Mit einer älteren Fassung der
Workflow-Datei als Argument muss er rot werden.

## Tooling (on the Mac, ~/.claude/scripts/ci/)

| Script | Purpose |
|---|---|
| `provision-runner.sh <repo>` | Register/repair a self-healing runner for a repo |
| `migrate-deploy-yml.py <file>` | Convert a deploy.yml's test job → self-hosted + set runner |
| `migrate-repo-workflows.sh <repo>` | Migrate deploy + security-scan + dependabot for a repo |
| `TEMPLATE-test-job-self-hosted.yml` | Canonical containerized test job |
| `TEMPLATE-security-scan-self-hosted.yml` | Self-hosted security scan (direct tool calls) |
