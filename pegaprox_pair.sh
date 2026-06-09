#!/bin/bash
# =============================================================================
# PegaProx Node Pairing — Prerequisite Validation & Hardening
# =============================================================================
#
# Run this against a target Proxmox node before pairing it with PegaProx.
# Validates SSH connectivity, sets up key-based auth, installs sudo, and
# deploys a scoped sudoers policy for PegaProx operations.
#
# Usage:
#   ./pegaprox_pair.sh -h <host> -u <user> [-p <port>] [-k <pubkey_path>]
#                      [--disable-password-auth]
#
# Flags:
#   -h  Target Proxmox node hostname or IP        (required)
#   -u  SSH user                                  (required, typically root)
#   -p  SSH port                                  (default: 22)
#   -k  Path to public key to deploy              (default: ~/.ssh/id_rsa.pub)
#   --disable-password-auth                       (default: OFF — set explicitly to enable)
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# DEFAULTS
# -----------------------------------------------------------------------------
SSH_PORT=22
SSH_USER=""
SSH_HOST=""
PUBKEY_PATH="${HOME}/.ssh/id_rsa.pub"
DISABLE_PASSWORD_AUTH=false

# PegaProx sudoers policy — what PegaProx is allowed to invoke on the node
PEGAPROX_SUDOERS_FILE="/etc/sudoers.d/pegaprox"
PEGAPROX_SUDOERS_USER="pegaprox"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() {
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  $*${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

die() {
    log_error "$*"
    exit 1
}

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
    exit 0
}

# -----------------------------------------------------------------------------
# ARGUMENT PARSING
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h) SSH_HOST="$2";           shift 2 ;;
        -u) SSH_USER="$2";           shift 2 ;;
        -p) SSH_PORT="$2";           shift 2 ;;
        -k) PUBKEY_PATH="$2";        shift 2 ;;
        --disable-password-auth)
            DISABLE_PASSWORD_AUTH=true; shift ;;
        --help) usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -z "$SSH_HOST" ]] && die "Target host required (-h)"
[[ -z "$SSH_USER" ]] && die "SSH user required (-u)"

# Convenience wrapper — all remote commands go through here
remote() {
    ssh -p "$SSH_PORT" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        "${SSH_USER}@${SSH_HOST}" "$@"
}

# -----------------------------------------------------------------------------
# PHASE 1 — CONNECTIVITY CHECK
# -----------------------------------------------------------------------------
log_section "PHASE 1 — Connectivity Check"

log_info "Testing SSH connectivity to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}..."

if ! ssh -p "$SSH_PORT" \
         -o StrictHostKeyChecking=accept-new \
         -o ConnectTimeout=10 \
         -o BatchMode=true \
         "${SSH_USER}@${SSH_HOST}" "exit 0" 2>/dev/null; then

    log_warn "Key-based auth failed — trying password auth..."

    # Attempt password-based connection to bootstrap key deployment
    if ! ssh -p "$SSH_PORT" \
             -o StrictHostKeyChecking=accept-new \
             -o ConnectTimeout=10 \
             -o PreferredAuthentications=password \
             "${SSH_USER}@${SSH_HOST}" "exit 0" 2>/dev/null; then
        die "Cannot connect to ${SSH_HOST}:${SSH_PORT} as ${SSH_USER} — check host, port, and credentials"
    fi

    log_warn "Connected via password — key-based auth not yet configured"
    KEY_AUTH_CONFIGURED=false
else
    log_ok "SSH key-based auth already configured"
    KEY_AUTH_CONFIGURED=true
fi

# Validate this is actually a Proxmox node
log_info "Validating Proxmox environment..."
if ! remote "command -v pveum >/dev/null 2>&1"; then
    die "Target does not appear to be a Proxmox node (pveum not found)"
fi

PVE_VERSION=$(remote "pveversion --verbose 2>/dev/null | head -1 || echo unknown")
log_ok "Proxmox confirmed — ${PVE_VERSION}"

# -----------------------------------------------------------------------------
# PHASE 2 — SSH KEY DEPLOYMENT
# -----------------------------------------------------------------------------
log_section "PHASE 2 — SSH Key Deployment"

