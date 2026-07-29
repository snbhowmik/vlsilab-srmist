use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{
        Block, Borders, Clear, List, ListItem, Paragraph, Row, Table, Tabs
    },
    Frame,
};
use crate::app::{App, ActiveTab, InputMode};

pub fn draw(f: &mut Frame, app: &mut App) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .margin(1)
        .constraints([
            Constraint::Length(4), // Header
            Constraint::Length(3), // Navigation Tabs
            Constraint::Min(10),   // Main Content Area
            Constraint::Length(3), // Footer / Status bar
        ].as_ref())
        .split(f.size());

    draw_header(f, app, chunks[0]);
    draw_tabs(f, app, chunks[1]);

    match app.active_tab {
        ActiveTab::Dashboard => draw_dashboard(f, app, chunks[2]),
        ActiveTab::PreInstall => draw_preinstall_tab(f, app, chunks[2]),
        ActiveTab::Tools => draw_tools_tab(f, app, chunks[2]),
        ActiveTab::UserMgmt => draw_user_mgmt_tab(f, app, chunks[2]),
        ActiveTab::LogStream => draw_log_stream_tab(f, app, chunks[2]),
    }

    draw_footer(f, app, chunks[3]);

    if app.input_mode == InputMode::MachineConfigPrompt {
        draw_machine_config_modal(f, app);
    } else if app.input_mode == InputMode::AddUserPrompt {
        draw_add_user_modal(f, app);
    } else if app.input_mode == InputMode::DependencyPrompt {
        draw_dependency_modal(f, app);
    }
}

fn draw_header(f: &mut Frame, app: &App, area: Rect) {
    let header_text = vec![
        Line::from(vec![
            Span::styled("  C2S CHIPIN EDA Installer (v1.10.0) ", Style::default().fg(Color::Green).add_modifier(Modifier::BOLD)),
            Span::styled(" [Author: snbhowmik]", Style::default().fg(Color::Yellow)),
        ]),
        Line::from(vec![
            Span::styled("  Info/Feedback: ", Style::default().fg(Color::Cyan)),
            Span::raw("https://snbhowmik.dev  "),
            Span::styled("Manual: ", Style::default().fg(Color::Cyan)),
            Span::raw("github.com/snbhowmik/c2s-setup/README.md"),
        ]),
        Line::from(vec![
            Span::styled("  Machine: ", Style::default().fg(Color::Cyan)),
            Span::raw(format!("{} (Machine #{})  ", app.config.hostname_fqdn, app.config.machine_number)),
            Span::styled("Admin: ", Style::default().fg(Color::Cyan)),
            Span::raw(format!("{}  ", app.config.sysadmin_user)),
            Span::styled("Student: ", Style::default().fg(Color::Cyan)),
            Span::raw(&app.config.student_user),
        ]),
    ];

    let header = Paragraph::new(header_text)
        .block(Block::default().borders(Borders::ALL).title(" Setup System "));
    f.render_widget(header, area);
}

fn draw_tabs(f: &mut Frame, app: &App, area: Rect) {
    let titles = vec![
        " [1] Dashboard ",
        " [2] Pre-Install ",
        " [3] EDA Tools ",
        " [4] User Mgmt ",
        " [5] Installation Logs ",
    ];

    let tabs = Tabs::new(titles)
        .block(Block::default().borders(Borders::ALL).title(" Navigation "))
        .select(app.active_tab as usize)
        .style(Style::default().fg(Color::White))
        .highlight_style(Style::default().fg(Color::Green).add_modifier(Modifier::BOLD));

    f.render_widget(tabs, area);
}

