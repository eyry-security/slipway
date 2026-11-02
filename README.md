# Slipway

A builder-orchestrator for agent fleets.

Two keys — a DigitalOcean token and a model key — are enough to spin up
machines, give each one a task, and let the fleet knock out a spec in parallel
branches while Muse manages the queue. Slipway is the part that turns "I have
keys and a spec" into "the work is running on four machines and the reports are
coming back."

Slipway builds Eyry — the system that wrote this README's codebase runs on it daily.

---

## What is in the box

| Path | Purpose |
| --- | --- |
| `run.sh` | Generalized job runner: branch, env, headless agent, progress markers, report check. |
| `provision/` | DigitalOcean droplets from a snapshot or a stock image, with user-data bootstrap. |
| `contracts/` | Prompt, report, status, and probe-job templates distilled from real campaigns. |
| `watchdog.sh` | Queue watcher: IDLE / RUNNING / DONE-UNPICKED / STUCK. |
| `scripts/safety-scan.sh` | Pre-publication gate: secrets in tree + history, plus external banned terms. |
| `agent-env.example` | Placeholder-only env shape. The real file lives outside git, mode 0600. |

Everything deployment-specific is an environment input. No hostnames, tokens,
or fleet values live in the tree.

---

## Quickstart

### 1. Keys

Keep the agent env outside the repo and lock it down:

```bash
$ mkdir -p ~/.config/slipway
$ chmod 700 ~/.config/slipway
$ install -m 600 agent-env.example ~/.config/slipway/agent-env
$ $EDITOR ~/.config/slipway/agent-env
```

The environment file needs `DEEPSEEK_API_KEY` and `OPENCODE_SERVER_PASSWORD`.
The runner checks that those keys are present and never prints their values.

The DigitalOcean token is read only when `provision.sh` is called:

```bash
$ export DO_API_TOKEN="$(cat ~/.config/slipway/do-token)"
```

Do not put either token in a config file that git can see.

### 2. Provision

Fresh image, isolated by default:

```bash
$ ./provision/provision.sh \
    --name builder-1 \
    --image ubuntu-24-04-x64 \
    --user-data ./provision/user-data/bootstrap.sh \
    --wait
```

Snapshot clone, instant capacity:

```bash
$ ./provision/provision.sh \
    --name builder-2 \
    --snapshot SNAPSHOT_ID \
    --user-data ./provision/user-data/strip-clone.sh \
    --wait
```

See `provision/README.md` for the two patterns and the inputs each needs. A
snapshot clone runs `strip-clone.sh` first so live production units named in an
external config are disabled and stopped before an agent touches the machine.

### 3. Probe job

Run the probe before any real dispatch. It verifies the toolchain, the env
keys (by name), the repo checkout, and the report contract on a trivial task:

```bash
$ ./run.sh probe-1 /srv/repo main "$PWD/contracts/probe-job.md"
```

A probe that does not come back `PASS` means the builder is not ready. Fix it
before the queue starts.

### 4. First real job

Copy `contracts/job-prompt.tmpl.md`, fill the task, outcome, constraints, and
report path, then launch:

```bash
$ ./run.sh job-42 /srv/repo vector/job-42 /srv/prompts/job-42.md
```

The runner sources the agent env, cuts `vector/job-42` from `main`, runs the
headless agent, appends `START` / `DONE` to `~/.slipway/job-42-progress.log`,
and expects `~/.slipway/job-42-report.md`.

Watch the queue:

```bash
$ ./watchdog.sh --dir ~/.slipway
```

It prints machine-readable `JOB` and `SUMMARY` lines and exits non-zero on
`DONE-UNPICKED` or `STUCK`.

---

## Runner configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `SLIPWAY_HOME` | `~/.slipway` | Progress logs, run logs, and reports. |
| `SLIPWAY_ENV_FILE` | `~/.config/slipway/agent-env` | Agent env file, outside git. |
| `SLIPWAY_ENV_KEYS` | `DEEPSEEK_API_KEY OPENCODE_SERVER_PASSWORD` | Required keys, checked by name only. |
| `SLIPWAY_NODE_BIN` | empty | Optional directory prepended to `PATH` for the toolchain. |
| `SLIPWAY_AGENT_CMD` | `opencode run --auto` | Headless agent command. |

`run.sh --dry-run` validates the repo, absolute prompt path, branch name, and
env keys, prints the resolved configuration, and exits without launching
anything. A relative prompt path is always a hard failure.

Watchdog inputs: `SLIPWAY_LOG_DIR`, `SLIPWAY_STUCK_MINUTES` (default `180`),
and `SLIPWAY_MAX_HOURS` (default `3`), or the matching flags.

---

## The report contract

Every job writes exactly one report next to its progress log. The shape lives
in `contracts/report.tmpl.md`:

1. status, repo, branch, base, commit;
2. outcome;
3. changes with `file:line` references;
4. tests run and results;
5. decisions and assumptions;
6. risks and follow-ups.

The progress log is the heartbeat:

```text
2026-01-01T00:00:00Z START job-42
2026-01-01T00:42:00Z DONE job-42
```

`run.sh` stamps those lines. The watchdog reads them. A `DONE` with no pick
marker is `DONE-UNPICKED`; a `START` older than the threshold or longer than
three hours is `STUCK`.

---

## Safety gate

Before publishing anything, run the gate with a terms list that lives outside
the repository:

```bash
$ ./scripts/safety-scan.sh \
    --repo . \
    --terms /secure/location/banned-terms.txt \
    --report /tmp/safety-report.txt
```

It scans the working tree and git history for key/token/password assignments,
private key blocks, known token prefixes, credential-bearing URLs, and tracked
env files. It then scans for the external banned terms. The report records
locations and rule names only — never the secret value or the term itself. Any
hit exits non-zero.

The terms list is deliberately external: the list of names you do not want to
publish must not itself be published.

---

## License

MIT. See `LICENSE`.
