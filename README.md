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

## Tooling (on the Mac, ~/.claude/scripts/ci/)

| Script | Purpose |
|---|---|
| `provision-runner.sh <repo>` | Register/repair a self-healing runner for a repo |
| `migrate-deploy-yml.py <file>` | Convert a deploy.yml's test job → self-hosted + set runner |
| `migrate-repo-workflows.sh <repo>` | Migrate deploy + security-scan + dependabot for a repo |
| `TEMPLATE-test-job-self-hosted.yml` | Canonical containerized test job |
| `TEMPLATE-security-scan-self-hosted.yml` | Self-hosted security scan (direct tool calls) |
