#!/usr/bin/env bash
#
# build-iso-hetzner.sh — Build minikube ISO on a Hetzner Cloud ARM64 server
#
# Spins up an ephemeral cax41 (16 vCPU, 32GB RAM, ARM64) builder,
# installs dependencies, clones the repo, runs the Buildroot-based
# ISO build, downloads the result, and tears the server down.
#
# Prerequisites:
#   - hcloud CLI installed and configured (context or HCLOUD_TOKEN)
#   - SSH key registered with Hetzner (passed via --ssh-key)
#   - SSH private key available locally for root@ access
#
# Usage:
#   ./hack/build-iso-hetzner.sh [OPTIONS]
#
# Options:
#   --branch BRANCH        Git branch to build (default: zfs)
#   --repo URL             Git repo URL (default: https://github.com/someara/minikube.git)
#   --server-type TYPE     Hetzner server type (default: cax41)
#   --ssh-key ID           Hetzner SSH key ID or name (default: 106700993)
#   --location LOC         Hetzner datacenter location (default: nbg1)
#   --output PATH          Local path for the built ISO (default: ~/iso/minikube-zfs-arm64-1.iso)
#   --server-name NAME     Name for the builder server (default: iso-builder)
#   --keep-server          Don't tear down the server after build (for debugging)
#   --help                 Show this help message
#
# Examples:
#   # Default build (zfs branch, cax41, downloads to ~/iso/)
#   ./hack/build-iso-hetzner.sh
#
#   # Build a specific branch with a smaller server
#   ./hack/build-iso-hetzner.sh --branch dev --server-type cax31
#
#   # Keep the server alive for debugging a failed build
#   ./hack/build-iso-hetzner.sh --keep-server
#

set -euo pipefail

# ----------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------
BRANCH="zfs"
REPO="https://github.com/someara/minikube.git"
SERVER_TYPE="cax41"
SSH_KEY="106700993"
LOCATION="nbg1"
OUTPUT="${HOME}/iso/minikube-zfs-arm64-1.iso"
SERVER_NAME="iso-builder"
KEEP_SERVER=false
HCLOUD="${HCLOUD:-hcloud}"
SERVER_IP=""

# ANSI colors (disabled if not a terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------
log()   { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn()  { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARNING:${NC} $*"; }
err()   { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*" >&2; }
fatal() { err "$@"; cleanup; exit 1; }

elapsed() {
    local t=$1
    printf '%dh%02dm%02ds' $((t/3600)) $((t%3600/60)) $((t%60))
}

usage() {
    awk '/^# Usage:/,/^[^#]/{if(/^[^#]/)exit; sub(/^# ?/,""); print}' "$0"
    exit 0
}

# SSH wrapper — retries, no host key fuss
ssh_builder() {
    ssh -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=10 \
        "root@${SERVER_IP}" "$@"
}

scp_builder() {
    scp -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        "$@"
}

# Wait for SSH to become available
wait_for_ssh() {
    local max_attempts=30
    local attempt=0
    log "Waiting for SSH on ${SERVER_IP}..."
    while [ $attempt -lt $max_attempts ]; do
        if ssh_builder 'true' 2>/dev/null; then
            log "SSH is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    fatal "SSH not available after $((max_attempts * 5))s"
}

# Cleanup — always tear down unless --keep-server
cleanup() {
    if [ "$KEEP_SERVER" = true ]; then
        if [ -n "$SERVER_IP" ]; then
            warn "Keeping server ${SERVER_NAME} (${SERVER_IP}) alive per --keep-server"
            warn "SSH:    ssh root@${SERVER_IP}"
            warn "Logs:   ssh root@${SERVER_IP} tail -f /root/build.log"
            warn "Delete: ${HCLOUD} server delete ${SERVER_NAME}"
        fi
        return 0
    fi
    if [ -n "$SERVER_IP" ]; then
        log "Tearing down builder ${SERVER_NAME}..."
        "${HCLOUD}" server delete "${SERVER_NAME}" 2>/dev/null && \
            log "Server deleted" || \
            warn "Failed to delete server — clean up manually: ${HCLOUD} server delete ${SERVER_NAME}"
    fi
}

# ----------------------------------------------------------------------
# Parse arguments
# ----------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --branch)       BRANCH="$2"; shift 2 ;;
        --repo)         REPO="$2"; shift 2 ;;
        --server-type)  SERVER_TYPE="$2"; shift 2 ;;
        --ssh-key)      SSH_KEY="$2"; shift 2 ;;
        --location)     LOCATION="$2"; shift 2 ;;
        --output)       OUTPUT="$2"; shift 2 ;;
        --server-name)  SERVER_NAME="$2"; shift 2 ;;
        --keep-server)  KEEP_SERVER=true; shift ;;
        --help|-h)      usage ;;
        *)              fatal "Unknown option: $1 (use --help)" ;;
    esac
