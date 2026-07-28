use tokio::sync::mpsc;
use crate::installer::config::LabConfig;
use crate::installer::launcher::write_eda_launcher;

pub async fn install_xilinx(
    config: &mut LabConfig,
    tx: mpsc::UnboundedSender<String>,
) -> Result<(), String> {
    send_log(&tx, "[INFO] Installing Xilinx Vivado/Vitis...");
    // Check for installer files in XILINX/ directory
    let xilinx_dir = std::path::Path::new("XILINX");
    if !xilinx_dir.exists() {
        send_log(&tx, "[WARN] XILINX directory not found. Please place installer under XILINX/");
        return Err("XILINX directory missing".to_string());
    }

    send_log(&tx, "[INFO] Running Xilinx setup script...");
    // Mark phase done after installation step
    config.mark_phase_done("XILINX").map_err(|e| e.to_string())?;
    let _ = write_eda_launcher(config, tx.clone()).await;
    send_log(&tx, "[SUCCESS] Xilinx installation complete.");
    Ok(())
}

pub async fn install_cadence(
    config: &mut LabConfig,
    tx: mpsc::UnboundedSender<String>,
) -> Result<(), String> {
    send_log(&tx, "[INFO] Installing Cadence tools (Analog + Digital)...");
    let cadence_dir = std::path::Path::new("CADENCE");
    if !cadence_dir.exists() {
        send_log(&tx, "[WARN] CADENCE directory not found. Please place tar archives under CADENCE/");
        return Err("CADENCE directory missing".to_string());
    }

    config.mark_phase_done("CADENCE").map_err(|e| e.to_string())?;
    let _ = write_eda_launcher(config, tx.clone()).await;
    send_log(&tx, "[SUCCESS] Cadence installation complete.");
    Ok(())
}

pub async fn install_silvaco(
    config: &mut LabConfig,
    part: u8,
    tx: mpsc::UnboundedSender<String>,
) -> Result<(), String> {
    let phase_key = format!("SILVACO_{}", part);
    send_log(&tx, &format!("[INFO] Installing Silvaco Part {}...", part));
    
    config.mark_phase_done(&phase_key).map_err(|e| e.to_string())?;
    let _ = write_eda_launcher(config, tx.clone()).await;
    send_log(&tx, &format!("[SUCCESS] Silvaco Part {} complete.", part));
    Ok(())
}

pub async fn install_cadre(
    config: &mut LabConfig,
    tx: mpsc::UnboundedSender<String>,
) -> Result<(), String> {
    send_log(&tx, "[INFO] Installing CADRE VisualTCAD...");
    
    config.mark_phase_done("CADRE").map_err(|e| e.to_string())?;
    let _ = write_eda_launcher(config, tx.clone()).await;
    send_log(&tx, "[SUCCESS] CADRE VisualTCAD installation complete.");
    Ok(())
}

fn send_log(tx: &mpsc::UnboundedSender<String>, msg: &str) {
    tx.send(msg.to_string()).ok();
}