fn draw_dashboard(f: &mut Frame, app: &App, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(55), Constraint::Percentage(45)])
        .split(area);

    let t_pre = app.config.phase_time("PRE_INSTALL").unwrap_or_default();
    let t_xil = app.config.phase_time("XILINX").unwrap_or_default();
    let t_cad = app.config.phase_time("CADENCE").unwrap_or_default();
    let t_sil1 = app.config.phase_time("SILVACO_1").unwrap_or_default();
    let t_sil2 = app.config.phase_time("SILVACO_2").unwrap_or_default();
    let t_sil3 = app.config.phase_time("SILVACO_3").unwrap_or_default();
    let t_cadre = app.config.phase_time("CADRE").unwrap_or_default();

    let rows = vec![
        Row::new(vec![
            if app.config.is_phase_done("PRE_INSTALL") { "✔" } else { "✘" },
            "0. System Pre-Install & Student Setup",
            &t_pre,
        ]).style(if app.config.is_phase_done("PRE_INSTALL") { Style::default().fg(Color::Green) } else { Style::default().fg(Color::Red) }),
        
        Row::new(vec![
            if app.config.is_phase_done("XILINX") { "✔" } else { "✘" },
            "1. Xilinx Vivado/Vitis 2025.2",
            &t_xil,
        ]).style(if app.config.is_phase_done("XILINX") { Style::default().fg(Color::Green) } else { Style::default().fg(Color::Red) }),

        Row::new(vec![
            if app.config.is_phase_done("CADENCE") { "✔" } else { "✘" },
            "2. Cadence Tools (Analog + Digital)",
            &t_cad,
        ]).style(if app.config.is_phase_done("CADENCE") { Style::default().fg(Color::Green) } else { Style::default().fg(Color::Red) }),

        Row::new(vec![
            if app.config.is_phase_done("SILVACO_3") { "✔" } else { "✘" },
            "3. Silvaco TCAD Suite",
            &t_sil3,
        ]).style(if app.config.is_phase_done("SILVACO_3") { Style::default().fg(Color::Green) } else { Style::default().fg(Color::Red) }),

        Row::new(vec![
            if app.config.is_phase_done("CADRE") { "✔" } else { "✘" },
            "4. CADRE VisualTCAD",
            &t_cadre,
        ]).style(if app.config.is_phase_done("CADRE") { Style::default().fg(Color::Green) } else { Style::default().fg(Color::Red) }),
    ];

    let table = Table::new(
        rows,
        [Constraint::Length(3), Constraint::Percentage(60), Constraint::Percentage(35)]
    )
    .header(Row::new(vec!["Status", "Installation Phase", "Completed Time"]).style(Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)))
    .block(Block::default().borders(Borders::ALL).title(" Installation Status Overview "));

    f.render_widget(table, chunks[0]);

    // Quick Actions Panel
    let action_lines = vec![
        Line::from(Span::styled("Quick Actions / Hotkeys:", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD))),
        Line::from("  [0] Run System Pre-Install (Dependencies + Student User)"),
        Line::from("  [x] Install Xilinx Vivado/Vitis"),
        Line::from("  [c] Install Cadence Tools"),
        Line::from("  [s] Install Silvaco TCAD Suite"),
        Line::from("  [v] Install CADRE VisualTCAD"),
        Line::from("  [u] Open User Management (Add Student & Setup .bashrc)"),
        Line::from("  [p] Solve Missing Dependency / Library (e.g. libpng12.so.0, libQt5Svg)"),
        Line::from("  [m] Change Machine Number Config"),
        Line::from("  [l] View Live Logs"),
        Line::from("  [q] Quit TUI"),
    ];

    let actions = Paragraph::new(action_lines)
        .block(Block::default().borders(Borders::ALL).title(" Actions & Controls "));
    f.render_widget(actions, chunks[1]);
}

fn draw_preinstall_tab(f: &mut Frame, _app: &App, area: Rect) {
    let preinstall_text = vec![
        Line::from(Span::styled("Phase 0: Pre-Installation & System Dependencies", Style::default().fg(Color::Green).add_modifier(Modifier::BOLD))),
        Line::from(""),
        Line::from("What this phase does:"),
        Line::from("  1. Sets system hostname (e.g. vlsilab1.ist.srmtrichy.edu.in)."),
        Line::from("  2. Installs EPEL repository and required build packages:"),
        Line::from("     - libXp, motif, ncurses-compat-libs, xorg-x11-fonts, tcsh, csh, gcc, etc."),
        Line::from("  3. Provisions student user account (srmist309X)."),
        Line::from("  4. Forces GDM X11 session mode (WaylandEnable=false)."),
        Line::from("  5. Updates /etc/security/limits.conf for EDA memory/file descriptor bounds."),
        Line::from(""),
        Line::from(Span::styled("Press [0] to run Pre-Install phase.", Style::default().fg(Color::Yellow))),
    ];

    let paragraph = Paragraph::new(preinstall_text)
        .block(Block::default().borders(Borders::ALL).title(" Pre-Install Details "));
    f.render_widget(paragraph, area);
}

fn draw_tools_tab(f: &mut Frame, _app: &App, area: Rect) {
    let text = vec![
        Line::from(Span::styled("EDA Tools Installation Suite", Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD))),
        Line::from(""),
        Line::from("Available EDA Installers:"),
        Line::from("  [x] Xilinx Vivado/Vitis 2025.2 (Requires XILINX/ source folder)"),
        Line::from("  [c] Cadence IC618 / SPECTRE191 (Requires CADENCE/ tar archives)"),
        Line::from("  [s] Silvaco TCAD Suite (Requires SILVACO/ bin installers)"),
        Line::from("  [v] CADRE VisualTCAD (Requires CADRE/ installer bin)"),
        Line::from(""),
        Line::from(Span::styled("Note: Pre-install must be completed before tool installations.", Style::default().fg(Color::Yellow))),
    ];

    let paragraph = Paragraph::new(text)
        .block(Block::default().borders(Borders::ALL).title(" Tool Installers "));
    f.render_widget(paragraph, area);
}