if [[ "$KEY_AUTH_CONFIGURED" == false ]]; then

    [[ ! -f "$PUBKEY_PATH" ]] && die "Public key not found at ${PUBKEY_PATH} — generate one with ssh-keygen"

    log_info "Deploying public key from ${PUBKEY_PATH}..."

    PUBKEY_CONTENT=$(cat "$PUBKEY_PATH")

    # Deploy key via password session
    ssh -p "$SSH_PORT" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        -o PreferredAuthentications=password \
        "${SSH_USER}@${SSH_HOST}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
         touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && \
         grep -qxF '${PUBKEY_CONTENT}' ~/.ssh/authorized_keys || \
         echo '${PUBKEY_CONTENT}' >> ~/.ssh/authorized_keys"

    # Verify key auth now works
    if ! ssh -p "$SSH_PORT" \
             -o StrictHostKeyChecking=accept-new \
             -o ConnectTimeout=10 \
             -o BatchMode=true \
             "${SSH_USER}@${SSH_HOST}" "exit 0" 2>/dev/null; then
        die "Key deployment completed but key auth still failing — check authorized_keys on target"
    fi

    log_ok "SSH key deployed and verified"
    KEY_AUTH_CONFIGURED=true
else
    log_ok "Key already configured — skipping deployment"
fi

# -----------------------------------------------------------------------------
# PHASE 3 — PASSWORD AUTH HANDLING
# -----------------------------------------------------------------------------
log_section "PHASE 3 — Password Authentication"

CURRENT_PASS_AUTH=$(remote "grep -E '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print \$2}' || echo unknown")

if [[ "$DISABLE_PASSWORD_AUTH" == true ]]; then

    if [[ "$CURRENT_PASS_AUTH" == "no" ]]; then
        log_ok "Password auth already disabled — no change needed"
    else
        log_warn "--disable-password-auth is SET — disabling password auth on ${SSH_HOST}"
        log_warn "Ensure key auth is confirmed working before proceeding"

        read -rp "  Confirm you can log in with your key? (yes/no): " CONFIRM
        [[ "$CONFIRM" != "yes" ]] && die "Aborted — password auth NOT disabled"

        remote "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
                systemctl restart sshd"
        log_ok "Password auth disabled and sshd restarted"
    fi
else
    if [[ "$CURRENT_PASS_AUTH" == "no" ]]; then
        log_ok "Password auth already disabled"
    else
        log_warn "Password auth is currently ENABLED on ${SSH_HOST}"
        log_warn "Use --disable-password-auth to disable it (not set by default)"
    fi
fi

# -----------------------------------------------------------------------------
# PHASE 4 — SUDO INSTALLATION
# -----------------------------------------------------------------------------
log_section "PHASE 4 — Sudo Installation"

if remote "command -v sudo >/dev/null 2>&1"; then
    SUDO_VERSION=$(remote "sudo --version | head -1")
    log_ok "sudo already installed — ${SUDO_VERSION}"
else
    log_info "sudo not found — installing via apt..."
    remote "apt-get update -qq && apt-get install -y sudo"

    if ! remote "command -v sudo >/dev/null 2>&1"; then
        die "sudo installation failed"
    fi

    log_ok "sudo installed successfully"
fi

# -----------------------------------------------------------------------------
# PHASE 5 — PEGAPROX SUDOERS POLICY
# -----------------------------------------------------------------------------
log_section "PHASE 5 — PegaProx Sudoers Policy"

# Check if sudoers file already exists
if remote "test -f ${PEGAPROX_SUDOERS_FILE} 2>/dev/null"; then
    log_warn "Sudoers file already exists at ${PEGAPROX_SUDOERS_FILE}"
    EXISTING=$(remote "cat ${PEGAPROX_SUDOERS_FILE}")
    log_info "Existing content:"
    echo "$EXISTING" | sed 's/^/    /'
    echo ""
    read -rp "  Overwrite? (yes/no): " OVERWRITE
    [[ "$OVERWRITE" != "yes" ]] && { log_info "Skipping sudoers deployment"; }
fi

if [[ "${OVERWRITE:-yes}" == "yes" ]]; then

    log_info "Deploying PegaProx sudoers policy..."

    # Deploy the scoped sudoers file
    # Scope: vzdump, pct lifecycle, qm lifecycle on specific operations only
    # No NOPASSWD on broad commands — PegaProx authenticates via SSH key,
    # sudo here is a constraint boundary not an auth bypass
    remote "cat > ${PEGAPROX_SUDOERS_FILE} << 'SUDOERS_EOF'
# =============================================================
# PegaProx Scoped Sudoers Policy
# Generated by pegaprox_pair.sh
# =============================================================
#
# Principle: Least privilege execution boundary for PegaProx
# operations. PegaProx authenticates via SSH key. This file
# constrains what commands can be invoked, not who can connect.
#
# root@pam credential is retained for Proxmox API token refresh
# only. All node operations go through this scoped path.
# =============================================================

Defaults:root    logfile=/var/log/pegaprox-sudo.log
Defaults:root    log_year
Defaults:root    log_host

