# VLSI Lab — EDA Tool Setup
### SRM Institute of Science and Technology — Trichy Campus
**Author:** snbhowmik

---

## Overview

A unified interactive setup tool for configuring RHEL 8 lab workstations with EDA tools. Everything runs from a single script (`setup.sh`) with a dashboard interface that tracks installation progress.

### Supported Tools
| Tool | Status | Install Dir |
|---|---|---|
| Xilinx Vivado/Vitis 2025.2 | ✅ Supported | /opt/Xilinx |
| Cadence (Analog + Digital) | ✅ Supported | /opt/cadence |
| Silvaco (TCAD + Victory) | ✅ Supported | /opt/sedatools |
| CADRE VisualTCAD | ✅ Supported | /opt/cadre |
| Synopsys | ⏳ Coming Soon | TBD |

---

## Folder Layout

Place your installer files alongside `setup.sh`:

```
├── setup.sh
├── lockdown.sh
├── CADENCE/
│   ├── Digital_RHEL_8.tar.gz
│   └── Analog_RHEL_8.tar.gz
├── SILVACO/
│   ├── 243423-tcadlegacyandinterco-2024-00-rh64.bin
│   ├── 255020-victorytcad-2025-01-rh64.bin
│   └── 255017-victory_str-2025-01.bin
├── XILINX/
│   └── FPGAs_AdaptiveSoCs_...Lin64.bin (or extracted xsetup folder)
├── CADRE/
│   └── Cadre-VisualTCAD-Linux-2025.04.r3-284.bin
├── SYNOPSYS/   (future)
```

---

## Quick Start

```bash
# 1. Clone or copy this repo to the lab machine
# 2. Place installer files in the appropriate subfolders
# 3. Run the setup tool
sudo bash setup.sh
```

The dashboard will guide you through:
1. **System Configuration** — hostname, student user creation
2. **Pre-Install** — dependencies, EPEL, RPM Fusion (must run first)
3. **Tool Installation** — pick any tool from the dashboard

---

## How It Works

### State Tracking
All progress is saved to `/var/log/vlsilab/install.state`. You can:
- Stop at any time and resume later
- See exactly which steps are complete
- Re-run the script from any directory

### Log File
Full installation log at `/var/log/vlsilab/install.log` — persists across reboots.

---

## Tool-Specific Notes

### Xilinx
- Installer found in `XILINX/` folder (or prompted for path)
- **Critical:** Set install directory to `/opt/Xilinx` (NOT `/opt`)
- Desktop shortcuts are auto-installed for the student user
- USB cable drivers are installed automatically

### Cadence
- Tarballs extracted from `CADENCE/` folder to `/opt/cadence`
- **Auto-sourced environment** — the Cadence env script is auto-sourced on terminal open
- Uses `_cds_add_path` to only add directories that exist on disk, keeping startup fast
- Environment script: `/opt/cadence/cadence-env.sh`
- A guard prevents double-loading in the same shell

### Silvaco
- Three `.bin` installers run in strict order:
  1. TCAD Legacy & Interconnect
  2. Victory TCAD 2025
  3. Victory STR 2025
- Installers found in `SILVACO/` folder
- Environment added to student's `.bashrc` automatically

### CADRE VisualTCAD
- Single `.bin` installer: `Cadre-VisualTCAD-Linux-2025.04.r3-284.bin`
- Installer found in `CADRE/` folder
- Environment added to student's `.bashrc` automatically

---

## User Accounts

| Account | Username | Password | Sudo? |
|---|---|---|---|
| Admin (pre-existing) | sysadmin309X | Srmist@789 | ✅ Yes |
| Student (created by script) | srmist309X | Student@SRM | ❌ No |

Replace X with machine number (1-20).

---

## License Servers

| Tool | Port | Server |
|---|---|---|
| Xilinx | 2100 | 14.139.1.126 / c2s.cdacb.in |
| Cadence | 5280 | 14.139.1.126 / c2s.cdacb.in |
| Silvaco | 27000 | c2s.cdacb.in |

---

## Lockdown

After all tools are verified working:
```bash
sudo bash lockdown.sh --dry-run   # preview first
sudo bash lockdown.sh              # apply
```

---

## Troubleshooting

| Problem | Solution |
|---|---|
| dnf update fails | Register with Red Hat Subscription Manager first |
| Vivado not found after source .bashrc | Check settings64.sh paths under /opt/Xilinx |
| Cadence tools not launching | Check license: `LM_LICENSE_FILE=5280@14.139.1.126` |
| Terminal crashes on login | Check .bashrc for stale env blocks. The auto-source uses _cds_add_path to only add existing dirs |
| Silvaco license error | Verify LM_LICENSE_FILE=27000@c2s.cdacb.in |
| USB JTAG not detected | Re-run cable driver installer |

---

*Author: snbhowmik | SRM IST Trichy — VLSI Lab*
