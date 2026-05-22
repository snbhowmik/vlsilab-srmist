#!/bin/bash
# =============================================================================
#  VLSI LAB — UNIFIED EDA SETUP TOOL
#  SRM Institute of Science and Technology, Trichy
#  Author: snbhowmik
#
#  Run as : sysadmin, using sudo  →  sudo bash setup.sh
#
#  What it does:
#    1. Prompts for machine config (saved to state file)
#    2. Installs system dependencies (must be run before any tool)
#    3. Shows a tool dashboard — install whichever tools you need
#    4. Tracks every phase so you can stop and resume at any time
#
#  Folder layout (place installers alongside this script):
#    setup.sh
#    CADENCE/    → Digital_RHEL_8.tar.gz, Analog_RHEL_8.tar.gz
#    SILVACO/    → 243423-tcadlegacy..., 255020-victorytcad..., 255017-victory_str...
#    XILINX/     → FPGAs_AdaptiveSoCs_...bin  or  extracted xsetup folder
#    CADRE/      → Cadre-VisualTCAD-Linux-2025.04.r3-284.bin
#    SYNOPSYS/   → (future)
#
#  State file : /var/log/vlsilab/install.state
#  Full log   : /var/log/vlsilab/install.log
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# SCRIPT DIRECTORY  —  resolve the folder containing this script so that
# tool subfolders (CADENCE/, SILVACO/, etc.) are found regardless of where
# the user cds from.
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
STATE_DIR="/var/log/vlsilab"
STATE_FILE="${STATE_DIR}/install.state"
LOG_FILE="${STATE_DIR}/install.log"

LICENSE_SERVER_IP="14.139.1.126"
LICENSE_SERVER_HOSTNAME="c2s.cdacb.in"

# ── Xilinx ───────────────────────────────────────────────────────────────────
XILINX_ROOT="/opt/Xilinx"
XILINX_VERSION="2025.2"
XILINX_PORT="2100"

# ── Cadence ──────────────────────────────────────────────────────────────────
CADENCE_INSTALL_DIR="/opt/cadence"
CADENCE_PORT="5280"

# ── Silvaco ──────────────────────────────────────────────────────────────────
SILVACO_INSTALL_DIR="/opt/sedatools"
SILVACO_PORT="27000"
# Installer filenames — MUST be installed in this order
SILVACO_BIN_1="243423-tcadlegacyandinterco-2024-00-rh64.bin"
SILVACO_BIN_2="255020-victorytcad-2025-01-rh64.bin"
SILVACO_BIN_3="255017-victory_str-2025-01.bin"

# ── CADRE ────────────────────────────────────────────────────────────────────
CADRE_INSTALL_DIR="/opt/cadre"
CADRE_BIN="Cadre-VisualTCAD-Linux-2025.04.r3-284.bin"

# ── Tool source folders (relative to SCRIPT_DIR) ────────────────────────────
DIR_CADENCE="${SCRIPT_DIR}/CADENCE"
DIR_SILVACO="${SCRIPT_DIR}/SILVACO"
DIR_XILINX="${SCRIPT_DIR}/XILINX"
DIR_SYNOPSYS="${SCRIPT_DIR}/SYNOPSYS"
DIR_CADRE="${SCRIPT_DIR}/CADRE"

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"
CYAN="\033[1;36m"; BOLD="\033[1m"; DIM="\033[2m"; NC="\033[0m"

info()    { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
log()     { echo -e "$*" | tee -a "$LOG_FILE"; }
section() {
    echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}" | tee -a "$LOG_FILE"
    echo -e "${GREEN}  $*${NC}" | tee -a "$LOG_FILE"
    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}\n" | tee -a "$LOG_FILE"
}

# ── State management ────────────────────────────────────────────────────────
state_get() {
    local key="$1"
    grep -m1 "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d'=' -f2- || echo ""
}

state_set() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$STATE_FILE"
    else
        echo "${key}=${val}" >> "$STATE_FILE"
    fi
}

phase_done() {
    local phase="$1"
    state_set "${phase}" "DONE"
    state_set "${phase}_TIME" "$(date '+%Y-%m-%d %H:%M:%S')"
    info "Phase complete: ${phase}"
}

is_done() {
    [[ "$(state_get "$1")" == "DONE" ]]
}

