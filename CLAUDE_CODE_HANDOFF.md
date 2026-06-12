# PegaProx - Path C Development Handoff
## For Claude Code running locally (Windows) - testing via Overwatch deploy cycle

---

## Read This First

This document is the complete working context for implementing **Path C** - a
pairing-time security hardening feature for PegaProx. Read every section before
touching any code. The constraints in this document exist for specific reasons
documented below.

### STOP - Do These Before Writing Any Code

#### 1. Audit the existing CIS Hardening feature

PegaProx already ships a **CIS Hardening** feature and a **CVE Scanner** that
operate via SSH against Proxmox nodes. These may already implement some or all
of what Path C proposes. Before writing anything new:

- Search the codebase for `harden`, `cis`, `debsecan`, `cvescanner` across
  all files in `pegaprox/api/`, `pegaprox/core/`, `pegaprox/utils/`
- Understand exactly what the existing hardening feature does via SSH
- Determine whether sudo installation and sudoers deployment are already part
  of it or a gap it leaves open

**Path C should extend or integrate with the existing hardening feature, not
duplicate it.**

Note: Issue #175 (v0.9.2) showed the Harden PVE Node feature failing with
SSH errors. Verify whether this is resolved in the current codebase (now at
v0.9.13) and understand the fix before building on top of it.

#### 2. Review all branches before assuming main is the right base

The fork includes all upstream branches as of the fork date. Inspect them:

```bash
git branch -a | grep -v HEAD | sort
```

Pay specific attention to branches containing: `security`, `hardening`,
`harden`, `cis`, `node`, `pairing`, `aikido`. The upstream team had active
security hardening work in v0.9.12 via the Aikido batch. There may be a
relevant in-progress branch with code worth reviewing before implementing
Path C fresh.

#### 3. Branch currency - ALREADY DONE

`Secure-LXC` has already been merged with upstream `main` (which is at
v0.9.13). Merge commit `e97c5c4` is on top of the v0.9.13 release. Confirm
this matches what you see locally:

```bash
git log --oneline -5
```

Expected top commit: `e97c5c4 Merge remote-tracking branch 'origin/main' into Secure-LXC`