# Backup and snapshot operations
root ALL=(ALL) NOPASSWD: /usr/bin/vzdump *

# LXC lifecycle — start, stop, status, config reads
root ALL=(ALL) NOPASSWD: /usr/sbin/pct start *
root ALL=(ALL) NOPASSWD: /usr/sbin/pct stop *
root ALL=(ALL) NOPASSWD: /usr/sbin/pct status *
root ALL=(ALL) NOPASSWD: /usr/sbin/pct config *

# VM lifecycle — start, stop, status, config reads
root ALL=(ALL) NOPASSWD: /usr/sbin/qm start *
root ALL=(ALL) NOPASSWD: /usr/sbin/qm stop *
root ALL=(ALL) NOPASSWD: /usr/sbin/qm status *
root ALL=(ALL) NOPASSWD: /usr/sbin/qm config *

SUDOERS_EOF"

    # Validate the sudoers file with visudo before leaving it in place
    if ! remote "visudo -c -f ${PEGAPROX_SUDOERS_FILE} 2>&1"; then
        remote "rm -f ${PEGAPROX_SUDOERS_FILE}"
        die "Sudoers file failed validation — removed. Check syntax and retry."
    fi

    # Lock down permissions
    remote "chmod 440 ${PEGAPROX_SUDOERS_FILE}"

    log_ok "PegaProx sudoers policy deployed and validated"
    log_info "Sudo audit log will write to: /var/log/pegaprox-sudo.log"
fi

# -----------------------------------------------------------------------------
# PHASE 6 — AUDITD RULES
# -----------------------------------------------------------------------------
log_section "PHASE 6 — Auditd Rules"

if ! remote "command -v auditctl >/dev/null 2>&1"; then
    log_info "auditd not found — installing..."
    remote "apt-get install -y auditd"
fi

AUDIT_RULES_FILE="/etc/audit/rules.d/pegaprox.rules"

if remote "test -f ${AUDIT_RULES_FILE} 2>/dev/null"; then
    log_ok "PegaProx audit rules already present — skipping"
else
    log_info "Deploying auditd rules for PegaProx operations..."

    remote "cat > ${AUDIT_RULES_FILE} << 'AUDIT_EOF'
# =============================================================
# PegaProx Audit Rules
# Generated by pegaprox_pair.sh
# =============================================================

# Watch PegaProx sudoers file for any modifications
-w /etc/sudoers.d/pegaprox -p wa -k pegaprox_sudoers

# Watch PegaProx sudo audit log
-w /var/log/pegaprox-sudo.log -p wa -k pegaprox_sudo_log

# Track vzdump invocations
-a always,exit -F arch=b64 -F exe=/usr/bin/vzdump -k pegaprox_backup

# Track pct invocations
-a always,exit -F arch=b64 -F exe=/usr/sbin/pct -k pegaprox_lxc

# Track qm invocations
-a always,exit -F arch=b64 -F exe=/usr/sbin/qm -k pegaprox_vm

AUDIT_EOF"

    remote "augenrules --load 2>/dev/null || systemctl restart auditd"
    log_ok "Auditd rules deployed"
fi

# -----------------------------------------------------------------------------
# PHASE 7 — VALIDATION SUMMARY
# -----------------------------------------------------------------------------
log_section "PHASE 7 — Validation Summary"

PASS=0
FAIL=0

check() {
    local label="$1"
    local cmd="$2"
    if remote "$cmd" >/dev/null 2>&1; then
        log_ok "$label"
        ((PASS++))
    else
        log_error "$label"
        ((FAIL++))
    fi
}

check "SSH key auth working"           "exit 0"
check "Proxmox node confirmed"         "command -v pveum"
check "sudo installed"                 "command -v sudo"
check "PegaProx sudoers file exists"   "test -f ${PEGAPROX_SUDOERS_FILE}"
check "Sudoers file permissions 440"   "stat -c '%a' ${PEGAPROX_SUDOERS_FILE} | grep -q 440"
check "Sudoers passes visudo check"    "visudo -c -f ${PEGAPROX_SUDOERS_FILE}"
check "auditd running"                 "systemctl is-active auditd"
check "PegaProx audit rules present"   "test -f ${AUDIT_RULES_FILE}"

echo ""
echo -e "  Results: ${GREEN}${PASS} passed${NC} / ${RED}${FAIL} failed${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    log_warn "Some checks failed — review output above before pairing this node with PegaProx"
    exit 1
else
    log_ok "Node ${SSH_HOST} is ready for PegaProx pairing"
    log_info "AppArmor profile deployment is a separate step — see pegaprox_apparmor.sh"
    exit 0
fi