# ── Prompt for a file path, loop until valid ─────────────────────────────────
prompt_file() {
    local prompt="$1" result_var="$2"
    local path=""
    while true; do
        read -rp "  ${prompt}: " path
        if [[ -f "$path" ]]; then
            eval "$result_var=\"$path\""
            return 0
        fi
        echo -e "  ${RED}File not found: ${path}${NC}"
        read -rp "  Try again? [Y/n]: " retry
        [[ "${retry,,}" == "n" ]] && return 1
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# PRIVILEGE CHECK
# ─────────────────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo -e "${RED}[ERROR]${NC} Run with sudo: sudo bash $0"; exit 1; }
[[ -z "${SUDO_USER:-}" ]] && { echo -e "${RED}[ERROR]${NC} Do not run as root directly. Log in as sysadmin and use sudo."; exit 1; }

# Set up log dir early (before any logging)
mkdir -p "$STATE_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

echo -e "\n$(date '+%Y-%m-%d %H:%M:%S') — setup.sh started by ${SUDO_USER}" >> "$LOG_FILE"

# Save SCRIPT_DIR to state so we can report it later
state_set "SCRIPT_DIR" "$SCRIPT_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 0 : Machine Configuration
#
#  On first run: prompts for machine number, derives all usernames/hostnames,
#  saves everything to the state file.
#  On subsequent runs: loads from state file and confirms.
# ─────────────────────────────────────────────────────────────────────────────
clear
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║       VLSI LAB — SRM IST TRICHY SETUP TOOL          ║"
echo "  ║                  Author: snbhowmik                   ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

if is_done "CONFIG"; then
    # ── Load saved config ────────────────────────────────────────────────────
    MACHINE_NUMBER=$(state_get "MACHINE_NUMBER")
    SYSADMIN_USER=$(state_get "SYSADMIN_USER")
    STUDENT_USER=$(state_get "STUDENT_USER")
    HOSTNAME_FQDN=$(state_get "HOSTNAME")
    SYSADMIN_HOME="/home/${SUDO_USER}"

    echo -e "  ${CYAN}Saved configuration detected:${NC}"
    echo -e "  Hostname  : ${HOSTNAME_FQDN}"
    echo -e "  Admin     : ${SYSADMIN_USER}"
    echo -e "  Student   : ${STUDENT_USER}"
    echo -e "  State file: ${STATE_FILE}"
    echo ""
    read -rp "  Use this configuration? [Y/n]: " USE_SAVED
    if [[ "${USE_SAVED,,}" == "n" ]]; then
        # Reset config so we re-prompt
        sed -i '/^CONFIG=/d; /^MACHINE_NUMBER=/d; /^SYSADMIN_USER=/d; /^STUDENT_USER=/d; /^HOSTNAME=/d' "$STATE_FILE"
    fi
fi

if ! is_done "CONFIG"; then
    section "SYSTEM CONFIGURATION"

    # ── Machine number ───────────────────────────────────────────────────────
    echo -e "  ${YELLOW}Machine numbers run from 1 to 20.${NC}"
    echo -e "  ${YELLOW}Examples: 1, 5, 20 → hostnames vlsilab1, vlsilab5, vlsilab20${NC}\n"
    while true; do
        read -rp "  Enter machine number [1-20]: " MACHINE_NUMBER
        if [[ "$MACHINE_NUMBER" =~ ^([1-9]|1[0-9]|20)$ ]]; then
            break
        fi
        echo -e "  ${RED}Invalid — enter a number between 1 and 20.${NC}"
    done

    SYSADMIN_USER="sysadmin309${MACHINE_NUMBER}"
    STUDENT_USER="srmist309${MACHINE_NUMBER}"
    HOSTNAME_FQDN="vlsilab${MACHINE_NUMBER}.ist.srmtrichy.edu.in"
    SYSADMIN_HOME="/home/${SUDO_USER}"

    # ── Confirm ──────────────────────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}Configuration summary:${NC}"
    echo -e "  Hostname : ${GREEN}${HOSTNAME_FQDN}${NC}"
    echo -e "  Admin    : ${GREEN}${SYSADMIN_USER}${NC}  (must already exist)"
    echo -e "  Student  : ${GREEN}${STUDENT_USER}${NC}  (will be created)"
    echo ""
    read -rp "  Confirm and continue? [Y/n]: " CONFIRM_CFG
    [[ "${CONFIRM_CFG,,}" == "n" ]] && { echo "Aborted."; exit 0; }

    # Verify the sysadmin running this is who we expect
    [[ "$SUDO_USER" != "$SYSADMIN_USER" ]] && \
        warn "Logged in as '${SUDO_USER}' but config expects '${SYSADMIN_USER}'. Continuing anyway."

    # ── Save config ──────────────────────────────────────────────────────────
    state_set "MACHINE_NUMBER" "$MACHINE_NUMBER"
    state_set "SYSADMIN_USER"  "$SYSADMIN_USER"
    state_set "STUDENT_USER"   "$STUDENT_USER"
    state_set "HOSTNAME"       "$HOSTNAME_FQDN"
    phase_done "CONFIG"
fi

# Convenience vars used by all phases
STUDENT_HOME="/home/${STUDENT_USER}"
BASHRC="${STUDENT_HOME}/.bashrc"
SYSADMIN_HOME="/home/${SUDO_USER}"

# ─────────────────────────────────────────────────────────────────────────────
# STATUS DASHBOARD
# ─────────────────────────────────────────────────────────────────────────────
show_dashboard() {
    local tick="${GREEN}✔${NC}" cross="${RED}✘${NC}" clock="${YELLOW}⏳${NC}"

    status_icon() { is_done "$1" && echo -e "$tick" || echo -e "$cross"; }
    status_time()  { local t; t=$(state_get "${1}_TIME"); [[ -n "$t" ]] && echo " (${t})" || echo ""; }

    # Silvaco combo status
    local silvaco_all=true
    is_done "SILVACO_1" || silvaco_all=false
    is_done "SILVACO_2" || silvaco_all=false
    is_done "SILVACO_3" || silvaco_all=false

    local preinstall_ok=false
    is_done "PRE_INSTALL" && preinstall_ok=true

    clear
    echo -e "${GREEN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║       VLSI LAB — SRM IST TRICHY SETUP TOOL          ║"
    echo "  ║                  Author: snbhowmik                   ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${CYAN}Machine${NC} : ${HOSTNAME_FQDN}"
    echo -e "  ${CYAN}Student${NC} : ${STUDENT_USER}"
    echo -e "  ${CYAN}Source ${NC} : ${SCRIPT_DIR}"
    echo -e "  ${CYAN}Log    ${NC} : ${LOG_FILE}"
    echo ""
    echo -e "  ${BOLD}Installation Status${NC}"
    echo    "  ──────────────────────────────────────────────────────"
    printf  "  [%b] %-4s %s%s\n" "$(status_icon PRE_INSTALL)"   "0."  "System dependencies & student user" "$(status_time PRE_INSTALL)"
    echo    "  ──────────────────────────────────────────────────────"
    printf  "  [%b] %-4s %s%s\n" "$(status_icon XILINX)"        "1."  "Xilinx Vivado/Vitis ${XILINX_VERSION}"  "$(status_time XILINX)"
    echo    "  ──────────────────────────────────────────────────────"
    printf  "  [%b] %-4s %s%s\n" "$(status_icon CADENCE)"       "2."  "Cadence (Analog + Digital)"         "$(status_time CADENCE)"
    echo    "  ──────────────────────────────────────────────────────"
    printf  "  [%b] %-4s %s%s\n" "$(status_icon SILVACO_1)"     "3a." "Silvaco — TCAD Legacy & Interconnect" "$(status_time SILVACO_1)"
    printf  "  [%b] %-4s %s%s\n" "$(status_icon SILVACO_2)"     "3b." "Silvaco — Victory TCAD 2025"         "$(status_time SILVACO_2)"
    printf  "  [%b] %-4s %s%s\n" "$(status_icon SILVACO_3)"     "3c." "Silvaco — Victory STR 2025"          "$(status_time SILVACO_3)"
    echo    "  ──────────────────────────────────────────────────────"
    printf  "  [%b] %-4s %s%s\n" "$(status_icon CADRE)"         "4."  "CADRE VisualTCAD"                    "$(status_time CADRE)"
    echo    "  ──────────────────────────────────────────────────────"
    printf  "  [%b] %-4s %s\n"   "$clock"                       "5."  "Synopsys  (coming soon)"
    echo    "  ──────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${BOLD}Options${NC}"
    echo -e "  ${GREEN}0${NC}  Run pre-install (dependencies + student user)  ${YELLOW}← do this first${NC}"

    if [[ "$preinstall_ok" == true ]]; then
        echo -e "  ${GREEN}1${NC}  Install Xilinx"
        echo -e "  ${GREEN}2${NC}  Install Cadence"
        echo -e "  ${GREEN}3${NC}  Install Silvaco (runs 3a → 3b → 3c in order)"
        echo -e "  ${GREEN}4${NC}  Install CADRE VisualTCAD"
        echo -e "  ${DIM}  5  Synopsys  (coming soon)${NC}"
    else
        echo -e "  ${DIM}  1  Install Xilinx      (run pre-install first)${NC}"
        echo -e "  ${DIM}  2  Install Cadence     (run pre-install first)${NC}"
        echo -e "  ${DIM}  3  Install Silvaco     (run pre-install first)${NC}"
        echo -e "  ${DIM}  4  Install CADRE       (run pre-install first)${NC}"
        echo -e "  ${DIM}  5  Synopsys            (coming soon)${NC}"
    fi

    echo -e "  ${GREEN}s${NC}  Show this dashboard"
    echo -e "  ${GREEN}l${NC}  View install log"
    echo -e "  ${GREEN}q${NC}  Quit"
    echo ""
}

# ── Pre-install gate — blocks tool installs until dependencies are done ──────
require_preinstall() {
    if ! is_done "PRE_INSTALL"; then
        echo ""
        echo -e "  ${RED}╔══════════════════════════════════════════════════╗${NC}"
        echo -e "  ${RED}║  Pre-install must be completed first (option 0) ║${NC}"
        echo -e "  ${RED}╚══════════════════════════════════════════════════╝${NC}"
        echo ""
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 0 : Pre-Install (dependencies + student user)
# ─────────────────────────────────────────────────────────────────────────────
run_pre_install() {
    if is_done "PRE_INSTALL"; then
        warn "Pre-install already completed — skipping."
        read -rp "  Force re-run? [y/N]: " FORCE
        [[ "${FORCE,,}" != "y" ]] && return 0
    fi

    section "PRE-INSTALL: System Configuration & Dependencies"

    # ── Student user ─────────────────────────────────────────────────────────
    info "Creating student user: ${STUDENT_USER}"
    if id "$STUDENT_USER" &>/dev/null; then
        warn "User ${STUDENT_USER} already exists — skipping creation."
    else
        useradd -m -c "SRM-IST-309-${MACHINE_NUMBER}" -s /bin/bash "$STUDENT_USER"
        echo "${STUDENT_USER}:Student@SRM" | chpasswd
        info "Student user created."
    fi
    if groups "$STUDENT_USER" | grep -q wheel; then
        gpasswd -d "$STUDENT_USER" wheel
        info "Removed ${STUDENT_USER} from wheel group."
    fi

    # ── Hostname ─────────────────────────────────────────────────────────────
    info "Setting hostname: ${HOSTNAME_FQDN}"
    hostnamectl set-hostname "$HOSTNAME_FQDN"

    # ── /etc/hosts — license server ──────────────────────────────────────────
    if ! grep -q "$LICENSE_SERVER_HOSTNAME" /etc/hosts; then
        printf "\n# EDA License Server\n%s %s\n" \
            "$LICENSE_SERVER_IP" "$LICENSE_SERVER_HOSTNAME" | tee -a /etc/hosts > /dev/null
        info "License server added to /etc/hosts"
    else
        info "License server already in /etc/hosts"
    fi

    # ── DNF update + repos ───────────────────────────────────────────────────
    info "Running dnf update ..."
    dnf update -y

    info "Installing EPEL ..."
    dnf install -y epel-release 2>/dev/null || \
        dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm

    info "Enabling CodeReady Builder ..."
    subscription-manager repos \
        --enable "codeready-builder-for-rhel-8-$(arch)-rpms" 2>/dev/null || \
        warn "CodeReady Builder enable failed — may not be subscribed. Continuing."

    dnf update -y

    # ── RPM Fusion ───────────────────────────────────────────────────────────
    info "Installing RPM Fusion ..."
    TMP=$(mktemp -d)
    curl -fLo "${TMP}/free.rpm"    https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-8.noarch.rpm
    curl -fLo "${TMP}/nonfree.rpm" https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-8.noarch.rpm
    dnf install -y "${TMP}/free.rpm" "${TMP}/nonfree.rpm" || warn "RPM Fusion had warnings — continuing."
    rm -rf "$TMP"

    # ── EDA dependencies ─────────────────────────────────────────────────────
    info "Installing EDA dependencies ..."
    dnf install -y \
        compat-openssl10 redhat-lsb-core csh ksh \
        libnsl libnsl.i686 fuse-exfat \
        glibc glibc-devel glibc.i686 \
        libgcc.i686 libstdc++.i686 zlib.i686 \
        elfutils-libelf \
        mesa-libGL mesa-libGLU \
        xorg-x11-fonts-75dpi xorg-x11-fonts-misc \
        nano gdbm elrepo-release \
        libXtst libXrender libXi libXrandr \
        libXcursor libXinerama libSM libICE libXft libXext libXau libXdmcp \
        --skip-broken

    dnf install -y 'openssl*' --skip-broken || warn "Some openssl* packages skipped."
    dnf install -y 'liba*'    --skip-broken || warn "Some liba* packages skipped."

    phase_done "PRE_INSTALL"
    info "Pre-install complete. Reboot before installing EDA tools."
    read -rp "  Reboot now? [y/N]: " DO_REBOOT
    [[ "${DO_REBOOT,,}" == "y" ]] && reboot
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 : Xilinx
# ─────────────────────────────────────────────────────────────────────────────
run_xilinx() {
    require_preinstall || return 0

    if is_done "XILINX"; then
        warn "Xilinx already marked complete."
        read -rp "  Force re-run? [y/N]: " FORCE
        [[ "${FORCE,,}" != "y" ]] && return 0
    fi

    section "XILINX VIVADO/VITIS ${XILINX_VERSION}"

    local XILINX_VER_ROOT="${XILINX_ROOT}/${XILINX_VERSION}"

    # ── Check for existing installation ──────────────────────────────────────
    local ALREADY_INSTALLED=false
    if [[ -d "${XILINX_VER_ROOT}" ]]; then
        info "Found existing install at: ${XILINX_VER_ROOT}"
        ALREADY_INSTALLED=true
    elif [[ -d "/opt/${XILINX_VERSION}" ]] || [[ -d "/opt/DocNav" ]] || [[ -d "/opt/xic" ]]; then
        info "Found Xilinx dirs under /opt/ — needs relocation."
        ALREADY_INSTALLED=true
    fi

    # ── Find installer ───────────────────────────────────────────────────────
    if [[ "$ALREADY_INSTALLED" == false ]]; then
        echo -e "\n${RED}══════════════════════════════════════════════════════${NC}"
        echo -e "${RED}  ⚠️  SET INSTALL DIRECTORY TO EXACTLY:  /opt/Xilinx   ${NC}"
        echo -e "${RED}  Do NOT use /opt — breaks internal JVM classpaths      ${NC}"
        echo -e "${RED}══════════════════════════════════════════════════════${NC}\n"

        local INSTALLER_TO_RUN="" INSTALLER_TYPE=""

        # ── Search in XILINX/ folder alongside setup.sh ──────────────────────
        if [[ -d "$DIR_XILINX" ]]; then
            info "Scanning ${DIR_XILINX}/ for installers ..."

            # Look for .bin files
            local BIN_FOUND
            BIN_FOUND=$(find "$DIR_XILINX" -maxdepth 2 -name "*.bin" -type f 2>/dev/null | head -n 1)
            if [[ -n "$BIN_FOUND" ]]; then
                INSTALLER_TO_RUN="$BIN_FOUND"
                INSTALLER_TYPE="bin"
                info "Found .bin installer: ${BIN_FOUND}"
            fi

            # Look for xsetup if no .bin found
            if [[ -z "$INSTALLER_TO_RUN" ]]; then
                local XSETUP_FOUND
                XSETUP_FOUND=$(find "$DIR_XILINX" -maxdepth 4 -name "xsetup" -type f 2>/dev/null | head -n 1)
                if [[ -n "$XSETUP_FOUND" ]]; then
                    INSTALLER_TO_RUN="$XSETUP_FOUND"
                    INSTALLER_TYPE="xsetup"
                    info "Found offline installer: ${XSETUP_FOUND}"
                fi
            fi
        fi

        # ── Fallback: check ~/Downloads ──────────────────────────────────────
        if [[ -z "$INSTALLER_TO_RUN" ]]; then
            local DEFAULT_BIN="${SYSADMIN_HOME}/Downloads/FPGAs_AdaptiveSoCs_Unified_SDI_${XILINX_VERSION}_1114_2157_Lin64.bin"
            if [[ -f "$DEFAULT_BIN" ]]; then
                INSTALLER_TO_RUN="$DEFAULT_BIN"
                INSTALLER_TYPE="bin"
                info "Found .bin in Downloads: ${DEFAULT_BIN}"
            fi
        fi

        # ── Still nothing? Ask the user ──────────────────────────────────────
        if [[ -z "$INSTALLER_TO_RUN" ]]; then
            warn "No Xilinx installer found in ${DIR_XILINX}/ or ~/Downloads."
            echo ""
            echo -e "  ${YELLOW}Select installer type:${NC}"
            echo -e "  ${GREEN}1)${NC} Offline installer (xsetup)"
            echo -e "  ${GREEN}2)${NC} .bin file in another location"
            echo -e "  ${GREEN}3)${NC} Skip for now"
            while true; do
                read -rp "  Choice [1/2/3]: " CH
                case "$CH" in
                    1)
                        prompt_file "Full path to xsetup" INSTALLER_TO_RUN || return 1
                        INSTALLER_TYPE="xsetup"; break ;;
                    2)
                        prompt_file "Full path to .bin installer" INSTALLER_TO_RUN || return 1
                        INSTALLER_TYPE="bin"; break ;;
                    3) warn "Xilinx install skipped."; return 0 ;;
                    *) echo -e "  ${RED}Invalid.${NC}" ;;
                esac
            done
        else
            echo -e "  ${GREEN}Found:${NC} ${INSTALLER_TO_RUN}"
            read -rp "  Use this installer? [Y/n]: " OK
            [[ "${OK,,}" == "n" ]] && { warn "Xilinx install skipped."; return 0; }
        fi

        chmod 755 "${INSTALLER_TO_RUN}"
        if [[ "$INSTALLER_TYPE" == "xsetup" ]]; then
            cd "$(dirname "${INSTALLER_TO_RUN}")"
            ./xsetup
            cd - > /dev/null
        else
            "${INSTALLER_TO_RUN}"
        fi
    fi

    # ── Verify correct install path ───────────────────────────────────────────
    if [[ ! -d "${XILINX_VER_ROOT}" ]]; then
        echo -e "\n${RED}  ✗ Not found at ${XILINX_VER_ROOT}${NC}"
        echo -e "${YELLOW}  If installed to /opt/ instead of /opt/Xilinx/:${NC}"
        echo -e "    sudo rm -rf /opt/${XILINX_VERSION} /opt/DocNav /opt/xic /opt/.xinstall"
        echo -e "    Re-run this script and install to /opt/Xilinx"
        return 1
    fi

    # ── Move companion dirs (safe — no baked-in paths) ───────────────────────
    mkdir -p "${XILINX_ROOT}"
    for dir in "DocNav" "xic" ".xinstall"; do
        [[ -d "/opt/${dir}" ]] && mv "/opt/${dir}" "${XILINX_ROOT}/${dir}" && \
            info "Moved /opt/${dir} → ${XILINX_ROOT}/${dir}"
    done

    # ── .bashrc ───────────────────────────────────────────────────────────────
    local MARKER="# ── XILINX LICENSE AND ENVIRONMENT"
    if grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
        warn "Xilinx .bashrc block already present — skipping."
    else
        cat >> "$BASHRC" <<XILINX_ENV