If your local clone doesn't show this, run `git fetch origin && git pull
origin Secure-LXC` before proceeding.

---

## Environment

| Item | Value |
|---|---|
| Local dev machine | Windows 10, Ryzen x86/64, VSCode + Claude Code |
| Repo location (local) | Wherever you cloned `git@github.com:DarmokNoob/project-pegaprox.git` |
| Working branch | `Secure-LXC` |
| Deployment target | Overwatch - Raspberry Pi 4 4GB, PiKVM OS, `192.168.113.30` |
| Proxmox nodes | Watchguard `192.168.113.10` (primary), Guardwatch `192.168.113.110` (secondary) |

### Split Workflow - Read This Before Doing Anything

**Code analysis and writing happens here, locally.** This is where the
actual development work happens - reviewing files, implementing
`node_hardening.py`, editing `vms.py`, etc.

**You have SSH access to the deployment targets** via `~/.ssh/config` short
names: `overwatch`, `watchguard`, `guardwatch` - all root, key-based, no
password prompts. This closes the feedback loop without round-tripping
through Colin for every iteration:

1. Implement / edit code locally
2. Commit and push to `Secure-LXC`
3. `ssh overwatch '~/pegaprox-dev-deploy.sh'` - pulls latest and restarts
   the dev container (no rebuild needed, `/app/pegaprox` is volume-mounted
   to the live repo checkout on Overwatch)
4. `ssh overwatch 'docker logs --tail 50 pegaprox-dev'` - check it started
   cleanly
5. Trigger whatever you're testing (replication job, node pairing, etc.)
   via the dev container's API if needed, or run validation checks directly:
   ```bash
   ssh guardwatch "command -v sudo && echo sudo OK"
   ssh guardwatch "visudo -c -f /etc/sudoers.d/pegaprox && echo sudoers OK"
   ssh guardwatch "stat -c '%a' /etc/sudoers.d/pegaprox"
   ssh guardwatch "systemctl is-active auditd && echo auditd OK"
   ssh guardwatch "test -f /etc/audit/rules.d/pegaprox.rules && echo rules OK"
   ssh guardwatch "ausearch -k pegaprox_lxc 2>/dev/null | tail -20"
   ```
6. Iterate based on results - edit, push, redeploy, retest

If the dev container isn't running or needs to be recreated from scratch
(e.g. after an image update), `ssh overwatch '~/pegaprox-dev-run.sh'` -
occasional/setup only, normal iteration uses `pegaprox-dev-deploy.sh`.

### Guardrails on SSH Usage

**SSH is for execution and observation, not development.**

- DO run deploy scripts, restart containers, tail logs, run validation
  commands, query `pct`/`qm`/`systemctl`/`auditd` state on the targets
- DO NOT edit files directly on Overwatch/Watchguard/Guardwatch over SSH -
  all code changes happen in the local repo, committed and pushed, then
  pulled via the deploy script
- DO NOT start any persistent session, language server, file watcher, or
  IDE-like process on any remote host - this is exactly the pattern that
  overloaded the Pi previously. One-shot commands only.
- DO NOT modify the production `pegaprox` container (ports 5000-5002) -
  only `pegaprox-dev` (ports 5010-5012) and its isolated data directory
  are in scope
- If something needs fixing on a remote host itself (not in the repo) -
  e.g. a permissions issue in `/mnt/usb/pegaprox-dev/data` - a single SSH
  command to fix it is fine. Standing up new infrastructure or multi-step
  remote configuration is not - flag it for Colin instead.

### Deployment Target Reference

| Item | Value |
|---|---|
| Overwatch | `192.168.113.30` / `overwatch.thematrix.lan` (SSH alias: `overwatch`) |
| Dev container name | `pegaprox-dev` |
| Dev container image | `ghcr.io/pegaprox/pegaprox:latest` |
| Dev data dir (isolated) | `/mnt/usb/pegaprox-dev/data` |
| Repo on Overwatch | `/mnt/usb/root-home/repos/project-pegaprox` (alias `~/repos/project-pegaprox`) |
| Dev web UI | `https://overwatch.thematrix.lan:5010` |
| Primary Proxmox node | Watchguard - `192.168.113.10` / `watchguard.thematrix.lan` (SSH alias: `watchguard`) |
| Secondary Proxmox node | Guardwatch - `192.168.113.110` / `guardwatch.thematrix.lan` (SSH alias: `guardwatch`) |

**Your job is not done until the code is pushed AND verified working** via
the SSH-based checks above. If validation fails, iterate - edit, push,
redeploy, retest - before reporting completion.

---

## What PegaProx Is

PegaProx is a Proxmox cluster management and LXC/VM replication tool. It runs
as a Docker container and manages multiple Proxmox nodes (Watchguard and
Guardwatch above).

It communicates with Proxmox nodes via two channels:
1. **Proxmox REST API** - standard cluster management operations
2. **SSH via paramiko** - operations Proxmox does not expose through its API

The SSH connection pool lives in `pegaprox/utils/ssh_pool.py`. PegaProx uses
paramiko to execute varied commands over persistent SSH connections. This is
not a single fixed command - it sends many different operations depending on
the feature being used.

---

## The Security Finding - Read Carefully

### The Silent Privilege Escalation

In `pegaprox/core/manager.py`, the `_create_session()` method (~line 420)
contains an if/else auth flow:

1. Attempt API token authentication first
2. If the token receives 403 Forbidden (which it will for certain operations),
   silently set `self._api_token = None`
3. Fall back to username/password ticket authentication
4. Every subsequent `_api_put()` call automatically rides the ticket

**The ticket authenticates as root@pam.** This is not logged at a level that
makes the escalation obvious. The operator has limited visibility that this
escalation has occurred unless they inspect the network session or read INFO
logs carefully.

### Live Evidence (Captured from the Dev Container)

This exact behavior was observed live against Watchguard when the dev
container started up:

```
[PegaProx_Primary Network Stack] WARNING: API Token auth failed at watchguard.thematrix.lan: 401
[PegaProx_Primary Network Stack] INFO: Stored API token rejected, trying password auth
[PegaProx_Primary Network Stack] INFO: Successfully connected to Proxmox at watchguard.thematrix.lan
```

