#!/bin/bash
# =============================================================================
#  VLSI LAB — UNIFIED EDA RATATUI SETUP & USER MANAGER BOOTSTRAPPER
#  SRM Institute of Science and Technology, Trichy
#  Author: snbhowmik [Subir Nath Bhowmik]
#
#  Run as : sysadmin, using sudo  →  sudo bash setup.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# PRIVILEGE CHECK
# ─────────────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[1;31m[ERROR]\033[0m Run with sudo: sudo bash $0"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# RUST & CARGO BOOTSTRAPPER
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\033[1;32m[INFO]\033[0m Checking Rust toolchain requirement..."

if ! command -v cargo &>/dev/null; then
    echo -e "\033[1;33m[WARN]\033[0m Cargo/Rust not detected. Installing Rust compiler..."
    if command -v dnf &>/dev/null; then
        dnf install -y rust cargo || {
            echo -e "\033[1;33m[INFO]\033[0m Installing Rust via rustup fallback..."
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            source "$HOME/.cargo/env"
        }
    else
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
    fi
fi

# Source cargo env if present
if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:${PATH}"

# ─────────────────────────────────────────────────────────────────────────────
# BUILD & LAUNCH RATATUI TUI
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\033[1;32m[INFO]\033[0m Building Ratatui TUI installer ('vlsilab')..."
cargo build --release

echo -e "\033[1;32m[INFO]\033[0m Launching VLSI Lab Setup TUI..."
exec ./target/release/vlsilab "$@"
