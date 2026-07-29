use std::fs;
use std::path::Path;
use std::process::Command;
use tokio::sync::mpsc;

#[derive(Debug, Clone)]
pub struct LabUser {
    pub username: String,
    pub role: String, // "Student", "Faculty", "Staff", "Guest"
    pub identifier: String, // Reg No or FET ID
    pub exists: bool,
    pub bashrc_configured: bool,
}

pub fn check_user_exists(username: &str) -> bool {
    Command::new("id")
        .arg(username)
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

pub fn is_bashrc_configured(username: &str) -> bool {
    let bashrc_path = format!("/home/{}/.bashrc", username);
    if !Path::new(&bashrc_path).exists() {
        return false;
    }
    fs::read_to_string(&bashrc_path)
        .map(|content| content.contains("/opt/vlsilab/eda-launcher.sh"))
        .unwrap_or(false)
}

pub async fn create_or_configure_student_user(
    username: &str,
    role: &str,
    identifier: &str,
    tx: mpsc::UnboundedSender<String>,
) -> Result<(), String> {
    send_log(&tx, &format!("[USER MGR] Provisioning user account '{}' ({}) - ID: {}", username, role, identifier));

    if !check_user_exists(username) {
        send_log(&tx, &format!("[USER MGR] User '{}' does not exist. Creating system account...", username));
        let output = Command::new("useradd")
            .args(&["-m", "-s", "/bin/bash", "-c", &format!("VLSI Lab {} [{}]", role, identifier), username])
            .output();

        match output {
            Ok(out) if out.status.success() => {
                send_log(&tx, &format!("[USER MGR] Successfully created Linux user '{}'.", username));
            }
            Ok(out) => {
                let err_msg = String::from_utf8_lossy(&out.stderr);
                send_log(&tx, &format!("[ERROR] useradd failed: {}", err_msg));
                return Err(format!("useradd failed: {}", err_msg));
            }
            Err(e) => return Err(format!("Failed to execute useradd: {}", e)),
        }
    } else {
        send_log(&tx, &format!("[USER MGR] User account '{}' already exists.", username));
    }

    // Configure .bashrc
    let bashrc_path = format!("/home/{}/.bashrc", username);
    if Path::new(&bashrc_path).exists() {
        if !is_bashrc_configured(username) {
            send_log(&tx, &format!("[USER MGR] Injecting EDA launcher into {}...", bashrc_path));
            let entry = "\n# Source VLSI Lab EDA Tool Launcher\nif [ -f /opt/vlsilab/eda-launcher.sh ]; then\n    source /opt/vlsilab/eda-launcher.sh\nfi\n";
            if let Ok(existing) = fs::read_to_string(&bashrc_path) {
                let updated = format!("{}{}", existing, entry);
                if let Err(e) = fs::write(&bashrc_path, updated) {
                    return Err(format!("Failed to update {}: {}", bashrc_path, e));
                }
                send_log(&tx, &format!("[SUCCESS] Configured .bashrc for '{}'.", username));
            }
        } else {
            send_log(&tx, &format!("[INFO] .bashrc for '{}' is already configured.", username));
        }
    } else {
        send_log(&tx, &format!("[WARN] Home directory or .bashrc missing for '{}'.", username));
    }

    Ok(())
}

fn send_log(tx: &mpsc::UnboundedSender<String>, msg: &str) {
    tx.send(msg.to_string()).ok();
}