This confirms the fallback is real, occurs on a live node, and the only
visibility into it is these three log lines at WARNING/INFO level - no
distinct audit event, no flag, nothing that would surface in a dashboard or
alert. Use this as a concrete reference when reviewing `_create_session()`.

### Why root@pam Is Required

Proxmox hardcodes an identity check in `LXC.pm`:

```perl
return 1 if $authuser eq 'root@pam';
```

This is an identity check, not a permission check. No API token - regardless
of granted permissions - can pass it. It gates:
- Setting LXC feature flags (`mknod`, `fuse`, `keyctl`, `nfs`, `cifs`)
- Certain other LXC configuration operations

### What Legitimately Requires root SSH

PegaProx's own documentation explicitly states these features require full
root SSH access and will not work with limited credentials:

- **Rolling Updates** - runs `apt`, `systemctl` across nodes
- **SMBIOS Auto-Config** - writes hardware-level configuration
- **2-Node HA** - fencing and heartbeat operations
- **Node Shell** - it is a root shell by design

**DO NOT attempt to restrict these operations.** They are intentional design
requirements driven by what Proxmox does not expose via API. Any sudoers
policy that tries to scope these will break legitimate PegaProx functionality.

---

## What Path C Is

Path C is a **pairing-time security hardening feature** that deploys OS-layer
controls to Proxmox nodes when they are added to PegaProx management.

### What It Does

When a new Proxmox node is paired with PegaProx, the pairing process
additionally:

1. **Installs sudo** via `apt install sudo` if not present (Debian managed
   package, not affected by Proxmox updates)
2. **Deploys `/etc/sudoers.d/pegaprox`** - a scoped sudoers policy
   specifically for LXC replication operations
3. **Installs auditd** if not present
4. **Deploys `/etc/audit/rules.d/pegaprox.rules`** - audit rules that log
   every invocation of the scoped commands and watch the sudoers file for
   modifications

### What the Sudoers Policy Covers

The sudoers policy is scoped to LXC replication and feature flag restoration
operations **only**:

```
/usr/bin/vzdump *
/usr/sbin/pct start *
/usr/sbin/pct stop *
/usr/sbin/pct status *
/usr/sbin/pct config *
/usr/sbin/qm start *
/usr/sbin/qm stop *
/usr/sbin/qm status *
/usr/sbin/qm config *
```

Audit log target: `/var/log/pegaprox-sudo.log`

### What It Does NOT Do

- Does not restrict PegaProx's SSH root access for Rolling Updates, SMBIOS,
  HA, or Node Shell
- Does not deploy AppArmor profiles (deferred - paramiko's multi-command SSH
  pattern makes host-side AppArmor impractical without breaking PegaProx
  features)
- Does not conflict with Nico Schmidt's (MrMasterbay) proxmox-security-hardening
  script - our files live in separate paths and are additive
- Does not conflict with community-scripts.org scripts

### The Audit Trail

sudo logs every invocation to syslog natively. The homelab forwards syslog to
a central syslog-ng collector on pfSense Secondary (`192.168.113.3:514`). The
audit trail flows automatically into the existing log pipeline with no
additional instrumentation.

---

## Key Files to Review Before Implementing

Review these files in order before writing any new code. Understand the
existing patterns before adding to them.

### 1. `pegaprox/core/manager.py`
- `_create_session()` - the auth fallback that produces the silent escalation
  (see live evidence above)
- `_api_put()` - how subsequent API calls use the escalated session
- `_ssh_connect()` - how SSH sessions are established to nodes
- Understand the Manager class lifecycle before adding anything to it

### 2. `pegaprox/utils/ssh_pool.py`
- How paramiko connections are pooled and reused
- What commands are executed and how results are returned
- This is the layer Path C hardening commands will use to reach nodes

### 3. `pegaprox/api/vms.py`
- How node pairing is currently handled (find the add-node endpoint)
- How existing post-pairing operations are structured
- The pattern for returning success/failure from node operations

### 4. `pegaprox/background/cross_cluster_replication.py`
- The LXC replication pipeline - this is the surface the sudoers policy covers
- Patches already applied (verify present after the v0.9.13 merge): duplicate
  job prevention, hostname restore, MAC restore, feature flag restore

