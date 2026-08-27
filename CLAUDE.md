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

`src/installer/config.rs::LabConfig` is the one piece of state everything else reads. It's derived from a machine number (`sysadmin309{N}` / `srmist309{N}` / `vlsilab{N}.ist.srmtrichy.edu.in`) and persisted to `/var/log/vlsilab/install.state` as flat `KEY=VALUE` lines — phase completion flags (`XILINX=DONE`, `CADENCE_TIME=...`, etc.) and machine identity. If `VLSI_SITE_CONFIG` is set (passed by `setup.sh` after site setup), every state write is also mirrored to `$VLSI_SITE_CONFIG/machine_states/machine_{N}.state`, which is how a shared NFS/site directory aggregates state across the 20 lab workstations.

`get_root_dir()` resolves where `CADENCE/`, `XILINX/`, etc. live: it's simply the saved `SCRIPT_DIR` (the directory `setup.sh` was invoked from). `setup.sh` validates those tool folders as direct children of that same directory before it ever launches the TUI, and launches the TUI binary with that directory as its `cwd` — so `get_root_dir()` must equal `get_script_dir()`, not a parent of it. (It briefly climbed one level up in this repo's history, which broke every `get_tool_dir()` lookup — don't reintroduce that.)

### TUI shell (`src/app.rs`, `src/main.rs`, `src/ui/layout.rs`)

Three-pane layout: Main Menu → Actions (sub-menu) → Details, plus a full-screen Log Stream view (`Focus` enum controls which pane has input focus). `App::handle_sub_menu_execute()` is the dispatcher for every menu action; `main.rs`'s event loop just routes key events into it or into one of the three modal input prompts (`InputMode`: machine number, add-user, custom-dependency).

**Every long-running action (installs, pre-install, dependency resolution, add-user) follows the same pattern**: set focus to `Focus::LogStream`, clone `log_tx` and the shared `busy: Arc<AtomicBool>`, `tokio::spawn` the async work, and only flip `busy` back to `false` **from inside the spawned task** once it actually finishes. Do not set `busy` to `false` right after calling `tokio::spawn` — that was the TUI bug fixed in this repo's history (the log view would flash "Task Complete" while the install was still running in the background). `App::on_tick()` watches for the `busy: true → false` edge and calls `refresh_users()` so background changes (new user, freshly-installed tool) show up without an explicit refresh action.

Progress and errors from spawned tasks reach the UI only through `log_tx: mpsc::UnboundedSender<String>` — there's no other channel back to `App` from a background task. `App::poll_logs()` drains it every frame.

`sys_validation.rs` and `network.rs` each run their own independent background scan (`spawn_system_validation` / `spawn_network_checks`) into an `Arc<Mutex<...>>` state the Dashboard/Network panes read directly; they're not gated by the `busy` flag since they're passive checks, not mutating actions.

### EDA environment generation (`src/installer/launcher.rs`, `src/installer/tools.rs`)

This is the part most tool-launch bugs come from, and it spans two generated files:

- `/opt/cadence/cadence-env.sh` — Cadence-only. Every `TOOL HOME` (LIBERATEHOME, CDSHOME, ASSURAHOME, QRC_HOME, PVSHOME, MMSIMHOME, IUSHOME, LECHOME, INNOVUSHOME, GENUSHOME, MODUSHOME, SSVHOME, JASPERHOME, MVSHOME, SIGRITYHOME, STRATUSHOME, XCELIUMHOME, ULTRASIMHOME, VMANAGERHOME, INTEGRANDHOME, JLSHOME, SPBHOME) has to be defined here even if that sub-tool isn't installed yet — `_cds_add_path` silently no-ops on missing directories, but a *missing env var* breaks the tool's own launcher scripts. Adding a new Cadence tool means adding its home dir here, not just a wrapper function in eda-launcher.sh.
- `/opt/vlsilab/eda-launcher.sh` — sourced by every user's `.bashrc` (injected by `user_mgr.rs::create_or_configure_student_user`). It stays cheap at shell startup: X11 display vars, the combined license server string, and Silvaco/CADRE PATH exports run unconditionally, but Xilinx and Cadence are lazy — `vivado`/`virtuoso`/etc. are wrapper functions that source the heavy environment (`settings64.sh` for Xilinx, `cadence-env.sh` for Cadence) on first call, then `unset -f` themselves so the real binary is used directly afterward. **Every Cadence binary needs a matching wrapper function here** (virtuoso, spectre, genus, innovus, xcelium, modus, liberate, pegasus) — a tool home defined in cadence-env.sh with no wrapper here is unreachable from a fresh shell.

`launcher.rs::recreate_env(tool, tx)` regenerates both files: for `"cadence"` it rewrites `cadence-env.sh`, then always calls `write_base_launcher()` to rewrite `eda-launcher.sh`. For `"xilinx"/"silvaco"/"cadre"` there's no separate per-tool file — those environments are fully inline in `eda-launcher.sh` — so `recreate_env` just refreshes the launcher. `sys_validation.rs`'s "Environment Script" status check mirrors this split: Cadence checks `CADENCE_ENV_FILE`, everything else checks `EDA_LAUNCHER`.

The repo root has untracked local copies of `cadence-env.sh` and `eda-launcher.sh` (not in git — they're deployed/reference copies, not source). When changing what `launcher.rs` generates, treat those files as the canonical target content to match, and keep them in sync manually if you update one side.

### Installing tool binaries (`src/installer/tools.rs`)

Cadence is structurally different from the other three tools: it isn't a single installer binary, it's delivered as one already-extracted folder per sub-tool under `CADENCE/` (`CADENCE/IC618/`, `CADENCE/GENUS211/`, etc. — the same names as the `TOOL HOME` dirs in `cadence-env.sh`). `install_cadence()` copies (`cp -a`) each present one straight into `/opt/cadence/<NAME>/`; names listed in `CADENCE_TOOL_DIRS` but missing from `CADENCE/` are logged and skipped, not treated as failures, since not every lab has every tool licensed/delivered yet. Adding a new Cadence sub-tool means adding its dir name to `CADENCE_TOOL_DIRS` here *and* its `TOOL_HOME` in `launcher.rs`'s `CADENCE_ENV_SCRIPT` *and* a wrapper function in `EDA_LAUNCHER_SCRIPT` — all three, or the tool will be silently unreachable somewhere in that chain.

JASPER is a special case within that: it's vendored as a doubly-wrapped archive (observed name pattern `*.tar.gz.gtar`) whose extraction produces a folder containing one more single-child folder before the real payload. `prepare_jasper_archive()` runs before the copy pass, finds that archive by filename (case-insensitive `"jasper"` + a tar-like extension) only if `CADENCE/JASPER2209/` doesn't already exist, extracts it to a scratch dir, unwraps however many redundant single-child folder levels wrap the payload (`unwrap_single_child_dirs` — not hardcoded to exactly two), and moves the payload's contents into `CADENCE/JASPER2209/` so the generic copy pass treats it like any other tool.

`install_xilinx`/`install_silvaco`/`install_cadre` are still stubs: they only check the source directory exists, mark the phase done, and call `recreate_env` — they never invoke the vendor `.bin` installer. Don't assume those tools get installed by running the TUI; only Cadence's folder-copy install is real right now.

### Not yet implemented

`docs/CLUSTER_TRACKER_ARCHITECTURE.md` describes a planned `vlsilab daemon` (systemd service, polls running processes via `sysinfo`, logs sessions/tool usage to a shared SQLite/Postgres `tracker.db` for sysadmin reporting across all 20 workstations). None of that exists in `src/` yet — it's a design doc for future work, not current behavior.
