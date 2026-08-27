# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

C2S Setup Tool — a two-stage installer for configuring RHEL 8 workstations in the SRM IST Trichy VLSI Lab with EDA tools (Xilinx Vivado/Vitis, Cadence, Silvaco TCAD, CADRE VisualTCAD; Synopsys planned).

- `setup.sh` — a bash bootstrapper. Validates the `CADENCE/ SILVACO/ XILINX/ SYNOPSYS/ CADRE/` directory layout next to it, prompts for site config (lab name, hostname format, machine count) on first run, downloads the matching `c2s-setup-linux-amd64` release from GitHub with SHA256 verification (falls back to a cached local binary when offline), then `exec`s it.
- The Rust binary (`src/`) — a Ratatui TUI that does the actual work: installing tool binaries, generating shell environments, provisioning lab users, and running diagnostics. This is almost always what you're editing.

## Commands

```bash
cargo build              # debug build
cargo build --release    # release build (this is what setup.sh downloads/runs)
cargo run                # run the TUI locally (most install actions need root — run under sudo)
cargo check               # fast type-check without codegen
```

There is no test suite (`cargo test` has nothing to run) and no lint config beyond rustc's default warnings — `cargo build` output is the correctness signal.

## Architecture

### Config and state

`src/installer/config.rs::LabConfig` is the one piece of state everything else reads. It's derived from a machine number (`sysadmin309{N}` / `srmist309{N}` / `vlsilab{N}.ist.srmtrichy.edu.in`) and persisted to `/var/log/vlsilab/install.state` as flat `KEY=VALUE` lines — phase completion flags (`XILINX=DONE`, `CADENCE_TIME=...`, etc.) and machine identity. If `VLSI_SITE_CONFIG` is set (passed by `setup.sh` after site setup), every state write is also mirrored to `$VLSI_SITE_CONFIG/machine_states/machine_{N}.state`, which is how a shared NFS/site directory aggregates state across the 20 lab workstations. `get_root_dir()` walks up from the saved `SCRIPT_DIR` to resolve where the `CADENCE/`, `XILINX/`, etc. installer source folders live relative to the repo checkout — installers assume they're one level above `vlsilab-srmist/`.

### TUI shell (`src/app.rs`, `src/main.rs`, `src/ui/layout.rs`)

Three-pane layout: Main Menu → Actions (sub-menu) → Details, plus a full-screen Log Stream view (`Focus` enum controls which pane has input focus). `App::handle_sub_menu_execute()` is the dispatcher for every menu action; `main.rs`'s event loop just routes key events into it or into one of the three modal input prompts (`InputMode`: machine number, add-user, custom-dependency).

**Every long-running action (installs, pre-install, dependency resolution, add-user) follows the same pattern**: set focus to `Focus::LogStream`, clone `log_tx` and the shared `busy: Arc<AtomicBool>`, `tokio::spawn` the async work, and only flip `busy` back to `false` **from inside the spawned task** once it actually finishes. Do not set `busy` to `false` right after calling `tokio::spawn` — that was the TUI bug fixed in this repo's history (the log view would flash "Task Complete" while the install was still running in the background). `App::on_tick()` watches for the `busy: true → false` edge and calls `refresh_users()` so background changes (new user, freshly-installed tool) show up without an explicit refresh action.

Progress and errors from spawned tasks reach the UI only through `log_tx: mpsc::UnboundedSender<String>` — there's no other channel back to `App` from a background task. `App::poll_logs()` drains it every frame.

`sys_validation.rs` and `network.rs` each run their own independent background scan (`spawn_system_validation` / `spawn_network_checks`) into an `Arc<Mutex<...>>` state the Dashboard/Network panes read directly; they're not gated by the `busy` flag since they're passive checks, not mutating actions.

### EDA environment generation (`src/installer/launcher.rs`, `src/installer/tools.rs`)

This is the part most tool-launch bugs come from, and it spans two generated files:

- `/opt/cadence/cadence-env.sh` — Cadence-only. Every `TOOL HOME` (LIBERATEHOME, CDSHOME, ASSURAHOME, QRC_HOME, PVSHOME, MMSIMHOME, IUSHOME, LECHOME, INNOVUSHOME, GENUSHOME, MODUSHOME, SSVHOME, JASPERHOME, MVSHOME, SIGRITYHOME, STRATUSHOME, XCELIUMHOME, ULTRASIMHOME, VMANAGERHOME, INTEGRANDHOME, JLSHOME, SPBHOME) has to be defined here even if that sub-tool isn't installed yet — `_cds_add_path` silently no-ops on missing directories, but a *missing env var* breaks the tool's own launcher scripts. Adding a new Cadence tool means adding its home dir here, not just a wrapper function in eda-launcher.sh.
- `/opt/vlsilab/eda-launcher.sh` — sourced by every user's `.bashrc` (injected by `user_mgr.rs::create_or_configure_student_user`). It stays cheap at shell startup: X11 display vars, the combined license server string, and Silvaco/CADRE PATH exports run unconditionally, but Xilinx and Cadence are lazy — `vivado`/`virtuoso`/etc. are wrapper functions that source the heavy environment (`settings64.sh` for Xilinx, `cadence-env.sh` for Cadence) on first call, then `unset -f` themselves so the real binary is used directly afterward. **Every Cadence binary needs a matching wrapper function here** (virtuoso, spectre, genus, innovus, xcelium, modus, liberate, pegasus) — a tool home defined in cadence-env.sh with no wrapper here is unreachable from a fresh shell.

`launcher.rs::recreate_env(tool, tx)` regenerates both files: for `"cadence"` it rewrites `cadence-env.sh`, then always calls `write_base_launcher()` to rewrite `eda-launcher.sh`. For `"xilinx"/"silvaco"/"cadre"` there's no separate per-tool file — those environments are fully inline in `eda-launcher.sh` — so `recreate_env` just refreshes the launcher. `tools.rs::install_*` functions check that the tool's source directory exists under `LabConfig::get_tool_dir()`, mark the install phase done, then call `recreate_env` to (re)generate the environment. `sys_validation.rs`'s "Environment Script" status check mirrors this split: Cadence checks `CADENCE_ENV_FILE`, everything else checks `EDA_LAUNCHER`.

The repo root has untracked local copies of `cadence-env.sh` and `eda-launcher.sh` (not in git — they're deployed/reference copies, not source). When changing what `launcher.rs` generates, treat those files as the canonical target content to match, and keep them in sync manually if you update one side.

### Not yet implemented

`docs/CLUSTER_TRACKER_ARCHITECTURE.md` describes a planned `vlsilab daemon` (systemd service, polls running processes via `sysinfo`, logs sessions/tool usage to a shared SQLite/Postgres `tracker.db` for sysadmin reporting across all 20 workstations). None of that exists in `src/` yet — it's a design doc for future work, not current behavior.