# ── XILINX LICENSE AND ENVIRONMENT ─────────────────────────────────────────
# Added by setup.sh (snbhowmik) — do not edit manually
$(  for f in Vitis Vivado Model_Composer PDM; do
        fp="${XILINX_VER_ROOT}/${f}/settings64.sh"
        [[ -f "$fp" ]] && echo "source ${fp}"
    done
)
export LM_LICENSE_FILE=${XILINX_PORT}@${LICENSE_SERVER_IP}:${XILINX_PORT}@${LICENSE_SERVER_HOSTNAME}
export XILINXD_LICENSE_FILE=${XILINX_PORT}@${LICENSE_SERVER_IP}:${XILINX_PORT}@${LICENSE_SERVER_HOSTNAME}
export PATH=${XILINX_VER_ROOT}/Vitis/bin:\$PATH
export PATH=${XILINX_VER_ROOT}/Vivado/bin:\$PATH
# ──────────────────────────────────────────────────────────────────────────
XILINX_ENV
        chown "${STUDENT_USER}:${STUDENT_USER}" "$BASHRC"
        info "Xilinx environment written to ${BASHRC}"
    fi

    # ── Desktop shortcuts ─────────────────────────────────────────────────────
    local ROOT_DESKTOP="/root/Desktop"
    local STUDENT_DESKTOP="${STUDENT_HOME}/Desktop"
    local SYSTEM_APPS="/usr/share/applications"
    mkdir -p "$STUDENT_DESKTOP"
    chown "${STUDENT_USER}:${STUDENT_USER}" "$STUDENT_DESKTOP"

    if compgen -G "${ROOT_DESKTOP}/*.desktop" > /dev/null 2>&1; then
        for src in "${ROOT_DESKTOP}"/*.desktop; do
            local fname; fname="$(basename "$src")"
            sed -i "s|/opt/${XILINX_VERSION}|${XILINX_VER_ROOT}|g; \
                    s|/opt/DocNav|${XILINX_ROOT}/DocNav|g; \
                    s|/opt/xic|${XILINX_ROOT}/xic|g" "$src"
            cp "$src" "${SYSTEM_APPS}/${fname}" && chmod 644 "${SYSTEM_APPS}/${fname}"
            cp "$src" "${STUDENT_DESKTOP}/${fname}"
            chown "${STUDENT_USER}:${STUDENT_USER}" "${STUDENT_DESKTOP}/${fname}"
            chmod 755 "${STUDENT_DESKTOP}/${fname}"
        done
        command -v update-desktop-database &>/dev/null && \
            update-desktop-database "${SYSTEM_APPS}" && info "GNOME app menu updated."
        command -v gio &>/dev/null && \
            for f in "${STUDENT_DESKTOP}"/*.desktop; do
                gio set "$f" metadata::trusted true 2>/dev/null || true
            done
        info "Desktop shortcuts installed."
    else
        warn "No .desktop files in /root/Desktop — shortcuts skipped."
    fi

    # ── USB cable drivers ─────────────────────────────────────────────────────
    local DRV="${XILINX_VER_ROOT}/data/xicom/cable_drivers/lin64/install_script/install_drivers/install_drivers"
    if [[ -f "$DRV" ]]; then
        chmod 755 "$DRV" && "$DRV" && info "USB cable drivers installed."
    else
        warn "Cable driver script not found — install manually if needed."
    fi

    phase_done "XILINX"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 : Cadence
#
#  The Cadence environment is MASSIVE (~60 env vars, ~200 PATH entries).
#  Loading it on every terminal open crashes the terminal application.
#
#  Solution: LAZY LOADING
#    - A full env script is generated at ${CADENCE_INSTALL_DIR}/cadence-env.sh
#    - Only a small loader function is added to .bashrc
#    - Student types "cadence-env" to activate the environment when needed
# ─────────────────────────────────────────────────────────────────────────────
run_cadence() {
    require_preinstall || return 0

    if is_done "CADENCE"; then
        warn "Cadence already marked complete."
        read -rp "  Force re-run? [y/N]: " FORCE
        [[ "${FORCE,,}" != "y" ]] && return 0
    fi

    section "CADENCE ANALOG + DIGITAL TOOLS"

    # ── Create install directory ─────────────────────────────────────────────
    mkdir -p "${CADENCE_INSTALL_DIR}"
    chmod 755 "${CADENCE_INSTALL_DIR}"

    # ── Extract tarballs from CADENCE/ folder ────────────────────────────────
    for TARBALL_NAME in "Digital_RHEL_8.tar.gz" "Analog_RHEL_8.tar.gz"; do
        local TARBALL_PATH="${DIR_CADENCE}/${TARBALL_NAME}"

        if [[ -f "${TARBALL_PATH}" ]]; then
            info "Extracting ${TARBALL_NAME} → ${CADENCE_INSTALL_DIR} ..."
            tar -xzvf "${TARBALL_PATH}" -C "${CADENCE_INSTALL_DIR}"
            info "Done: ${TARBALL_NAME}"
        else
            # Fallback: check sysadmin Downloads
            local FALLBACK="${SYSADMIN_HOME}/Downloads/${TARBALL_NAME}"
            if [[ -f "$FALLBACK" ]]; then
                info "Found in Downloads: ${FALLBACK}"
                tar -xzvf "${FALLBACK}" -C "${CADENCE_INSTALL_DIR}"
                info "Done: ${TARBALL_NAME}"
            else
                warn "Not found: ${TARBALL_PATH}"
                echo -e "  ${YELLOW}Enter path to ${TARBALL_NAME} (or press ENTER to skip):${NC}"
                read -rp "  Path: " USER_PATH
                if [[ -f "${USER_PATH}" ]]; then
                    tar -xzvf "${USER_PATH}" -C "${CADENCE_INSTALL_DIR}"
                    info "Done: ${TARBALL_NAME}"
                else
                    warn "Skipping ${TARBALL_NAME} — extract manually later."
                fi
            fi
        fi
    done

    # ── Generate cadence-env.sh (bash translation of the csh env script) ─────
    #
    # This is the FULL environment setup for all Cadence tools.
    # It is auto-sourced on terminal open via .bashrc.
    # The _cds_add_path helper only adds existing directories, keeping startup fast.
    #
    local CADENCE_ENV_SCRIPT="${CADENCE_INSTALL_DIR}/cadence-env.sh"

    info "Generating Cadence environment script: ${CADENCE_ENV_SCRIPT}"

    cat > "${CADENCE_ENV_SCRIPT}" <<'CADENCE_ENV_HEADER'
#!/bin/bash
# =============================================================================
#  CADENCE TOOL ENVIRONMENT — AUTO-GENERATED BY setup.sh
#  Author: snbhowmik
#
#  This script is auto-sourced by .bashrc on every terminal open.
#  It uses _cds_add_path to only add directories that exist on disk,
#  keeping startup fast and preventing terminal crashes.
# =============================================================================

# Guard: don't load twice in the same shell
if [[ "${_CADENCE_ENV_LOADED:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

CADENCE_ENV_HEADER

    # Now append the tool definitions (these use the actual CADENCE_INSTALL_DIR)
    cat >> "${CADENCE_ENV_SCRIPT}" <<CADENCE_ENV_BODY

# ─────────────────────────────────────────────────────────────────────────────
# PATH HELPER — adds directories to PATH only if they exist
# ─────────────────────────────────────────────────────────────────────────────
_cds_add_path() {
    local dir
    for dir in "\$@"; do
        [[ -d "\$dir" ]] && export PATH="\${dir}:\${PATH}"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# BASE SETTINGS
# ─────────────────────────────────────────────────────────────────────────────
export CDS_Netlisting_Mode=Analog
export QRC_ENABLE_QRCRACTION="1"
export CDS_AUTO_64BIT=ALL
export CDS_AHDLCMI_ENABLE=YES
export EDITOR=gedit
export LANG=en_US

# ─────────────────────────────────────────────────────────────────────────────
# LICENSE
# ─────────────────────────────────────────────────────────────────────────────
export LM_LICENSE_FILE="${CADENCE_PORT}@${LICENSE_SERVER_IP}"
export CDS_LIC_FILE="\${LM_LICENSE_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# TOOL HOMES  — CIC (Custom IC)
# ─────────────────────────────────────────────────────────────────────────────
export LIBERATEHOME="${CADENCE_INSTALL_DIR}/LIBERATE201"

export CDSHOME="${CADENCE_INSTALL_DIR}/IC618"
export ASSURAHOME="${CADENCE_INSTALL_DIR}/ASSURA41"
export QRC_HOME="${CADENCE_INSTALL_DIR}/QUANTUS212"
export PVSHOME="${CADENCE_INSTALL_DIR}/PVS222"
export MMSIMHOME="${CADENCE_INSTALL_DIR}/SPECTRE211"

# ─────────────────────────────────────────────────────────────────────────────
# TOOL HOMES  — ASIC
# ─────────────────────────────────────────────────────────────────────────────
export IUSHOME="${CADENCE_INSTALL_DIR}/INCISIVE152"
export LECHOME="${CADENCE_INSTALL_DIR}/CONFRML211"
export INNOVUSHOME="${CADENCE_INSTALL_DIR}/INNOVUS211"
export GENUSHOME="${CADENCE_INSTALL_DIR}/GENUS211"
export MODUSHOME="${CADENCE_INSTALL_DIR}/MODUS201"
export SSVHOME="${CADENCE_INSTALL_DIR}/SSV221"

# ─────────────────────────────────────────────────────────────────────────────
# TOOL HOMES  — ADDITIONAL
# ─────────────────────────────────────────────────────────────────────────────
export JASPERHOME="${CADENCE_INSTALL_DIR}/JASPER1909"
export MVSHOME="${CADENCE_INSTALL_DIR}/MVS202"
export SIGRITYHOME="${CADENCE_INSTALL_DIR}/SIGRITY20211"
export STRATUSHOME="${CADENCE_INSTALL_DIR}/STRATUS202"
export XCELIUMHOME="${CADENCE_INSTALL_DIR}/XCELIUM2209"
export ULTRASIMHOME="${CADENCE_INSTALL_DIR}/ULTRASIM181"
export VMANAGERHOME="${CADENCE_INSTALL_DIR}/VMANAGER2009"
export INTEGRANDHOME="${CADENCE_INSTALL_DIR}/INTEGRAND60"
export JLSHOME="${CADENCE_INSTALL_DIR}/JLS201"

# ─────────────────────────────────────────────────────────────────────────────
# TOOL HOMES  — PCB
# ─────────────────────────────────────────────────────────────────────────────
export SPBHOME="${CADENCE_INSTALL_DIR}/SPB174"

# ─────────────────────────────────────────────────────────────────────────────
# FOUNDRY / LIBRARIES
# ─────────────────────────────────────────────────────────────────────────────
export FOUNDRY="${CADENCE_INSTALL_DIR}/FOUNDRY"
export ANALOG="\${FOUNDRY}/analog"
export STDCELL="\${FOUNDRY}/stdcell"
export FINFET="\${FOUNDRY}/cds_ff_mpt_v_1.0"
export DIGITAL="\${FOUNDRY}/digital"
export dig_45nm="\${DIGITAL}/45nm"

# ─────────────────────────────────────────────────────────────────────────────
# DERIVED VARIABLES
# ─────────────────────────────────────────────────────────────────────────────
export CDS_INST_DIR="\${CDSHOME}"
export AMSHOME="\${IUSHOME}"

# LD_LIBRARY_PATH — only add existing directories
export LD_LIBRARY_PATH="\${CDS_INST_DIR}/tools/lib:\${CDS_INST_DIR}/tools/dfII/lib:\${IUSHOME}/tools/lib:\${LD_LIBRARY_PATH:-}"

# ─────────────────────────────────────────────────────────────────────────────
# PATH  — add tool bin directories (only if they exist on disk)
# ─────────────────────────────────────────────────────────────────────────────

# CIC tools
_cds_add_path \\
    "\${CDS_INST_DIR}/bin" "\${CDS_INST_DIR}/tools/bin" \\
    "\${MMSIMHOME}/bin" \\
    "\${ASSURAHOME}/bin" "\${ASSURAHOME}/tools/bin" "\${ASSURAHOME}/tools/dfII/bin" \\
    "\${ASSURAHOME}/tools.lnx86/dfII/bin" "\${ASSURAHOME}/share/bin" \\
    "\${PVSHOME}/bin" "\${PVSHOME}/tools/bin" "\${PVSHOME}/tools.lnx86/bin" \\
    "\${PVSHOME}/tools/dfII/bin" "\${PVSHOME}/tools/assura/bin" \\
    "\${QRC_HOME}/tools/bin" \\
    "\${LIBERATEHOME}/bin" "\${LIBERATEHOME}/tools.lnx86/bin" "\${LIBERATEHOME}/tools.lnx86/dfII/bin"

# ASIC tools
_cds_add_path \\
    "\${IUSHOME}/bin" "\${IUSHOME}/tools.lnx86/bin" "\${IUSHOME}/tools/dfII/bin" \\
    "\${IUSHOME}/tools.lnx86/dfII/bin" "\${IUSHOME}/share/bin" \\
    "\${LECHOME}/bin" "\${LECHOME}/tools.lnx86/bin" "\${LECHOME}/tools.lnx86/dfII/bin" \\
    "\${LECHOME}/share/bin" \\
    "\${GENUSHOME}/bin" "\${GENUSHOME}/share/bin" "\${GENUSHOME}/tools.lnx86/bin" \\
    "\${GENUSHOME}/tools.lnx86/dfII/bin" \\
    "\${INNOVUSHOME}/bin" "\${INNOVUSHOME}/tools/bin" "\${INNOVUSHOME}/tools/dfII/bin" \\
    "\${INNOVUSHOME}/share/bin" \\
    "\${SSVHOME}/bin" "\${SSVHOME}/tools.lnx86/bin" "\${SSVHOME}/tools.lnx86/dfII/bin" \\
    "\${SSVHOME}/share/bin" \\
    "\${MODUSHOME}/bin" "\${MODUSHOME}/tools.lnx86/bin" "\${MODUSHOME}/tools.lnx86/dfII/bin"

# Additional tools
_cds_add_path \\
    "\${XCELIUMHOME}/bin" "\${XCELIUMHOME}/tools/bin" "\${XCELIUMHOME}/tools.lnx86/bin" \\
    "\${XCELIUMHOME}/tools/dfII/bin" "\${XCELIUMHOME}/tools.lnx86/dfII/bin" \\
    "\${XCELIUMHOME}/share/bin" \\
    "\${JASPERHOME}/bin" "\${JASPERHOME}/tools.lnx86/bin" "\${JASPERHOME}/tools.lnx86/dfII/bin" \\
    "\${JASPERHOME}/share/bin" \\
    "\${MVSHOME}/bin" "\${MVSHOME}/tools.lnx86/bin" "\${MVSHOME}/tools.lnx86/dfII/bin" \\
    "\${MVSHOME}/share/bin" \\
    "\${SIGRITYHOME}/bin" "\${SIGRITYHOME}/tools.lnx86/bin" "\${SIGRITYHOME}/tools.lnx86/dfII/bin" \\
    "\${SIGRITYHOME}/share/bin" \\
    "\${STRATUSHOME}/bin" "\${STRATUSHOME}/tools.lnx86/bin" "\${STRATUSHOME}/tools.lnx86/dfII/bin" \\
    "\${STRATUSHOME}/share/bin" \\
    "\${ULTRASIMHOME}/bin" "\${ULTRASIMHOME}/tools.lnx86/bin" "\${ULTRASIMHOME}/tools.lnx86/dfII/bin" \\
    "\${ULTRASIMHOME}/share/bin" \\
    "\${VMANAGERHOME}/bin" "\${VMANAGERHOME}/tools.lnx86/bin" "\${VMANAGERHOME}/tools.lnx86/dfII/bin" \\
    "\${VMANAGERHOME}/share/bin" \\
    "\${INTEGRANDHOME}/bin" "\${INTEGRANDHOME}/tools.lnx86/bin" "\${INTEGRANDHOME}/tools.lnx86/dfII/bin" \\
    "\${INTEGRANDHOME}/share/bin" \\
    "\${JLSHOME}/bin" "\${JLSHOME}/tools.lnx86/bin" "\${JLSHOME}/tools.lnx86/dfII/bin" \\
    "\${JLSHOME}/share/bin"

# PCB tools
_cds_add_path \\
    "\${SPBHOME}/bin" "\${SPBHOME}/tools.lnx86/bin" "\${SPBHOME}/tools.lnx86/pcb/bin" \\
    "\${SPBHOME}/tools.lnx86/dfII/bin"

# ─────────────────────────────────────────────────────────────────────────────
# MARK LOADED
# ─────────────────────────────────────────────────────────────────────────────
export _CADENCE_ENV_LOADED=1

CADENCE_ENV_BODY

    chmod 644 "${CADENCE_ENV_SCRIPT}"
    info "Generated: ${CADENCE_ENV_SCRIPT}"

    # ── .bashrc — auto-source cadence-env.sh on terminal open ─────────────────
    local MARKER="# ── CADENCE ENVIRONMENT (AUTO-LOADED)"
    if grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
        warn "Cadence .bashrc block already present — skipping."
    else
        cat >> "$BASHRC" <<CADENCE_BASHRC

# ── CADENCE ENVIRONMENT (AUTO-LOADED) ─────────────────────────────────────
# Added by setup.sh (snbhowmik)
# Cadence env is auto-sourced on terminal open.
# The script only adds directories that exist on disk, keeping startup fast.
[[ -f "${CADENCE_INSTALL_DIR}/cadence-env.sh" ]] && source "${CADENCE_INSTALL_DIR}/cadence-env.sh"
# ──────────────────────────────────────────────────────────────────────────
CADENCE_BASHRC
        chown "${STUDENT_USER}:${STUDENT_USER}" "$BASHRC"
        info "Cadence environment auto-source written to ${BASHRC}"
    fi

    phase_done "CADENCE"
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 : Silvaco  (3 installers, must run in order)
# ─────────────────────────────────────────────────────────────────────────────
install_silvaco_bin() {
    local PHASE="$1"        # e.g. SILVACO_1
    local BIN_NAME="$2"     # e.g. 243423-tcadlegacyandinterco-2024-00-rh64.bin
    local LABEL="$3"        # human label

    if is_done "$PHASE"; then
        warn "${LABEL} already marked complete — skipping."
        return 0
    fi

    section "SILVACO — ${LABEL}"

    # ── Search in SILVACO/ folder alongside setup.sh ─────────────────────────
    local BIN_PATH="${DIR_SILVACO}/${BIN_NAME}"

    if [[ ! -f "$BIN_PATH" ]]; then
        # Fallback: check ~/Downloads
        local FALLBACK="${SYSADMIN_HOME}/Downloads/${BIN_NAME}"
        if [[ -f "$FALLBACK" ]]; then
            BIN_PATH="$FALLBACK"
            info "Found in Downloads: ${BIN_PATH}"
        else
            warn "Not found: ${BIN_PATH}"
            echo -e "  ${YELLOW}Enter path to ${BIN_NAME} (or press ENTER to skip):${NC}"
            read -rp "  Path: " USER_PATH
            if [[ -f "${USER_PATH}" ]]; then
                BIN_PATH="${USER_PATH}"
            else
                warn "Skipping ${LABEL} — run again when the file is available."
                return 0
            fi
        fi
    fi

    info "Running installer: ${BIN_NAME}"
    chmod 755 "${BIN_PATH}"
    sudo bash "${BIN_PATH}"

    phase_done "$PHASE"
}

run_silvaco() {
    require_preinstall || return 0

    section "SILVACO TOOL SUITE"
    echo -e "  ${YELLOW}Silvaco tools must be installed in this order:${NC}"
    echo -e "  ${GREEN}3a)${NC} TCAD Legacy & Interconnect  (${SILVACO_BIN_1})"
    echo -e "  ${GREEN}3b)${NC} Victory TCAD 2025           (${SILVACO_BIN_2})"
    echo -e "  ${GREEN}3c)${NC} Victory STR 2025            (${SILVACO_BIN_3})"
    echo ""

    if [[ -d "$DIR_SILVACO" ]]; then
        info "Silvaco folder: ${DIR_SILVACO}"
        echo -e "  ${CYAN}Files found:${NC}"
        ls -1 "$DIR_SILVACO"/ 2>/dev/null | head -10 || echo "  (empty)"
        echo ""
    else
        warn "SILVACO/ folder not found at: ${DIR_SILVACO}"
        warn "Create it and place the .bin files inside, or provide paths manually."
        echo ""
    fi

    install_silvaco_bin "SILVACO_1" "$SILVACO_BIN_1" "TCAD Legacy & Interconnect"
    install_silvaco_bin "SILVACO_2" "$SILVACO_BIN_2" "Victory TCAD 2025"
    install_silvaco_bin "SILVACO_3" "$SILVACO_BIN_3" "Victory STR 2025"

    # ── .bashrc (only once, after all three are done / attempted) ─────────────
    local MARKER="# ── SILVACO LICENSE AND ENVIRONMENT"
    if grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
        warn "Silvaco .bashrc block already present — skipping."
    else
        cat >> "$BASHRC" <<SILVACO_ENV

# ── SILVACO LICENSE AND ENVIRONMENT ────────────────────────────────────────
# Added by setup.sh (snbhowmik)
export PATH="${SILVACO_INSTALL_DIR}/bin:\$PATH"
export LM_LICENSE_FILE="${SILVACO_PORT}@${LICENSE_SERVER_HOSTNAME}"
export SFLM_FLEXLM=1
# ──────────────────────────────────────────────────────────────────────────
SILVACO_ENV
        chown "${STUDENT_USER}:${STUDENT_USER}" "$BASHRC"
        info "Silvaco environment written to ${BASHRC}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5 : Synopsys  (placeholder)
# ─────────────────────────────────────────────────────────────────────────────
run_synopsys() {
    require_preinstall || return 0

    section "SYNOPSYS — COMING SOON"
    echo -e "  ${YELLOW}Synopsys installation is not yet implemented.${NC}"
    echo -e "  ${YELLOW}When installers are available, place them in:${NC}"
    echo -e "    ${DIR_SYNOPSYS}/"
    echo ""
    echo -e "  ${DIM}The pre-install dependencies already cover Synopsys requirements.${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4 : CADRE VisualTCAD
# ─────────────────────────────────────────────────────────────────────────────
run_cadre() {
    require_preinstall || return 0

    if is_done "CADRE"; then
        warn "CADRE already marked complete."
        read -rp "  Force re-run? [y/N]: " FORCE
        [[ "${FORCE,,}" != "y" ]] && return 0
    fi

    section "CADRE VisualTCAD"

    # ── Find installer ───────────────────────────────────────────────────────
    local BIN_PATH="${DIR_CADRE}/${CADRE_BIN}"

    if [[ ! -f "$BIN_PATH" ]]; then
        # Fallback: check ~/Downloads
        local FALLBACK="${SYSADMIN_HOME}/Downloads/${CADRE_BIN}"
        if [[ -f "$FALLBACK" ]]; then
            BIN_PATH="$FALLBACK"
            info "Found in Downloads: ${BIN_PATH}"
        else
            warn "Not found: ${BIN_PATH}"
            echo -e "  ${YELLOW}Enter path to ${CADRE_BIN} (or press ENTER to skip):${NC}"
            read -rp "  Path: " USER_PATH
            if [[ -f "${USER_PATH}" ]]; then
                BIN_PATH="${USER_PATH}"
            else
                warn "Skipping CADRE — run again when the file is available."
                return 0
            fi
        fi
    fi

    info "Running CADRE installer: ${CADRE_BIN}"
    chmod 755 "${BIN_PATH}"
    sudo bash "${BIN_PATH}"

    # ── .bashrc ───────────────────────────────────────────────────────────────
    local MARKER="# ── CADRE ENVIRONMENT"
    if grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
        warn "CADRE .bashrc block already present — skipping."
    else
        cat >> "$BASHRC" <<CADRE_ENV

# ── CADRE ENVIRONMENT ─────────────────────────────────────────────────────
# Added by setup.sh (snbhowmik)
export PATH="${CADRE_INSTALL_DIR}/bin:\$PATH"
# ──────────────────────────────────────────────────────────────────────────
CADRE_ENV
        chown "${STUDENT_USER}:${STUDENT_USER}" "$BASHRC"
        info "CADRE environment written to ${BASHRC}"
    fi

    phase_done "CADRE"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN LOOP
# ─────────────────────────────────────────────────────────────────────────────
while true; do
    show_dashboard
    read -rp "  Select option: " CHOICE
    echo ""
    case "${CHOICE,,}" in
        0) run_pre_install ;;
        1) run_xilinx ;;
        2) run_cadence ;;
        3) run_silvaco ;;
        4) run_synopsys ;;
        5) run_cadre ;;
        s) continue ;;
        l)
            echo -e "\n${CYAN}── Last 40 lines of install log ──────────────────────${NC}"
            tail -40 "$LOG_FILE"
            echo -e "${CYAN}── Full log: ${LOG_FILE} ──────────────────────────────${NC}\n"
            read -rp "Press ENTER to return to menu... "
            ;;
        q) echo -e "\n${GREEN}Goodbye. State saved at: ${STATE_FILE}${NC}\n"; exit 0 ;;
        *) echo -e "  ${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
    echo ""
    read -rp "  Press ENTER to return to menu... "
done
