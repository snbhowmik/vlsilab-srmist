use std::io;
use std::time::Duration;
use crossterm::{
    event::{self, Event, KeyCode},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use ratatui::{backend::CrosstermBackend, Terminal};

mod app;
mod installer;
mod ui;
mod user_mgr;

use app::{ActiveTab, App, InputMode};
use installer::config::LabConfig;
use installer::preinstall::run_preinstall;
use installer::tools::{install_cadence, install_cadre, install_silvaco, install_xilinx};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Determine current running user
    let sudo_user = std::env::var("SUDO_USER").unwrap_or_else(|_| "sysadmin".to_string());
    
    // Load config or default to machine #1
    let config = LabConfig::load_from_state(&sudo_user)
        .unwrap_or_else(|| LabConfig::new(1, &sudo_user));

    // Setup terminal
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // Create App state
    let mut app = App::new(config);

    let res = run_app(&mut terminal, &mut app).await;

    // Restore terminal
    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;

    if let Err(err) = res {
        println!("Error running TUI application: {:?}", err);
    }

    Ok(())
}

async fn run_app<B: ratatui::backend::Backend>(
    terminal: &mut Terminal<B>,
    app: &mut App,
) -> io::Result<()> {
    loop {
        app.poll_logs();
        terminal.draw(|f| ui::layout::draw(f, app))?;

        if event::poll(Duration::from_millis(50))? {
            if let Event::Key(key) = event::read()? {
                match app.input_mode {
                    InputMode::Normal => match key.code {
                        KeyCode::Char('q') => return Ok(()),
                        KeyCode::Char('1') => app.active_tab = ActiveTab::Dashboard,
                        KeyCode::Char('2') => app.active_tab = ActiveTab::PreInstall,
                        KeyCode::Char('3') => app.active_tab = ActiveTab::Tools,
                        KeyCode::Char('4') => app.active_tab = ActiveTab::UserMgmt,
                        KeyCode::Char('5') | KeyCode::Char('l') => app.active_tab = ActiveTab::LogStream,
                        KeyCode::Char('0') => {
                            app.active_tab = ActiveTab::LogStream;
                            app.is_busy = true;
                            let tx = app.log_tx.clone();
                            let mut cfg = app.config.clone();
                            tokio::spawn(async move {
                                let _ = run_preinstall(&mut cfg, tx).await;
                            });
                            app.is_busy = false;
                        }
                        KeyCode::Char('x') => {
                            app.active_tab = ActiveTab::LogStream;
                            let tx = app.log_tx.clone();
                            let mut cfg = app.config.clone();
                            tokio::spawn(async move {
                                let _ = install_xilinx(&mut cfg, tx).await;
                            });
                        }
                        KeyCode::Char('c') => {
                            app.active_tab = ActiveTab::LogStream;
                            let tx = app.log_tx.clone();
                            let mut cfg = app.config.clone();
                            tokio::spawn(async move {
                                let _ = install_cadence(&mut cfg, tx).await;
                            });
                        }
                        KeyCode::Char('s') => {
                            app.active_tab = ActiveTab::LogStream;
                            let tx = app.log_tx.clone();
                            let mut cfg = app.config.clone();
                            tokio::spawn(async move {
                                let _ = install_silvaco(&mut cfg, 1, tx.clone()).await;
                                let _ = install_silvaco(&mut cfg, 2, tx.clone()).await;
                                let _ = install_silvaco(&mut cfg, 3, tx.clone()).await;
                            });
                        }
                        KeyCode::Char('v') => {
                            app.active_tab = ActiveTab::LogStream;
                            let tx = app.log_tx.clone();
                            let mut cfg = app.config.clone();
                            tokio::spawn(async move {
                                let _ = install_cadre(&mut cfg, tx).await;
                            });
                        }
                        KeyCode::Char('u') => app.active_tab = ActiveTab::UserMgmt,
                        KeyCode::Char('a') if app.active_tab == ActiveTab::UserMgmt => {
                            app.input_mode = InputMode::AddUserPrompt;
                            app.input_buffer.clear();
                        }
                        KeyCode::Char('m') => {
                            app.input_mode = InputMode::MachineConfigPrompt;
                            app.input_buffer.clear();
                        }
                        _ => {}
                    },
                    InputMode::MachineConfigPrompt => match key.code {
                        KeyCode::Enter => {
                            if let Ok(num) = app.input_buffer.trim().parse::<u8>() {
                                if num >= 1 && num <= 20 {
                                    let sudo_user = std::env::var("SUDO_USER").unwrap_or_else(|_| "sysadmin".to_string());
                                    app.config = LabConfig::new(num, &sudo_user);
                                    let _ = app.config.save_state_key("MACHINE_NUMBER", &num.to_string());
                                    app.add_log(format!("[CONFIG] Machine updated to #{} ({})", num, app.config.hostname_fqdn));
                                    app.refresh_users();
                                }
                            }
                            app.input_buffer.clear();
                            app.input_mode = InputMode::Normal;
                        }
                        KeyCode::Esc => {
                            app.input_buffer.clear();
                            app.input_mode = InputMode::Normal;
                        }
                        KeyCode::Char(c) => {
                            app.input_buffer.push(c);
                        }
                        KeyCode::Backspace => {
                            app.input_buffer.pop();
                        }
                        _ => {}
                    },
                    InputMode::AddUserPrompt => match key.code {
                        KeyCode::Enter => {
                            app.handle_add_user_submit().await;
                        }
                        KeyCode::Esc => {
                            app.input_buffer.clear();
                            app.input_mode = InputMode::Normal;
                        }
                        KeyCode::Char(c) => {
                            app.input_buffer.push(c);
                        }
                        KeyCode::Backspace => {
                            app.input_buffer.pop();
                        }
                        _ => {}
                    },
                }
            }
        }
    }
}
