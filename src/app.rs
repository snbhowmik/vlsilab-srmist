use tokio::sync::mpsc;
use crate::installer::config::LabConfig;
use crate::user_mgr::{check_user_exists, is_bashrc_configured, create_or_configure_student_user, LabUser};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActiveTab {
    Dashboard = 0,
    PreInstall = 1,
    Tools = 2,
    UserMgmt = 3,
    LogStream = 4,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputMode {
    Normal,
    MachineConfigPrompt,
    AddUserPrompt,
    DependencyPrompt,
}

pub struct App {
    pub config: LabConfig,
    pub active_tab: ActiveTab,
    pub input_mode: InputMode,
    pub input_buffer: String,
    pub logs: Vec<String>,
    pub users_list: Vec<LabUser>,
    pub is_busy: bool,
    pub log_rx: mpsc::UnboundedReceiver<String>,
    pub log_tx: mpsc::UnboundedSender<String>,
}

impl App {
    pub fn new(config: LabConfig) -> Self {
        let (log_tx, log_rx) = mpsc::unbounded_channel();

        let mut app = Self {
            config,
            active_tab: ActiveTab::Dashboard,
            input_mode: InputMode::Normal,
            input_buffer: String::new(),
            logs: Vec::new(),
            users_list: Vec::new(),
            is_busy: false,
            log_rx,
            log_tx,
        };

        app.refresh_users();
        app.logs.push("[INFO] VLSI Lab Ratatui Setup Tool initialized.".to_string());
        app
    }

    pub fn refresh_users(&mut self) {
        let student_user = self.config.student_user.clone();
        let sysadmin_user = self.config.sysadmin_user.clone();

        self.users_list = vec![
            LabUser {
                username: sysadmin_user.clone(),
                role: "Sysadmin".to_string(),
                identifier: "SYSADMIN".to_string(),
                exists: check_user_exists(&sysadmin_user),
                bashrc_configured: is_bashrc_configured(&sysadmin_user),
            },
            LabUser {
                username: student_user.clone(),
                role: "Student".to_string(),
                identifier: format!("STUDENT-{}", self.config.machine_number),
                exists: check_user_exists(&student_user),
                bashrc_configured: is_bashrc_configured(&student_user),
            },
        ];
    }

    pub fn add_log(&mut self, msg: String) {
        let _ = self.config.append_log(&msg);
        self.logs.push(msg);
    }

    pub fn poll_logs(&mut self) {
        while let Ok(msg) = self.log_rx.try_recv() {
            self.add_log(msg);
        }
    }

    pub async fn handle_add_user_submit(&mut self) {
        let input = self.input_buffer.trim().to_string();
        self.input_buffer.clear();
        self.input_mode = InputMode::Normal;

        if input.is_empty() {
            return;
        }

        let parts: Vec<&str> = input.split(',').map(|s| s.trim()).collect();
        let (username, role, identifier) = match parts.as_slice() {
            [u, r, id] => (u.to_string(), r.to_string(), id.to_string()),
            [u] => (u.to_string(), "Student".to_string(), "REG-DEFAULT".to_string()),
            _ => {
                self.add_log("[ERROR] Invalid user format. Use: USERNAME,ROLE,REGISTER_NO".to_string());
                return;
            }
        };

        let tx = self.log_tx.clone();
        self.is_busy = true;

        if let Err(e) = create_or_configure_student_user(&username, &role, &identifier, tx).await {
            self.add_log(format!("[ERROR] Failed to add user {}: {}", username, e));
        }

        self.is_busy = false;
        self.refresh_users();
    }

    pub async fn handle_dependency_submit(&mut self) {
        let input = self.input_buffer.trim().to_string();
        self.input_buffer.clear();
        self.input_mode = InputMode::Normal;

        if input.is_empty() {
            return;
        }

        self.active_tab = ActiveTab::LogStream;
        let tx = self.log_tx.clone();
        self.is_busy = true;

        tokio::spawn(async move {
            let _ = crate::installer::dependency::resolve_and_install_dependency(&input, tx).await;
        });

        self.is_busy = false;
    }
}