done

# ----------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------
log "${BOLD}minikube ISO builder (Hetzner Cloud)${NC}"
log "Branch:      ${BRANCH}"
log "Repo:        ${REPO}"
log "Server:      ${SERVER_TYPE} @ ${LOCATION}"
log "Output:      ${OUTPUT}"
echo ""

command -v "${HCLOUD}" >/dev/null 2>&1 || fatal "hcloud CLI not found. Install: brew install hcloud"
command -v ssh >/dev/null 2>&1        || fatal "ssh not found"
command -v scp >/dev/null 2>&1        || fatal "scp not found"

# Verify hcloud is authenticated
"${HCLOUD}" server list >/dev/null 2>&1 || fatal "hcloud not authenticated. Run: hcloud context create <name>"

# Check for existing server with same name
if "${HCLOUD}" server describe "${SERVER_NAME}" >/dev/null 2>&1; then
    fatal "Server '${SERVER_NAME}' already exists. Delete it first: ${HCLOUD} server delete ${SERVER_NAME}"
fi

# Ensure output directory exists
mkdir -p "$(dirname "${OUTPUT}")"

# Trap for cleanup
trap cleanup EXIT

# ----------------------------------------------------------------------
# Phase 1: Create server
# ----------------------------------------------------------------------
BUILD_START=$(date +%s)
log "${BOLD}Phase 1/5: Creating ${SERVER_TYPE} server...${NC}"

CREATE_OUTPUT=$("${HCLOUD}" server create \
    --name "${SERVER_NAME}" \
    --type "${SERVER_TYPE}" \
    --image ubuntu-24.04 \
    --location "${LOCATION}" \
    --ssh-key "${SSH_KEY}" 2>&1)

SERVER_IP=$(echo "${CREATE_OUTPUT}" | grep -oE 'IPv4: [0-9.]+' | awk '{print $2}')

if [ -z "${SERVER_IP}" ]; then
    fatal "Failed to extract server IP from hcloud output:\n${CREATE_OUTPUT}"
fi

log "Server created: ${SERVER_NAME} (${SERVER_IP})"

# Remove any stale host key for this IP
ssh-keygen -R "${SERVER_IP}" 2>/dev/null || true

wait_for_ssh

# Print server specs
ssh_builder 'echo "$(uname -m) | $(nproc) cores | $(free -h | awk "/Mem:/{print \$2}") RAM | $(df -h / | awk "NR==2{print \$4}") disk free"'

# ----------------------------------------------------------------------
# Phase 2: Install dependencies
# ----------------------------------------------------------------------
log "${BOLD}Phase 2/5: Installing build dependencies...${NC}"

ssh_builder 'export DEBIAN_FRONTEND=noninteractive && \
    apt-get update -qq && \
    apt-get install -y -qq \
        build-essential \
        bc \
        cpio \
        docker.io \
        file \
        genisoimage \
        git \
        golang-go \
        libncurses-dev \
        make \
        rsync \
        unzip \
        wget \
    > /dev/null 2>&1 && \
    systemctl start docker && \
    echo "Dependencies installed: $(go version), $(docker --version)"'

log "Dependencies installed"

# ----------------------------------------------------------------------
# Phase 3: Clone and build
# ----------------------------------------------------------------------
log "${BOLD}Phase 3/5: Cloning repo (branch: ${BRANCH})...${NC}"

ssh_builder "git clone --depth 1 --branch '${BRANCH}' '${REPO}' /root/minikube"

REMOTE_COMMIT=$(ssh_builder 'cd /root/minikube && git log --oneline -1')
log "Building commit: ${REMOTE_COMMIT}"

