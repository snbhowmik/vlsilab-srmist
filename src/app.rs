use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;
use ratatui::widgets::ListState;
use crate::installer::config::LabConfig;
use crate::user_mgr::{check_user_exists, is_bashrc_configured, create_or_configure_student_user, LabUser};
use crate::network::{NetworkState, spawn_network_checks};
use crate::sys_validation::{ValidationState, spawn_system_validation};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    MainMenu,
    SubMenu,
    LogStream,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EdaTool {
    Xilinx,
    Cadence,
    Silvaco,
    Cadre,
}

impl EdaTool {
    pub fn as_str(&self) -> &'static str {
        match self {
            EdaTool::Xilinx => "Xilinx",
            EdaTool::Cadence => "Cadence",
            EdaTool::Silvaco => "Silvaco",
            EdaTool::Cadre => "CADRE",
        }
    }
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
    pub focus: Focus,
    pub main_menu_state: ListState,
    pub sub_menu_state: ListState,
    pub input_mode: InputMode,
    pub input_buffer: String,
    pub logs: Vec<String>,
    pub users_list: Vec<LabUser>,
    busy: Arc<AtomicBool>,
    was_busy: bool,
    pub network_state: Arc<Mutex<NetworkState>>,
    pub validation_state: Arc<Mutex<ValidationState>>,
    pub log_rx: mpsc::UnboundedReceiver<String>,
    pub log_tx: mpsc::UnboundedSender<String>,
    pub tick_count: u64,
}

