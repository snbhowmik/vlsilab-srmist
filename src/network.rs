use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::net::TcpStream;
use std::process::Command;

#[derive(Debug, Clone)]
pub struct PortCheck {
    pub tool_name: String,
    pub port: u16,
    pub is_reachable: Option<bool>,
}

#[derive(Debug, Clone)]
pub struct NetworkState {
    pub is_checking: bool,
    pub whitelisted_ip: Option<String>,
    pub port_checks: Vec<PortCheck>,
}

impl NetworkState {
    pub fn new() -> Self {
        Self {
            is_checking: true,
            whitelisted_ip: None,
            port_checks: vec![
                PortCheck { tool_name: "Siemens EDA".to_string(), port: 1717, is_reachable: None },
                PortCheck { tool_name: "Xilinx".to_string(), port: 2100, is_reachable: None },
                PortCheck { tool_name: "Ansys".to_string(), port: 1055, is_reachable: None },
                PortCheck { tool_name: "Cadence".to_string(), port: 5280, is_reachable: None },
                PortCheck { tool_name: "Silvaco".to_string(), port: 27000, is_reachable: None },
                PortCheck { tool_name: "Cliosoft".to_string(), port: 27008, is_reachable: None },
                PortCheck { tool_name: "Keysight".to_string(), port: 27009, is_reachable: None },
                PortCheck { tool_name: "Synopsys".to_string(), port: 27020, is_reachable: None },
            ],
        }
    }
}

pub fn spawn_network_checks(state: Arc<Mutex<NetworkState>>) {
    tokio::spawn(async move {
        // 1. Check Whitelisting IP
        let mut output = Command::new("curl")
            .args(&["-s", "-m", "5", "http://c2s.cdacb.in/"])
            .output();
            
        if output.is_err() || !String::from_utf8_lossy(&output.as_ref().unwrap().stdout).contains("Congratulations") {
            output = Command::new("curl").args(&["-s", "-m", "5", "http://14.139.1.126/"]).output();
        }

        if let Ok(out) = output {
            let html = String::from_utf8_lossy(&out.stdout);
            let mut ip = None;
            if html.contains("Congratulations") {
                // Extract IP
                if let Some(ip_start) = html.find("Your IP:") {
                    let rest = &html[ip_start..];
                    let tokens: Vec<&str> = rest.split_whitespace().collect();
                    if tokens.len() > 2 {
                        ip = Some(tokens[2].to_string());
                    }
                }
            }
            
            {
                let mut s = state.lock().unwrap();
                s.whitelisted_ip = ip;
            }
        }

        // 2. Check Ports
        for i in 0..8 {
            let port = {
                let s = state.lock().unwrap();
                s.port_checks[i].port
            };

            let addr = format!("c2s.cdacb.in:{}", port);
            let is_reachable = match tokio::time::timeout(Duration::from_secs(3), TcpStream::connect(&addr)).await {
                Ok(Ok(_)) => true,
                _ => {
                    let addr_ip = format!("14.139.1.126:{}", port);
                    match tokio::time::timeout(Duration::from_secs(3), TcpStream::connect(&addr_ip)).await {
                        Ok(Ok(_)) => true,
                        _ => false
                    }
                }
            };

            {
                let mut s = state.lock().unwrap();
                s.port_checks[i].is_reachable = Some(is_reachable);
            }
        }

        {
            let mut s = state.lock().unwrap();
            s.is_checking = false;
        }
    });
}
