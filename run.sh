#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FEDORA_IMAGE_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2"
IMAGE_CACHE_DIR="${SCRIPT_DIR}/.cache"
BASE_IMAGE="${IMAGE_CACHE_DIR}/fedora-cloud.qcow2"
SNAPSHOT_IMAGE=""
CLOUDINIT_ISO=""
SSH_PORT=10022
SSH_USER=fedora
SSH_KEY="${SCRIPT_DIR}/cloud-init/id_ed25519"
QEMU_PID=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

passed=0
failed=0

cleanup() {
    echo ""
    echo "--- cleanup ---"
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "killing QEMU (pid $QEMU_PID)"
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [[ -n "$SNAPSHOT_IMAGE" && -f "$SNAPSHOT_IMAGE" ]]; then
        echo "removing snapshot $SNAPSHOT_IMAGE"
        rm -f "$SNAPSHOT_IMAGE"
    fi
    if [[ -n "$CLOUDINIT_ISO" && -f "$CLOUDINIT_ISO" ]]; then
        echo "removing cloud-init ISO $CLOUDINIT_ISO"
        rm -f "$CLOUDINIT_ISO"
    fi
}
trap cleanup EXIT

ssh_cmd() {
    ssh -i "$SSH_KEY" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        -p "$SSH_PORT" \
        "${SSH_USER}@localhost" \
        "$@"
}

scp_to_vm() {
    local src="$1" dst="$2"
    scp -i "$SSH_KEY" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -P "$SSH_PORT" \
        "$src" "${SSH_USER}@localhost:${dst}"
}

wait_for_ssh() {
    local deadline=$((SECONDS + 120))
    echo -n "waiting for SSH"
    while (( SECONDS < deadline )); do
        if ssh_cmd "true" 2>/dev/null; then
            echo " ok"
            return 0
        fi
        echo -n "."
        sleep 2
    done
    echo " TIMEOUT"
    return 1
}

assert() {
    local description="$1"
    shift
    echo -ne "  ${BOLD}assert:${NC} ${description} ... "
    if eval "$*"; then
        echo -e "${GREEN}PASS${NC}"
        passed=$((passed + 1))
    else
        echo -e "${RED}FAIL${NC}"
        failed=$((failed + 1))
    fi
}

# --- preflight checks ---

for cmd in qemu-system-x86_64 qemu-img; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "error: $cmd not found" >&2
        exit 1
    fi
done

MKISOFS=""
for cmd in genisoimage mkisofs xorrisofs; do
    if command -v "$cmd" &>/dev/null; then
        MKISOFS="$cmd"
        break
    fi
done
if [[ -z "$MKISOFS" ]]; then
    echo "error: genisoimage, mkisofs, or xorrisofs not found" >&2
    exit 1
fi

# --- download fedora cloud image ---

if [[ ! -f "$BASE_IMAGE" ]]; then
    echo "downloading Fedora Cloud image..."
    mkdir -p "$IMAGE_CACHE_DIR"
    curl -L -o "$BASE_IMAGE" "$FEDORA_IMAGE_URL"
    echo "download complete"
else
    echo "using cached Fedora Cloud image"
fi

# --- create cloud-init ISO ---

CLOUDINIT_ISO="$(mktemp /tmp/cloudinit-XXXXXX.iso)"
"$MKISOFS" -output "$CLOUDINIT_ISO" -volid cidata -joliet -rock \
    "${SCRIPT_DIR}/cloud-init/user-data" \
    "${SCRIPT_DIR}/cloud-init/meta-data" 2>/dev/null
echo "created cloud-init ISO"

# --- create snapshot ---

SNAPSHOT_IMAGE="$(mktemp /tmp/stratisd-repro-XXXXXX.qcow2)"
qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$SNAPSHOT_IMAGE" >/dev/null
echo "created snapshot"

# --- boot VM ---

echo "booting VM..."
qemu-system-x86_64 \
    -m 2048M \
    -smp 2 \
    -machine type=pc,accel=kvm \
    -cpu host \
    -drive "file=${SNAPSHOT_IMAGE},if=virtio,cache=writeback,discard=ignore,format=qcow2" \
    -cdrom "$CLOUDINIT_ISO" \
    -boot c \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device virtio-net,netdev=net0 \
    -nographic &
QEMU_PID=$!

wait_for_ssh

# --- provision ---

echo "installing stratisd..."
ssh_cmd "sudo dnf install -y stratisd > /dev/null 2>&1"
echo "stratisd installed"