impl App {
    pub fn new(config: LabConfig) -> Self {
        let (log_tx, log_rx) = mpsc::unbounded_channel();

        let mut main_menu_state = ListState::default();
        main_menu_state.select(Some(0));

        let mut sub_menu_state = ListState::default();
        sub_menu_state.select(Some(0));

        let mut app = Self {
            config,
            focus: Focus::MainMenu,
            main_menu_state,
            sub_menu_state,
            input_mode: InputMode::Normal,
            input_buffer: String::new(),
            logs: Vec::new(),
            users_list: Vec::new(),
            busy: Arc::new(AtomicBool::new(false)),
            was_busy: false,
            network_state: Arc::new(Mutex::new(NetworkState::new())),
            validation_state: Arc::new(Mutex::new(ValidationState::new())),
            log_rx,
            log_tx,
            tick_count: 0,
        };

        spawn_network_checks(app.network_state.clone());
        spawn_system_validation(app.validation_state.clone());
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

    pub fn on_tick(&mut self) {
        self.tick_count = self.tick_count.wrapping_add(1);

        let busy_now = self.is_busy();
        if self.was_busy && !busy_now {
            // A background task just finished — pull its effects (new user,
            // freshly installed tool, etc.) into the UI's cached state.
            self.refresh_users();
        }
        self.was_busy = busy_now;
    }

    pub fn is_busy(&self) -> bool {
        self.busy.load(Ordering::SeqCst)
    }

    pub fn current_main_menu_max_idx(&self) -> usize {
        6 // Dashboard, PreReqs, Apps, EDA Tools, Network, Users, Logs
    }

    pub fn current_sub_menu_max_idx(&self) -> usize {
        if let Some(main_idx) = self.main_menu_state.selected() {
            match main_idx {
                0 => 0, // Dashboard -> Refresh
                1 => 0, // PreReqs -> Execute PreInstall
                2 => 0, // Apps -> Empty
                3 => 7, // EDA Tools -> 4 tools * 2 actions = 8 items (max idx 7)
                4 => 0, // Network -> Refresh
                5 => 0, // Users -> Add User
                6 => 0, // Logs -> View
                _ => 0,
            }
        } else {
            0
        }
    }

    pub fn handle_add_user_submit(&mut self) {
        let input = self.input_buffer.trim().to_string();
        self.input_buffer.clear();
        self.input_mode = InputMode::Normal;

        if input.is_empty() { return; }

        let parts: Vec<&str> = input.split(',').map(|s| s.trim()).collect();
        let (username, role, identifier) = match parts.as_slice() {
            [u, r, id] => (u.to_string(), r.to_string(), id.to_string()),
            [u] => (u.to_string(), "Student".to_string(), "REG-DEFAULT".to_string()),
            _ => {
                self.add_log("[ERROR] Invalid user format. Use: USERNAME,ROLE,REGISTER_NO".to_string());
                return;
            }
        };

        self.focus = Focus::LogStream;
        let tx = self.log_tx.clone();
        let busy = self.busy.clone();
        busy.store(true, Ordering::SeqCst);

        tokio::spawn(async move {
            if let Err(e) = create_or_configure_student_user(&username, &role, &identifier, tx.clone()).await {
                tx.send(format!("[ERROR] Failed to add user {}: {}", username, e)).ok();
            }
            busy.store(false, Ordering::SeqCst);
        });
    }

    pub fn handle_dependency_submit(&mut self) {
        let input = self.input_buffer.trim().to_string();
        self.input_buffer.clear();
        self.input_mode = InputMode::Normal;

        if input.is_empty() { return; }

        self.focus = Focus::LogStream;
        let tx = self.log_tx.clone();
        let busy = self.busy.clone();
        busy.store(true, Ordering::SeqCst);

        tokio::spawn(async move {
            let _ = crate::installer::dependency::resolve_and_install_dependency(&input, tx).await;
            busy.store(false, Ordering::SeqCst);
        });
    }

    pub fn handle_sub_menu_execute(&mut self) {
        let main_idx = self.main_menu_state.selected().unwrap_or(0);
        let sub_idx = self.sub_menu_state.selected().unwrap_or(0);
        
        match main_idx {
            0 => {
                // Refresh Dashboard
                spawn_system_validation(self.validation_state.clone());
            },
            1 => {
                if sub_idx == 0 {
                    self.focus = Focus::LogStream;
                    let tx = self.log_tx.clone();
                    let mut cfg = self.config.clone();
                    let busy = self.busy.clone();
                    busy.store(true, Ordering::SeqCst);
                    tokio::spawn(async move {
                        let _ = crate::installer::preinstall::run_preinstall(&mut cfg, tx).await;
                        busy.store(false, Ordering::SeqCst);
                    });
                }
            },
            3 => {
                // EDA Tools
                let tool = match sub_idx / 2 {
                    0 => EdaTool::Xilinx,
                    1 => EdaTool::Cadence,
                    2 => EdaTool::Silvaco,
                    _ => EdaTool::Cadre,
                };
                let action_is_install = (sub_idx % 2) == 0;

                self.focus = Focus::LogStream;
                let tx = self.log_tx.clone();
                let mut cfg = self.config.clone();
                let busy = self.busy.clone();
                busy.store(true, Ordering::SeqCst);

                if action_is_install {
                    tokio::spawn(async move {
                        match tool {
                            EdaTool::Xilinx => { let _ = crate::installer::tools::install_xilinx(&mut cfg, tx).await; }
                            EdaTool::Cadence => { let _ = crate::installer::tools::install_cadence(&mut cfg, tx).await; }
                            EdaTool::Silvaco => {
                                let _ = crate::installer::tools::install_silvaco(&mut cfg, 1, tx.clone()).await;
                                let _ = crate::installer::tools::install_silvaco(&mut cfg, 2, tx.clone()).await;
                                let _ = crate::installer::tools::install_silvaco(&mut cfg, 3, tx.clone()).await;
                            }
                            EdaTool::Cadre => { let _ = crate::installer::tools::install_cadre(&mut cfg, tx).await; }
                        }
                        busy.store(false, Ordering::SeqCst);
                    });
                } else {
                    tokio::spawn(async move {
                        let _ = crate::installer::launcher::recreate_env(&tool.as_str().to_string(), tx).await;
                        busy.store(false, Ordering::SeqCst);
                    });
                }
            },
            4 => {
                // Network Refresh
                spawn_network_checks(self.network_state.clone());
            },
            5 => {
                if sub_idx == 0 {
                    self.input_mode = InputMode::AddUserPrompt;
                    self.input_buffer.clear();
                }
            },
            6 => {
                // LogStream View
                self.focus = Focus::LogStream;
            }
            _ => {}
        }
    }
}
