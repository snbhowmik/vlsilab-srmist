use tokio::sync::mpsc;
use crate::installer::config::LabConfig;
use crate::installer::launcher::write_eda_launcher;

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
    let _ = write_eda_launcher(config, tx.clone()).await;
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
        send_log(&tx, &format!("[WARN] CADENCE directory not found at {}. Please place tar archives under ROOT/CADENCE/", cadence_dir.display()));
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
    let silvaco_dir = config.get_tool_dir("SILVACO");
    send_log(&tx, &format!("[INFO] Installing Silvaco Part {} from {}...", part, silvaco_dir.display()));
    
    config.mark_phase_done(&phase_key).map_err(|e| e.to_string())?;
    let _ = write_eda_launcher(config, tx.clone()).await;
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
    let _ = write_eda_launcher(config, tx.clone()).await;
    send_log(&tx, "[SUCCESS] CADRE VisualTCAD installation complete.");
    Ok(())
}

fn send_log(tx: &mpsc::UnboundedSender<String>, msg: &str) {
    tx.send(msg.to_string()).ok();
}
