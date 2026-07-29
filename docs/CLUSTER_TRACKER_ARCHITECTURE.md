# Cluster Architecture: EDA Tool Usage Tracking & Aggregation

## Overview

In the SRM IST Trichy VLSI Lab, tools such as Xilinx Vivado/Vitis, Cadence Virtuoso/Spectre, Silvaco TCAD, and CADRE VisualTCAD run on 20 individual RHEL 8 Linux workstations (`vlsilab1.ist.srmtrichy.edu.in` through `vlsilab20.ist.srmtrichy.edu.in`). Students access workstations either locally in person or remotely via VNC sessions.

To monitor tool usage, duration, and user session metrics across all 20 nodes without interfering with EDA tool execution or forcing blocking UI prompts, the tracking system uses a **decentralized daemon + central aggregation** model.

---

## Component Architecture

```
 ┌─────────────────────────────────────────────────────────────┐
 │                    WORKSTATIONS (1..20)                     │
 │                                                             │
 │  ┌─────────────────┐ ┌──────────────────┐ ┌──────────────┐  │
 │  │ vlsilab1        │ │ vlsilab2         │ │ vlsilab20    │  │
 │  │ Local Daemon    │ │ Local Daemon     │ │ Local Daemon │  │
 │  │ (sysinfo poll)  │ │ (sysinfo poll)   │ │(sysinfo poll)│  │
 │  └────────┬────────┘ └────────┬─────────┘ └──────┬───────┘  │
 └───────────┼───────────────────┼──────────────────┼──────────┘
             │                   │                  │
             └───────────────────┼──────────────────┘
                                 ▼
         ┌───────────────────────────────────────────────┐
         │     Central Server / Shared Storage (NFS)     │
         │                                               │
         │   Central Database: tracker.db (SQLite/PG)   │
         │   Location: /var/log/vlsilab/tracker.db       │
         └───────────────────────┬───────────────────────┘
                                 │
                                 ▼
         ┌───────────────────────────────────────────────┐
         │    Sysadmin Analytics & Monthly Reporting     │
         │   Restricted to user: sysadmin3091..30920     │
         │   Exports: PDF / CSV / Monthly Aggregation    │
         └───────────────────────────────────────────────┘
```

---

## 1. Local Workstation Monitoring Daemon

- **Executable**: `vlsilab daemon`
- **Service**: `/etc/systemd/system/vlsilab-tracker.service` (enabled on boot).
- **Polling Loop**: Every 10 seconds, uses the Rust `sysinfo` crate to scan active running processes across all logged-in Linux users.
- **Target Process Mapping**:
  - **Xilinx**: `vivado`, `vitis`, `xsct`, `xsim`, `xvlog`, `model_composer`
  - **Cadence**: `virtuoso`, `spectre`, `genus`, `innovus`, `xcelium`, `modus`, `liberate`, `pegasus`
  - **Silvaco**: `deckbuild`, `victory`
  - **CADRE**: `cadre`

---

## 2. Session & Identity Resolution

When a user logs into GNOME or VNC, the workstation records active user sessions.
- **Session Identification**: Maps active system username (`srmist309X`) and environment variables to student Registration Numbers or Faculty FET IDs.
- **Logging Event**:
  - `start_event`: Recorded when a target process appears in process list.
  - `heartbeat`: Recorded every 60 seconds while process continues running.
  - `stop_event`: Recorded when target process disappears. Duration calculated in seconds.

---

## 3. Storage & Schema

The central SQLite database (`/var/log/vlsilab/tracker.db` or shared NFS mount `/opt/vlsilab/shared/tracker.db`) maintains three core relational tables:

```sql
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_type TEXT NOT NULL,          -- 'Student', 'Faculty', 'Staff', 'Guest'
    identifier TEXT UNIQUE NOT NULL,   -- Reg No (e.g. RA2111003010001) or FET ID
    name TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    workstation TEXT NOT NULL,        -- 'vlsilab1'..'vlsilab20'
    system_user TEXT NOT NULL,        -- 'srmist3091'
    login_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    logout_time TIMESTAMP,
    FOREIGN KEY(user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS tool_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id INTEGER NOT NULL,
    workstation TEXT NOT NULL,
    tool_name TEXT NOT NULL,          -- 'vivado', 'virtuoso', etc.
    start_time TIMESTAMP NOT NULL,
    end_time TIMESTAMP,
    duration_seconds INTEGER DEFAULT 0,
    FOREIGN KEY(session_id) REFERENCES sessions(id)
);
```

---

## 4. Admin Reporting & Access Control

- Access to monthly reports and CSV generation via `vlsilab report` or TUI Analytics tab is **restricted to `sysadmin309X` users**.
- **Aggregation Metrics**:
  - Total hours used per EDA tool per month.
  - Usage breakdown per student / registration number.
  - Workstation utilization percentage.