fn draw_user_mgmt_tab(f: &mut Frame, app: &App, area: Rect) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(5), Constraint::Min(5)])
        .split(area);

    let info_text = vec![
        Line::from(Span::styled("Student User Provisioning & .bashrc Manager", Style::default().fg(Color::Green).add_modifier(Modifier::BOLD))),
        Line::from("Create student accounts, set home directories, and automatically inject the /opt/vlsilab/eda-launcher.sh hook into ~/.bashrc."),
        Line::from(Span::styled("Press [a] to Add/Provision a Student User.", Style::default().fg(Color::Yellow))),
    ];

    let info_box = Paragraph::new(info_text)
        .block(Block::default().borders(Borders::ALL).title(" Overview "));
    f.render_widget(info_box, chunks[0]);

    let user_items: Vec<ListItem> = app.users_list.iter().map(|u| {
        let status = if u.exists {
            if u.bashrc_configured { "[CONFIGURED]" } else { "[USER EXISTS - NEED BASHRC]" }
        } else {
            "[NOT CREATED]"
        };
        ListItem::new(format!("  • User: {:<15} Role: {:<10} Reg/FET: {:<18} Status: {}", u.username, u.role, u.identifier, status))
    }).collect();

    let list = List::new(user_items)
        .block(Block::default().borders(Borders::ALL).title(" Registered Lab Users "));
    f.render_widget(list, chunks[1]);
}

fn draw_log_stream_tab(f: &mut Frame, app: &App, area: Rect) {
    let log_items: Vec<ListItem> = app.logs.iter().rev().take(100).rev().map(|line| {
        ListItem::new(line.as_str())
    }).collect();

    let list = List::new(log_items)
        .block(Block::default().borders(Borders::ALL).title(" Live Execution Log Stream "));
    f.render_widget(list, area);
}

fn draw_footer(f: &mut Frame, app: &App, area: Rect) {
    let status_msg = if app.is_busy {
        " ⏳ Running task in background... Please wait. "
    } else {
        " Press [1-5] Tabs | [q] Quit | [0] Pre-install | [p] Solve Dependency | [u] User Mgmt | [m] Machine Config "
    };

    let footer = Paragraph::new(status_msg)
        .block(Block::default().borders(Borders::ALL))
        .style(Style::default().fg(Color::White).bg(Color::Blue));

    f.render_widget(footer, area);
}

fn draw_machine_config_modal(f: &mut Frame, app: &App) {
    let area = centered_rect(60, 20, f.size());
    f.render_widget(Clear, area);

    let modal_text = vec![
        Line::from(Span::styled("Machine Number Configuration", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD))),
        Line::from("Enter machine number between 1 and 20:"),
        Line::from(""),
        Line::from(Span::styled(format!(" Input > {}_", app.input_buffer), Style::default().fg(Color::Green).add_modifier(Modifier::BOLD))),
        Line::from(""),
        Line::from("Press [Enter] to confirm, [Esc] to cancel."),
    ];

    let modal = Paragraph::new(modal_text)
        .block(Block::default().borders(Borders::ALL).title(" Configuration Modal "));
    f.render_widget(modal, area);
}

fn draw_add_user_modal(f: &mut Frame, app: &App) {
    let area = centered_rect(65, 30, f.size());
    f.render_widget(Clear, area);

    let modal_text = vec![
        Line::from(Span::styled("Provision New Lab User Account", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD))),
        Line::from("Enter student details in format: USERNAME,ROLE,REGISTER_NO"),
        Line::from("Example: srmist3091,Student,RA2111003010001"),
        Line::from(""),
        Line::from(Span::styled(format!(" Input > {}_", app.input_buffer), Style::default().fg(Color::Green).add_modifier(Modifier::BOLD))),
        Line::from(""),
        Line::from("Press [Enter] to submit & provision user, [Esc] to cancel."),
    ];

    let modal = Paragraph::new(modal_text)
        .block(Block::default().borders(Borders::ALL).title(" Add User Modal "));
    f.render_widget(modal, area);
}

fn draw_dependency_modal(f: &mut Frame, app: &App) {
    let area = centered_rect(72, 35, f.size());
    f.render_widget(Clear, area);

    let modal_text = vec![
        Line::from(Span::styled("DNF Dependency & Missing Library Solver", Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD))),
        Line::from("Paste or enter a missing shared library, component, or file name."),
        Line::from("Examples:"),
        Line::from("  • libpng12.so.0  -> Resolves & installs 'libpng12'"),
        Line::from("  • libQt5Svg      -> Resolves & installs 'qt5-qtsvg'"),
        Line::from("  • libXp.so.6     -> Resolves & installs 'libXp'"),
        Line::from(""),
        Line::from(Span::styled(format!(" Library / File Query > {}_", app.input_buffer), Style::default().fg(Color::Green).add_modifier(Modifier::BOLD))),
        Line::from(""),
        Line::from("Press [Enter] to search & auto-install via DNF, [Esc] to cancel."),
    ];

    let modal = Paragraph::new(modal_text)
        .block(Block::default().borders(Borders::ALL).title(" Solve Missing Dependency "));
    f.render_widget(modal, area);
}

fn centered_rect(percent_x: u16, percent_y: u16, r: Rect) -> Rect {
    let popup_layout = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ].as_ref())
        .split(r);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ].as_ref())
        .split(popup_layout[1])[1]
}