log "${BOLD}Phase 4/5: Building ISO (this takes 40-60 minutes)...${NC}"
log "Monitor progress: ssh root@${SERVER_IP} 'tail -f /root/build.log'"

# Run the build synchronously so we get the exit code
ssh_builder 'cd /root/minikube && \
    MINIKUBE_BUILD_IN_DOCKER=y make minikube-iso-aarch64 \
    > /root/build.log 2>&1' || {
    BUILD_LINES=$(ssh_builder 'wc -l < /root/build.log')
    err "Build failed after ${BUILD_LINES} lines of output"
    err "Last 30 lines:"
    ssh_builder 'tail -30 /root/build.log' >&2
    fatal "ISO build failed. Use --keep-server to debug."
}

# Verify ISO exists
ISO_SIZE=$(ssh_builder 'stat -c%s /root/minikube/out/minikube-arm64.iso 2>/dev/null || echo 0')
if [ "${ISO_SIZE}" -lt 1000000 ]; then
    fatal "ISO file missing or too small (${ISO_SIZE} bytes)"
fi

ISO_SIZE_MB=$((ISO_SIZE / 1048576))
log "ISO built successfully: ${ISO_SIZE_MB}MB"

# ----------------------------------------------------------------------
# Phase 4: Verify kernel config
# ----------------------------------------------------------------------
log "Verifying kernel config..."

VERIFY_OUTPUT=$(ssh_builder '
    CONFIG=$(find /root/minikube/out/buildroot/output-aarch64/build/ \
        -name ".config" -path "*/linux-*" | head -1)
    if [ -z "$CONFIG" ]; then
        echo "WARN: Could not find kernel .config for verification"
        exit 0
    fi

    CRITICAL_CONFIGS="
        CONFIG_BPF_SYSCALL
        CONFIG_BPF_JIT
        CONFIG_BPF_JIT_ALWAYS_ON
        CONFIG_BPF_LSM
        CONFIG_DEBUG_INFO_BTF
        CONFIG_KPROBES
        CONFIG_KPROBE_EVENTS
        CONFIG_BPF_EVENTS
        CONFIG_FTRACE
        CONFIG_FPROBE
        CONFIG_XDP_SOCKETS
        CONFIG_LWTUNNEL_BPF
        CONFIG_IP_NF_IPTABLES
        CONFIG_IP6_NF_IPTABLES
        CONFIG_NF_TABLES
        CONFIG_NF_CONNTRACK
        CONFIG_BRIDGE
        CONFIG_BRIDGE_NETFILTER
        CONFIG_VETH
        CONFIG_GENEVE
        CONFIG_XFRM
        CONFIG_XFRM_USER
        CONFIG_IPV6
    "

    FAIL=0
    for cfg in $CRITICAL_CONFIGS; do
        val=$(grep "^${cfg}=" "$CONFIG" 2>/dev/null | cut -d= -f2)
        if [ "$val" != "y" ]; then
            echo "FAIL: ${cfg} = ${val:-<not set>} (expected y)"
            FAIL=1
        fi
    done

    if [ $FAIL -eq 0 ]; then
        echo "OK: All 23 critical kernel configs verified =y"
    fi
')

echo "${VERIFY_OUTPUT}"
if echo "${VERIFY_OUTPUT}" | grep -q "^FAIL:"; then
    fatal "Kernel config verification failed"
fi

# ----------------------------------------------------------------------
# Phase 5: Download ISO
# ----------------------------------------------------------------------
log "${BOLD}Phase 5/5: Downloading ISO to ${OUTPUT}...${NC}"

scp_builder "root@${SERVER_IP}:/root/minikube/out/minikube-arm64.iso" "${OUTPUT}"

LOCAL_SIZE=$(stat -f%z "${OUTPUT}" 2>/dev/null || stat -c%s "${OUTPUT}" 2>/dev/null)
LOCAL_SIZE_MB=$((LOCAL_SIZE / 1048576))
log "Downloaded: ${OUTPUT} (${LOCAL_SIZE_MB}MB)"

# ----------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------
BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

echo ""
log "${BOLD}${GREEN}Build complete!${NC}"
log "ISO:      ${OUTPUT} (${LOCAL_SIZE_MB}MB)"
log "Commit:   ${REMOTE_COMMIT}"
log "Duration: $(elapsed ${BUILD_DURATION})"
echo ""
log "Next: make clean && make"
