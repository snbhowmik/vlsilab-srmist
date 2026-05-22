#!/bin/bash
# =============================================================================
#  LOCKDOWN SCRIPT — STUDENT USER RESTRICTIONS
#  Author: snbhowmik
#  Purpose : Restrict the student user to only the directories and files
#            they need for lab work. Run this AFTER all tools are installed
#            and verified to be working.
#  Run as  : sysadmin, using sudo  →  sudo bash lockdown.sh
#
#  ⚠️  WARNING: Test all EDA tools as the student user BEFORE running this.
#              Locking down too early will break tool access.
#              Run with --dry-run first to preview what will change.
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
STATE_FILE="/var/log/vlsilab/install.state"

# Set to "true" to preview changes without applying them
DRY_RUN="false"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="true"

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; NC="\033[0m"
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${GREEN}══════════════════════════════════════════${NC}"; \
            echo -e "${GREEN}  $*${NC}"; \
            echo -e "${GREEN}══════════════════════════════════════════${NC}\n"; }

state_get() {
    local key="$1"
    grep -m1 "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2- || echo ""
}

apply_chmod() {
    local mode="$1"; local target="$2"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  [DRY-RUN] chmod $mode $target"
    else
        chmod "$mode" "$target" && info "chmod $mode $target"
    fi
}

