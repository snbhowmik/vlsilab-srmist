#!/bin/bash
# =============================================================================
#  C2S Setup Tool - Bootstrapper
#  Version: 1.10.0
#  Author: snbhowmik
# =============================================================================

set -euo pipefail

GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
BOLD="\033[1m"
NC="\033[0m"

REPO_OWNER="snbhowmik"
REPO_NAME="c2s-setup"
TUI_BIN_NAME="c2s-setup-linux-amd64"

# ─────────────────────────────────────────────────────────────────────────────
# 1. DIRECTORY STRUCTURE VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
# Since this can be run via curl | bash, $0 might be "bash".
# We require the user to be in the correct directory.
SCRIPT_DIR="$(pwd)"

MISSING=0
for DIR in "CADENCE" "SILVACO" "XILINX" "SYNOPSYS" "CADRE"; do
    if [[ ! -d "${SCRIPT_DIR}/${DIR}" ]]; then
        MISSING=1
    fi
done

if [[ $MISSING -eq 1 ]]; then
    echo -e "${RED}[ERROR] Invalid directory structure!${NC}"
    echo -e "You must run this script from the root of the installer repository."
    echo -e "\nExpected Directory Tree:"
    echo -e "  ."
    echo -e "  ├── CADENCE/"
    echo -e "  ├── CADRE/"
    echo -e "  ├── SILVACO/"
    echo -e "  ├── SYNOPSYS/"
    echo -e "  └── XILINX/"
    echo -e "\nPlease organize the installers and try again."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# PRIVILEGE CHECK
# ─────────────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] Run with sudo: curl -fsSL https://.../setup.sh | sudo bash${NC}"
    exit 1
fi

if [[ -z "${SUDO_USER:-}" ]]; then
    echo -e "${RED}[ERROR] Do not run as root directly. Log in as sysadmin and use sudo.${NC}"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. SITE CONFIGURATION PROMPT
# ─────────────────────────────────────────────────────────────────────────────
clear
echo -e "${GREEN}${BOLD}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         C2S CHIPIN EDA Installer (v1.10.0)           ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo "  Author: snbhowmik"
echo "  For more info/feedback visit: https://snbhowmik.dev"
echo "  Manual: github.com/snbhowmik/c2s-setup/README.md"
echo "  Or visit: https://snbhowmik.dev/blog/srmist-vlsilab/setup.sh"
echo -e "${NC}\n"

EXISTING_CONFIG=$(find "${SCRIPT_DIR}/site_configs" -mindepth 2 -maxdepth 2 -name "config.env" 2>/dev/null | head -n 1 || true)

if [[ -n "$EXISTING_CONFIG" && -f "$EXISTING_CONFIG" ]]; then
    echo -e "  ${GREEN}✔ Existing site configuration found: ${EXISTING_CONFIG}${NC}"
    SITE_CONFIG_DIR=$(dirname "$EXISTING_CONFIG")
else
    # Read from /dev/tty because stdin is consumed by curl | bash
    read -rp "  Enter Institution / Lab Name (e.g. MainLab): " LAB_NAME < /dev/tty
    LAB_DIR_NAME=$(echo "$LAB_NAME" | tr -cd '[:alnum:]_-')

    if [[ -z "$LAB_DIR_NAME" ]]; then
        echo -e "${RED}Invalid Lab Name.${NC}"
        exit 1
    fi

    read -rp "  Enter Hostname format (use \$\$ for machine number, e.g. vlsilab$\$.ist.srmtrichy.edu.in): " HOST_FORMAT < /dev/tty

    SITE_CONFIG_DIR="${SCRIPT_DIR}/site_configs/${LAB_DIR_NAME}"
    mkdir -p "${SITE_CONFIG_DIR}"

    CONFIG_FILE="${SITE_CONFIG_DIR}/config.env"
    cat > "${CONFIG_FILE}" <<EOF
LAB_NAME="${LAB_NAME}"
HOSTNAME_FORMAT="${HOST_FORMAT}"
CREATED_BY="${SUDO_USER}"
CREATED_AT="$(date)"
EOF

    echo -e "\n  ${GREEN}✔ Site configuration saved to ${CONFIG_FILE}${NC}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. AUTO-UPDATE & SHA VERIFICATION
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n  ${CYAN}Checking for latest TUI release on GitHub...${NC}"

LATEST_RELEASE_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
# Extract the tag name (version)
LATEST_TAG=$(curl -sL "$LATEST_RELEASE_URL" | grep -Po '"tag_name": "\K.*?(?=")' || true)

if [[ -z "$LATEST_TAG" ]]; then
    echo -e "${YELLOW}[WARN] Failed to fetch latest release info from GitHub (possibly a pre-release or rate-limited).${NC}"
    echo -e "${YELLOW}[WARN] Falling back to known stable release v1.10.0...${NC}"
    LATEST_TAG="v1.10.0"
fi

echo -e "  Latest Release: ${BOLD}${LATEST_TAG}${NC}"

BIN_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${LATEST_TAG}/${TUI_BIN_NAME}"
SHA_URL="${BIN_URL}.sha256"

TUI_LOCAL_PATH="${SCRIPT_DIR}/${TUI_BIN_NAME}"
TUI_SHA_PATH="${TUI_LOCAL_PATH}.sha256"

# Always remove old files to ensure we get the latest clean binary
rm -f "${TUI_LOCAL_PATH}" "${TUI_SHA_PATH}"

echo -e "  ${YELLOW}Downloading TUI binary...${NC}"
curl -fsSL -o "${TUI_LOCAL_PATH}" "$BIN_URL"
echo -e "  ${YELLOW}Downloading SHA256 checksum...${NC}"
curl -fsSL -o "${TUI_SHA_PATH}" "$SHA_URL"

echo -e "  ${CYAN}Verifying checksum...${NC}"
# The downloaded sha256 file should look like "hash  c2s-setup-linux-amd64"
cd "${SCRIPT_DIR}"
if sha256sum -c "${TUI_SHA_PATH}"; then
    echo -e "  ${GREEN}✔ Binary verified securely.${NC}"
else
    echo -e "${RED}[ERROR] Checksum verification failed! The binary may be corrupted or compromised.${NC}"
    rm -f "${TUI_LOCAL_PATH}" "${TUI_SHA_PATH}"
    exit 1
fi

chmod +x "${TUI_LOCAL_PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# 4. TUI INVOCATION
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n  ${GREEN}Launching C2S Setup TUI...${NC}"
sleep 1

export VLSI_SITE_CONFIG="${SITE_CONFIG_DIR}"
exec "${TUI_LOCAL_PATH}"
