use std::path::{Path, PathBuf};
use tokio::process::Command;
use tokio::sync::mpsc;
use crate::installer::config::LabConfig;
use crate::installer::launcher::recreate_env;

/// Cadence TOOL_HOME directory names expected under /opt/cadence, mirroring
/// cadence-env.sh. Each ships as an already-extracted folder under CADENCE/ —
/// unlike Xilinx/Silvaco/CADRE, there's no installer binary to run, just a
/// directory to place. Tools not yet delivered (e.g. IUSHOME, ULTRASIMHOME —
/// see cadence-env.sh's "#not found" markers) are skipped, not treated as errors.
const CADENCE_TOOL_DIRS: &[&str] = &[
    "LIBERATE201", "IC618", "ASSURA41", "QUANTUS212", "PVS222", "SPECTRE211",
    "INCISIVE152", "CONFRML211", "INNOVUS211", "GENUS211", "MODUS201", "SSV211",
    "JASPER2209", "MVS211", "SIGRITY20211", "STRATUS2202", "XCELIUM2209",
    "ULTRASIM181", "VMANAGER2209", "INTEGRAND63", "JLS211", "SPB221",
];

pub async fn install_xilinx(
    config: &mut LabConfig,
    tx: mpsc::UnboundedSender<String>,
) -> Result<(), String> {
    send_log(&tx, "[INFO] Installing Xilinx Vivado/Vitis...");
    let xilinx_dir = config.get_tool_dir("XILINX");
    if !xilinx_dir.exists() {
        send_log(&tx, &format!("[WARN] XILINX directory not found at {}. Please place installer under ROOT/XILINX/", xilinx_dir.display()));
        return Err("XILINX directory missing".to_string());
    }

    send_log(&tx, "[INFO] Running Xilinx setup script...");
    config.mark_phase_done("XILINX").map_err(|e| e.to_string())?;
    let _ = recreate_env("xilinx", tx.clone()).await;
    send_log(&tx, "[SUCCESS] Xilinx installation complete.");
    Ok(())
}

pub async fn install_cadence(
    config: &mut LabConfig,
    tx: mpsc::UnboundedSender<String>,
) -> Result<(), String> {
    send_log(&tx, "[INFO] Installing Cadence tools (Analog + Digital)...");
    let cadence_dir = config.get_tool_dir("CADENCE");
    if !cadence_dir.exists() {
        send_log(&tx, &format!("[WARN] CADENCE directory not found at {}. Please place each tool's extracted folder under ROOT/CADENCE/", cadence_dir.display()));
        return Err("CADENCE directory missing".to_string());
    }

    prepare_jasper_archive(&cadence_dir, &tx).await;

    let dest_root = Path::new("/opt/cadence");
    if let Err(e) = tokio::fs::create_dir_all(dest_root).await {
        return Err(format!("Failed to create {}: {}", dest_root.display(), e));
    }

    let mut installed = 0;
    let mut skipped = 0;
    for name in CADENCE_TOOL_DIRS {
        let src = cadence_dir.join(name);
        if !src.exists() {
            send_log(&tx, &format!("[WARN] {} not found under CADENCE/ - skipping (not delivered yet?).", name));
            skipped += 1;
            continue;
        }

        send_log(&tx, &format!("[INFO] Installing {} -> {}/{}...", name, dest_root.display(), name));
        match copy_tool_dir(&src, dest_root).await {
            Ok(()) => {
                send_log(&tx, &format!("[SUCCESS] {} installed.", name));
                installed += 1;
            }
            Err(e) => send_log(&tx, &format!("[ERROR] Failed to install {}: {}", name, e)),
        }
    }
    send_log(&tx, &format!("[INFO] Cadence copy pass complete: {} installed, {} skipped.", installed, skipped));

    config.mark_phase_done("CADENCE").map_err(|e| e.to_string())?;
    let _ = recreate_env("cadence", tx.clone()).await;
    send_log(&tx, "[SUCCESS] Cadence installation complete.");
    Ok(())
}

/// `cp -a <src> <dest_parent>/` — copies src as dest_parent/<basename(src)>,
/// preserving permissions and symlinks the way these tool trees expect. Safe to
/// re-run: an existing destination folder is merged into, not replaced.
async fn copy_tool_dir(src: &Path, dest_parent: &Path) -> Result<(), String> {
    let status = Command::new("cp")
        .arg("-a")
        .arg(src)
        .arg(dest_parent)
        .status()
        .await
        .map_err(|e| format!("failed to spawn cp: {}", e))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("cp exited with {:?}", status.code()))
    }
}