### 5. Any existing hardening-related code
- Check if a `harden` module, endpoint, or utility already exists
- The "Harden PVE Node" feature in PegaProx scans for compliance but does
  not deploy controls - Path C is the deployment counterpart

---

## Implementation Approach

### New Module

Create `pegaprox/utils/node_hardening.py`:

- Function: `deploy_pairing_hardening(ssh_connection, node_host)`
- Uses the existing SSH connection pool to execute hardening commands
- Returns a structured result: `{success: bool, steps: [{name, status, detail}]}`
- Each step (sudo install, sudoers deploy, auditd install, audit rules deploy)
  is independent - failure of one step should not abort others, but all
  results must be reported
- Validates each step after execution (visudo -c on the sudoers file, etc.)
- Idempotent - safe to run multiple times on the same node

### Integration Point

Hook into the existing node pairing flow in `vms.py`. After the node is
successfully added and validated, call `deploy_pairing_hardening()`. The
result should be:
- Logged regardless of outcome
- Surfaced to the UI as a pairing step result (not a pairing blocker - a
  hardening failure should warn, not prevent the node from being added)

### The Sudoers File Content

Deploy this exactly - validate with `visudo -c -f` before leaving it in place,
remove it if validation fails:

```
# =============================================================
# PegaProx Scoped Sudoers Policy
# Generated by PegaProx pairing process
# Scope: LXC replication operations only
# Rolling Updates / SMBIOS / HA / Node Shell use root SSH directly
# =============================================================

Defaults:root    logfile=/var/log/pegaprox-sudo.log
Defaults:root    log_year
Defaults:root    log_host

root ALL=(ALL) NOPASSWD: /usr/bin/vzdump *
root ALL=(ALL) NOPASSWD: /usr/sbin/pct start *
root ALL=(ALL) NOPASSWD: /usr/sbin/pct stop *
root ALL=(ALL) NOPASSWD: /usr/sbin/pct status *
root ALL=(ALL) NOPASSWD: /usr/sbin/pct config *
root ALL=(ALL) NOPASSWD: /usr/sbin/qm start *
root ALL=(ALL) NOPASSWD: /usr/sbin/qm stop *
root ALL=(ALL) NOPASSWD: /usr/sbin/qm status *
root ALL=(ALL) NOPASSWD: /usr/sbin/qm config *
```

Permissions: `chmod 440 /etc/sudoers.d/pegaprox`

### The Auditd Rules File

Deploy to `/etc/audit/rules.d/pegaprox.rules`:

```
# PegaProx Audit Rules - generated by PegaProx pairing process

# Watch sudoers file for modifications
-w /etc/sudoers.d/pegaprox -p wa -k pegaprox_sudoers

# Watch sudo audit log
-w /var/log/pegaprox-sudo.log -p wa -k pegaprox_sudo_log

# Track replication command invocations
-a always,exit -F arch=b64 -F exe=/usr/bin/vzdump -k pegaprox_backup
-a always,exit -F arch=b64 -F exe=/usr/sbin/pct -k pegaprox_lxc
-a always,exit -F arch=b64 -F exe=/usr/sbin/qm -k pegaprox_vm
```

Load rules after deploy:
```bash
augenrules --load 2>/dev/null || systemctl restart auditd
```

---

## Testing - Run These Yourself via SSH

These are the checks defined earlier in the Split Workflow section. Run them
after each deploy cycle to confirm "done" actually means done.

### Unit-Level

`deploy_pairing_hardening()` will be tested against Guardwatch
(`192.168.113.110`) first - it is the secondary node and the lower-risk test
target.

```bash
ssh root@192.168.113.110 "command -v sudo && echo sudo OK"
ssh root@192.168.113.110 "visudo -c -f /etc/sudoers.d/pegaprox && echo sudoers OK"
ssh root@192.168.113.110 "stat -c '%a' /etc/sudoers.d/pegaprox"  # expect 440
ssh root@192.168.113.110 "systemctl is-active auditd && echo auditd OK"
ssh root@192.168.113.110 "test -f /etc/audit/rules.d/pegaprox.rules && echo rules OK"
```