apply_chown() {
    local owner="$1"; local target="$2"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  [DRY-RUN] chown $owner $target"
    else
        chown "$owner" "$target" && info "chown $owner $target"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# RESOLVE MACHINE NUMBER
# ─────────────────────────────────────────────────────────────────────────────
MACHINE_NUMBER=""
if [[ -f "$STATE_FILE" ]]; then
    MACHINE_NUMBER=$(state_get "MACHINE_NUMBER")
fi

if [[ -z "$MACHINE_NUMBER" ]]; then
    warn "Could not read MACHINE_NUMBER from ${STATE_FILE}."
    read -rp "Enter machine number (1-20): " MACHINE_NUMBER
    [[ -z "$MACHINE_NUMBER" ]] && error "Machine number cannot be empty."
fi

SYSADMIN_USER="sysadmin309${MACHINE_NUMBER}"
STUDENT_USER="srmist309${MACHINE_NUMBER}"
STUDENT_HOME="/home/${STUDENT_USER}"

info "Machine number : ${MACHINE_NUMBER}"
info "Sysadmin user  : ${SYSADMIN_USER}"
info "Student user   : ${STUDENT_USER}"

# Must be run via sudo from the sysadmin account
[[ $EUID -ne 0 ]] && error "Run this script with sudo:\n  sudo bash $0 [--dry-run]"
[[ -z "${SUDO_USER:-}" ]] && error "Do not run as root directly. Log in as ${SYSADMIN_USER} and run:\n  sudo bash $0"
[[ "$SUDO_USER" != "$SYSADMIN_USER" ]] && \
    warn "Expected SUDO_USER=${SYSADMIN_USER} but got '${SUDO_USER}'. Continuing anyway."

[[ "$DRY_RUN" == "true" ]] && warn "DRY-RUN mode — no changes will be applied."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 : Lock down /home — users cannot see each other's home dirs
# ─────────────────────────────────────────────────────────────────────────────
section "STEP 1: Isolating Home Directories"

for dir in /home/*/; do
    [[ -d "$dir" ]] && apply_chmod 700 "$dir"
done
info "All home directories set to 700 (owner-only access)."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 : Lock down system mount points
# ─────────────────────────────────────────────────────────────────────────────
section "STEP 2: Restricting Mount Points"

apply_chmod 700 /media
apply_chmod 700 /mnt
apply_chmod 700 /srv

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 : Restrict student's own home directory structure
#
#  TODO: Define exactly which subdirectories the student should have
#        read/write access to. Examples are listed below — uncomment and
#        adjust to match your lab's folder layout.
# ─────────────────────────────────────────────────────────────────────────────
section "STEP 3: Student Home Directory Permissions"

# ── Directories the student CAN read and write ──────────────────────────────
# Uncomment the ones that apply. Add more as needed.

# apply_chmod 700 "${STUDENT_HOME}"                      # full private home
# apply_chmod 755 "${STUDENT_HOME}/Desktop"              # desktop visible
# apply_chmod 700 "${STUDENT_HOME}/lab_work"             # lab submissions folder
# apply_chmod 755 "${STUDENT_HOME}/Downloads"            # downloads readable

# ── Directories the student should NOT write to ─────────────────────────────
# apply_chmod 555 "${STUDENT_HOME}/reference_docs"       # read-only references

warn "STEP 3 is a placeholder — no rules applied yet."
warn "Edit lockdown.sh and uncomment/add chmod lines under STEP 3."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 : Restrict access to EDA tool installation directories
#
#  By default, tool dirs are owned by root. The student needs execute access
#  to run the tools but should NOT be able to modify them.
#
#  TODO: Uncomment the blocks for the tools installed on this machine.
# ─────────────────────────────────────────────────────────────────────────────
section "STEP 4: EDA Tool Directory Access"

# ── Xilinx ──────────────────────────────────────────────────────────────────
# apply_chmod 755 /opt/Xilinx                           # student can traverse
# find /opt/Xilinx -type d -exec chmod 755 {} \;        # all subdirs traversable
# find /opt/Xilinx -type f -exec chmod 644 {} \;        # files readable
# find /opt/Xilinx/*/bin -type f -exec chmod 755 {} \;  # binaries executable

# ── Cadence ─────────────────────────────────────────────────────────────────
# apply_chmod 755 /opt/cadence                          # student can traverse
# find /opt/cadence -type d -exec chmod 755 {} \;
# find /opt/cadence -type f -exec chmod 644 {} \;
# find /opt/cadence/tools/bin -type f -exec chmod 755 {} \;

# ── Silvaco ─────────────────────────────────────────────────────────────────
# apply_chmod 755 /opt/sedatools
# find /opt/sedatools -type d -exec chmod 755 {} \;
# find /opt/sedatools -type f -exec chmod 644 {} \;
# find /opt/sedatools/bin -type f -exec chmod 755 {} \;

# ── Synopsys (placeholder) ─────────────────────────────────────────────────
# TODO: Add Synopsys directory restrictions when tool is installed.
# apply_chmod 755 /opt/synopsys
# find /opt/synopsys -type d -exec chmod 755 {} \;
# find /opt/synopsys -type f -exec chmod 644 {} \;
# find /opt/synopsys/bin -type f -exec chmod 755 {} \;

# ── CADRE (placeholder) ────────────────────────────────────────────────────
# TODO: Add CADRE directory restrictions when tool is installed.
# apply_chmod 755 /opt/cadre
# find /opt/cadre -type d -exec chmod 755 {} \;
# find /opt/cadre -type f -exec chmod 644 {} \;
# find /opt/cadre/bin -type f -exec chmod 755 {} \;

warn "STEP 4 is a placeholder — no rules applied yet."
warn "Uncomment the relevant blocks for Xilinx / Cadence / Silvaco / Synopsys / CADRE."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 : Prevent student from writing to system directories
#          (most are already root-owned, this is just a belt-and-suspenders check)
# ─────────────────────────────────────────────────────────────────────────────
section "STEP 5: System Directory Sanity Check"

SYSTEM_DIRS=(/opt /usr/local/bin /usr/share/applications)
for d in "${SYSTEM_DIRS[@]}"; do
    OWNER=$(stat -c '%U' "$d" 2>/dev/null || echo "unknown")
    PERMS=$(stat -c '%a' "$d" 2>/dev/null || echo "???")
    info "$d → owner: $OWNER | perms: $PERMS"
done
info "Review the above. If any system dir is world-writable, fix it manually."

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────
section "LOCKDOWN COMPLETE"

if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "  ${YELLOW}DRY-RUN finished — no changes were made.${NC}"
    echo -e "  Review the output above, then run without --dry-run to apply."
else
    echo -e "  Student user : ${STUDENT_USER}"
    echo -e "  ${YELLOW}Verify the student account still works before logging out:${NC}"
    echo -e "    su - ${STUDENT_USER}"
    echo -e "    vivado          # or the relevant EDA tool"
    echo -e "    exit"
    echo ""
    echo -e "  ${RED}If tools are broken, re-run with corrected permissions.${NC}"
fi
echo ""