/// JASPER is delivered as a double-wrapped archive (observed as `*.tar.gz.gtar`)
/// whose extraction produces a folder that itself contains a single inner
/// folder — the real JasperGold payload is inside that. If CADENCE/JASPER2209/
/// doesn't exist yet, find that raw archive and unwrap it in place so the copy
/// pass above can treat JASPER exactly like every other tool folder.
async fn prepare_jasper_archive(cadence_dir: &Path, tx: &mpsc::UnboundedSender<String>) {
    let jasper_dir = cadence_dir.join("JASPER2209");
    if jasper_dir.exists() {
        return;
    }

    let archive = match find_jasper_archive(cadence_dir) {
        Some(a) => a,
        None => return, // Nothing to unwrap; the copy pass will just report it missing.
    };

    send_log(tx, &format!("[INFO] Found raw JASPER archive {} - extracting...", archive.display()));

    let tmp_dir = cadence_dir.join(".jasper_extract_tmp");
    let _ = tokio::fs::remove_dir_all(&tmp_dir).await;
    if let Err(e) = tokio::fs::create_dir_all(&tmp_dir).await {
        send_log(tx, &format!("[ERROR] Could not create extraction dir: {}", e));
        return;
    }

    let extracted = Command::new("tar")
        .arg("-xf")
        .arg(&archive)
        .arg("-C")
        .arg(&tmp_dir)
        .status()
        .await;

    match extracted {
        Ok(s) if s.success() => {}
        Ok(s) => {
            send_log(tx, &format!("[ERROR] tar extraction failed (code {:?}). Extract {} into CADENCE/JASPER2209/ manually.", s.code(), archive.display()));
            return;
        }
        Err(e) => {
            send_log(tx, &format!("[ERROR] Failed to run tar: {}. Extract {} into CADENCE/JASPER2209/ manually.", e, archive.display()));
            return;
        }
    }

    // Unwrap however many levels of "single subfolder" wrapping the vendor
    // archive added, then move the real contents into JASPER2209/.
    let payload_dir = unwrap_single_child_dirs(&tmp_dir).await.unwrap_or_else(|| tmp_dir.clone());

    if let Err(e) = tokio::fs::create_dir_all(&jasper_dir).await {
        send_log(tx, &format!("[ERROR] Could not create {}: {}", jasper_dir.display(), e));
        return;
    }

    let mut moved = 0;
    if let Ok(mut entries) = tokio::fs::read_dir(&payload_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let dest = jasper_dir.join(entry.file_name());
            if tokio::fs::rename(entry.path(), &dest).await.is_ok() {
                moved += 1;
            }
        }
    }

    let _ = tokio::fs::remove_dir_all(&tmp_dir).await;

    if moved > 0 {
        send_log(tx, &format!("[SUCCESS] Unpacked JASPER archive into {} ({} entries).", jasper_dir.display(), moved));
    } else {
        send_log(tx, &format!("[ERROR] Extracted {} but found nothing to move into JASPER2209/ - check the archive layout manually.", archive.display()));
    }
}

/// Finds the raw JASPER vendor archive under CADENCE/, matched by filename
/// (case-insensitive "jasper" plus a tar-like extension) rather than a fixed
/// name, since the exact vendor filename varies by delivery.
fn find_jasper_archive(cadence_dir: &Path) -> Option<PathBuf> {
    let entries = std::fs::read_dir(cadence_dir).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let name = path.file_name()?.to_string_lossy().to_lowercase();
        if name.contains("jasper") && (name.ends_with(".gtar") || name.ends_with(".tar.gz") || name.ends_with(".tgz") || name.ends_with(".tar")) {
            return Some(path);
        }
    }
    None
}

/// Descends into a directory as long as it contains exactly one entry and that
/// entry is itself a directory - unwraps redundant single-child wrapper folders
/// left behind by an archive extraction.
async fn unwrap_single_child_dirs(start: &Path) -> Option<PathBuf> {
    let mut current = start.to_path_buf();
    loop {
        let mut children = Vec::new();
        let mut entries = tokio::fs::read_dir(&current).await.ok()?;
        while let Ok(Some(entry)) = entries.next_entry().await {
            children.push(entry.path());
        }
        if children.len() == 1 && children[0].is_dir() {
            current = children.into_iter().next().unwrap();
        } else {
            break;
        }
    }
    Some(current)
}

pub async fn install_silvaco(
    config: &mut LabConfig,
    part: u8,
    tx: mpsc::UnboundedSender<String>,
) -> Result<(), String> {
    let phase_key = format!("SILVACO_{}", part);
    let silvaco_dir = config.get_tool_dir("SILVACO");
    send_log(&tx, &format!("[INFO] Installing Silvaco Part {} from {}...", part, silvaco_dir.display()));
    
    config.mark_phase_done(&phase_key).map_err(|e| e.to_string())?;
    let _ = recreate_env("silvaco", tx.clone()).await;
    send_log(&tx, &format!("[SUCCESS] Silvaco Part {} complete.", part));
    Ok(())
}

pub async fn install_cadre(
    config: &mut LabConfig,
    tx: mpsc::UnboundedSender<String>,
) -> Result<(), String> {
    let cadre_dir = config.get_tool_dir("CADRE");
    send_log(&tx, &format!("[INFO] Installing CADRE VisualTCAD from {}...", cadre_dir.display()));
    
    config.mark_phase_done("CADRE").map_err(|e| e.to_string())?;
    let _ = recreate_env("cadre", tx.clone()).await;
    send_log(&tx, "[SUCCESS] CADRE VisualTCAD installation complete.");
    Ok(())
}

fn send_log(tx: &mpsc::UnboundedSender<String>, msg: &str) {
    tx.send(msg.to_string()).ok();
}