echo "copying test services..."
scp_to_vm "${SCRIPT_DIR}/services/downstream.service" "/tmp/downstream.service"
scp_to_vm "${SCRIPT_DIR}/services/fake-network-fstab.service" "/tmp/fake-network-fstab.service"
ssh_cmd "sudo cp /tmp/downstream.service /etc/systemd/system/ && \
         sudo cp /tmp/fake-network-fstab.service /etc/systemd/system/ && \
         sudo systemctl daemon-reload && \
         sudo systemctl enable stratisd.service downstream.service fake-network-fstab.service"
echo "services installed and enabled"

# --- phase 1: demonstrate the cycle ---

echo ""
echo -e "${YELLOW}=== Phase 1: Demonstrate dependency cycle ===${NC}"

VERIFY_BEFORE="$(ssh_cmd "sudo systemd-analyze verify default.target 2>&1" || true)"
echo "$VERIFY_BEFORE"

assert "systemd-analyze verify reports ordering cycle" \
    'echo "$VERIFY_BEFORE" | grep -qi "ordering cycle"'

# --- phase 2: apply the fix ---

echo ""
echo -e "${YELLOW}=== Phase 2: Apply fix (remove DefaultDependencies=no + After=multi-user.target) ===${NC}"

# Write the fixed unit file as an override. A drop-in cannot clear After= (it only
# appends), so we place a full replacement unit at /etc/systemd/system/.
FIXED_UNIT="$(mktemp /tmp/stratisd-fixed-XXXXXX.service)"
cat > "$FIXED_UNIT" <<'EOF'
[Unit]
Description=Stratis daemon
Documentation=man:stratisd(8)

[Service]
BusName=org.storage.stratis3
Type=dbus
Environment=RUST_BACKTRACE=1
ExecStart=/usr/libexec/stratisd --log-level debug
KillSignal=SIGINT
KillMode=process
Restart=on-abort

[Install]
WantedBy=multi-user.target
EOF
scp_to_vm "$FIXED_UNIT" "/tmp/stratisd-fixed.service"
rm -f "$FIXED_UNIT"
ssh_cmd "sudo cp /tmp/stratisd-fixed.service /etc/systemd/system/stratisd.service"

ssh_cmd "sudo systemctl daemon-reload"
echo "fix applied"

# --- phase 3: verify fix resolves cycle ---

echo ""
echo -e "${YELLOW}=== Phase 3: Verify fix resolves cycle ===${NC}"

VERIFY_AFTER="$(ssh_cmd "sudo systemd-analyze verify default.target 2>&1" || true)"
echo "$VERIFY_AFTER"

assert "systemd-analyze verify reports no ordering cycle" \
    '! echo "$VERIFY_AFTER" | grep -qi "ordering cycle"'

# --- phase 4: reboot and verify services ---

echo ""
echo -e "${YELLOW}=== Phase 4: Reboot and verify services ===${NC}"

echo "rebooting VM..."
ssh_cmd "sudo systemctl reboot" 2>/dev/null || true
sleep 5
wait_for_ssh

echo "checking services after reboot..."

DOWNSTREAM_STATUS="$(ssh_cmd "systemctl is-active downstream.service" 2>/dev/null || true)"
echo "downstream.service: $DOWNSTREAM_STATUS"
assert "downstream.service is active after reboot" \
    '[[ "$DOWNSTREAM_STATUS" == "active" ]]'

# Wait for the fake-network-fstab service to finish (it has a 3-second sleep)
ssh_cmd "sudo systemctl is-active --wait fake-network-fstab.service 2>/dev/null" || true
# is-active --wait may not be available; fall back to polling
for i in $(seq 1 10); do
    state="$(ssh_cmd "systemctl is-active fake-network-fstab.service" 2>/dev/null || true)"
    if [[ "$state" != "activating" ]]; then
        break
    fi
    sleep 1
done

FSTAB_MARKER="$(ssh_cmd "test -f /tmp/network-fstab-completed && echo exists" 2>/dev/null || true)"
echo "network-fstab marker: ${FSTAB_MARKER:-missing}"
assert "fake-network-fstab.service completed (Clevis path unaffected)" \
    '[[ "$FSTAB_MARKER" == "exists" ]]'

# stratisd will fail without a real pool, but we can check it attempted to start
STRATISD_STATUS="$(ssh_cmd "systemctl show -p ActiveState,SubState stratisd.service" 2>/dev/null || true)"
echo "stratisd.service: $STRATISD_STATUS"

# --- summary ---

echo ""
echo -e "${BOLD}=== Results ===${NC}"
echo -e "  ${GREEN}passed: ${passed}${NC}"
if (( failed > 0 )); then
    echo -e "  ${RED}failed: ${failed}${NC}"
    exit 1
else
    echo -e "  failed: 0"
fi