### Integration

Triggering a cross-cluster LXC replication job from the dev container UI
should result in:
1. Replication completing successfully
2. `/var/log/pegaprox-sudo.log` on the target node showing entries
3. `ausearch -k pegaprox_lxc` on the target node returning audit records
4. Hostname, MAC, and feature flags preserved (existing patches)

### Non-Regression

After hardening is deployed on Guardwatch, these must still work:
- Rolling Updates (if safe to run)
- Node Shell access
- General cluster health checks

These use root SSH directly and must be unaffected by the sudoers policy.

### Idempotency

Running the pairing hardening twice against the same node must:
- Not create duplicate sudoers entries
- Not duplicate auditd rules
- Report that each step was already in place
- Exit cleanly

---

## Commit Convention

Follow the existing PegaProx commit style observed in the repo:

```
feat: add pairing-time node hardening (sudo + auditd) for LXC replication surface
fix: [specific thing fixed]
```

Branch: `Secure-LXC`
Push to: `github.com/DarmokNoob/project-pegaprox`

---

## Context on Related Work

### Existing Patches in the Codebase (Already Merged to v0.9.12)

These are already shipped upstream - do not re-implement them:
- **#455** - duplicate LXC replication job prevention (`_running_jobs` set)
- **#456** - hostname and MAC restoration after cross-cluster migration
- **Feature flag restore** - `mknod`, `fuse`, `keyctl` restoration post-migration

Verify these patches are present in `Secure-LXC` (they should be, given the
v0.9.13 merge brings in everything from v0.9.12 and later).

### Upstream Issues

- **#457** is open - this is the feature request Path C addresses
- Marcus Kellermann (mkellermann97) is holding Path A pending this work
- Nico Schmidt (MrMasterbay) is the architecture owner - this will eventually
  need his review

### Reference Script: pegaprox_pair.sh

A standalone bash script exists that performs the same hardening operations
as a manual pre-pairing tool (SSH connectivity check, key deployment, sudo
install, sudoers deploy with visudo validation, auditd install and rules).
It has not been tested against a live node. Use it as a reference for the
exact command sequence and validation logic if useful - but apply the
decision gate below first.

**Decision gate:** Audit how the existing CIS Hardening and CVE Scanner
features execute commands against nodes. If they use paramiko
`exec_command()` calls in Python, implement Path C the same way for
consistency. If PegaProx already shells out to bash scripts for any node
operations, calling a script from Python is acceptable. Do not mix
approaches - pick one and be consistent with the existing codebase pattern.

If you need the full script contents, ask - it can be provided separately
rather than bloating this document.

---

## What Success Looks Like

A new Proxmox node paired through the PegaProx UI results in:

1. sudo installed on the node
2. `/etc/sudoers.d/pegaprox` deployed with 440 permissions, passing `visudo -c`
3. auditd installed and running
4. `/etc/audit/rules.d/pegaprox.rules` deployed and loaded
5. Pairing UI shows hardening step results (pass/warn per step)
6. All existing PegaProx features work unchanged on the hardened node
7. LXC replication generates sudo audit log entries on the target node
8. Running the hardening step twice against the same node is safe

---

## Do Not

- Do not modify `manager.py` auth logic - the silent escalation is a known
  issue being addressed separately via a future feature request after
  detection engineering review
- Do not attempt to scope PegaProx's SSH operations broadly - Rolling Updates,
  SMBIOS, HA, and Node Shell legitimately need full root SSH
- Do not add AppArmor profiles to Proxmox nodes - the paramiko multi-command
  SSH pattern makes targeted confinement impractical without breaking PegaProx
- Do not modify or assume write access to the production `pegaprox`
  container (ports 5000-5002) or its data directory
  (`/mnt/usb/pegaprox/`) - only `pegaprox-dev` and
  `/mnt/usb/pegaprox-dev/data` are in scope
- Do not push directly to `main` - all work stays on `Secure-LXC`
- Do not edit files on Overwatch/Watchguard/Guardwatch via SSH - see
  Guardrails on SSH Usage above. SSH is for running deploy/validation
  commands and reading output only.
- Do not start any IDE session, language server, or file watcher on a
  remote host - one-shot commands only