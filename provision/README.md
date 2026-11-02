# Slipway provisioning

Two ways to put a builder on DigitalOcean. Pick by how much isolation you need
versus how fast you need the machine.

The API token is read from `DO_API_TOKEN` (or `DIGITALOCEAN_TOKEN`) at call
time. It is passed to the API over stdin, never written to disk, never put in
the process arguments, and never printed.

---

## Pattern A — clone from a snapshot (instant capacity)

A snapshot is the fastest path: the toolchain, package cache, and base config
already exist. The risk is that a snapshot taken from a live box also contains
live production services. The clone must be stripped before it does anything.

```bash
export DO_API_TOKEN="$(cat "$HOME/.config/slipway/do-token")"

./provision.sh \
  --name builder-1 \
  --snapshot SNAPSHOT_ID \
  --region nyc3 \
  --size s-2vcpu-4gb \
  --ssh-keys "SSH_KEY_ID" \
  --user-data ./user-data/strip-clone.sh \
  --wait
```

`user-data/strip-clone.sh` reads `/etc/slipway/production-services.conf` (one
systemd unit per line) and runs `systemctl disable --now` on each named unit.
If the config file is missing, the script fails rather than leaving production
services running. Put the real unit list in an external file or an external
secret store; never commit it.

Inputs:

| Input | How |
| --- | --- |
| API token | `DO_API_TOKEN` in the environment at call time |
| Base image | `--snapshot SNAPSHOT_ID` |
| Service list | `/etc/slipway/production-services.conf` on the clone |
| SSH access | `--ssh-keys` with key ids/fingerprints already in the account |
| Agent env | delivered after boot into a 0600 file outside git |
| Region / size | `--region`, `--size` |

---

## Pattern B — fresh stock image (isolation by default)

A fresh image starts clean. It takes longer because bootstrap installs the
toolchain, but there is no production state to inherit and no strip step.

```bash
export DO_API_TOKEN="$(cat "$HOME/.config/slipway/do-token")"

./provision.sh \
  --name builder-2 \
  --image ubuntu-24-04-x64 \
  --region nyc3 \
  --size s-2vcpu-4gb \
  --ssh-keys "SSH_KEY_ID" \
  --user-data ./user-data/bootstrap.sh \
  --wait
```

`user-data/bootstrap.sh`:

1. installs base packages;
2. installs Node 22 from the NodeSource setup script;
3. installs a pinned `opencode-ai` version;
4. clones the repos listed in `/etc/slipway/repos.conf`;
5. writes `/etc/slipway/agent-env` with mode 0600 and empty placeholder keys.

Render the user-data with your repo list (or include a separate config file),
then fill the agent env after boot. The repo config format is:

```text
# <name> <git-url> [branch]
builder-repo git@example.com:org/repo.git main
```

Inputs:

| Input | How |
| --- | --- |
| API token | `DO_API_TOKEN` in the environment at call time |
| Base image | `--image ubuntu-24-04-x64` (or another stock slug) |
| Repo list | `/etc/slipway/repos.conf` |
| Agent env | `/etc/slipway/agent-env`, mode 0600, filled after boot |
| SSH access | `--ssh-keys` |
| Region / size | `--region`, `--size` |

---

## Common flags

```text
--name NAME          required
--snapshot ID        boot from a snapshot
--image SLUG         boot from a stock image (default: ubuntu-24-04-x64)
--region REGION      default: nyc3
--size SIZE          default: s-2vcpu-4gb
--ssh-keys "A B"     space-separated ids or fingerprints
--tag TAG            repeatable
--user-data FILE     cloud-init/user-data file
--wait               poll until active, then print the public IP
--timeout SECONDS    wait timeout (default: 600)
--dry-run            print the request shape, call nothing
```

The script prints a small receipt:

```text
DROPLET_ID=...
DROPLET_NAME=builder-1
DROPLET_IP=203.0.113.10
```

Addresses in examples are TEST-NET placeholders, not real hosts.

---

## Safety checklist

- Token comes from the environment, never from a committed file.
- Snapshot clones get `strip-clone.sh` before any agent runs.
- Repo lists, service lists, hostnames, and agent env values live outside git.
- `agent-env` is mode 0600 and never leaves the machine.
- Use the safety gate in `scripts/safety-scan.sh` before publishing anything.
