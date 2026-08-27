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
    pub private_ip: Option<String>,
    pub gateway_ip: Option<String>,
    pub dns_c2s_up: Option<bool>,
    pub direct_ip_up: Option<bool>,
    pub port_checks: Vec<PortCheck>,
}

impl NetworkState {
    pub fn new() -> Self {
        Self {
            is_checking: true,
            whitelisted_ip: None,
            private_ip: None,
            gateway_ip: None,
            dns_c2s_up: None,
            direct_ip_up: None,
            port_checks: vec![
                PortCheck { tool_name: "Siemens EDA".to_string(), port: 1717, is_reachable: None },
                PortCheck { tool_name: "Xilinx".to_string(), port: 2100, is_reachable: None },
                PortCheck { tool_name: "Ansys".to_string(), port: 1055, is_reachable: None },
                PortCheck { tool_name: "Cadence".to_string(), port: 5280, is_reachable: None },
                PortCheck { tool_name: "Silvaco".to_string(), port: 27000, is_reachable: None },
                PortCheck { tool_name: "Keysight".to_string(), port: 27009, is_reachable: None },
                PortCheck { tool_name: "Synopsys".to_string(), port: 27020, is_reachable: None },
            ],
        }
    }
}

pub fn spawn_network_checks(state: Arc<Mutex<NetworkState>>) {
    tokio::spawn(async move {
        // 1. Check Private IP
        let mut priv_ip = None;
        if let Ok(out) = Command::new("sh").args(&["-c", "hostname -I | awk '{print $1}'"]).output() {
            let ip = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !ip.is_empty() {
                priv_ip = Some(ip);
            }
        }

        // 2. Check Gateway
        let mut gw_ip = None;
        if let Ok(out) = Command::new("sh").args(&["-c", "ip route show default | awk '/default/ {print $3}'"]).output() {
            let gw = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !gw.is_empty() {
                gw_ip = Some(gw);
            }
        }
        
        {
            let mut s = state.lock().unwrap();
            s.private_ip = priv_ip;
            s.gateway_ip = gw_ip;
        }

        // 3. Check ICMP / Ping for Servers
        let dns_ping = Command::new("ping").args(&["-c", "1", "-W", "2", "c2s.cdacb.in"]).output();
        let direct_ping = Command::new("ping").args(&["-c", "1", "-W", "2", "14.139.1.126"]).output();

        let dns_up = dns_ping.map(|o| o.status.success()).unwrap_or(false);
        let direct_up = direct_ping.map(|o| o.status.success()).unwrap_or(false);

        {
            let mut s = state.lock().unwrap();
            s.dns_c2s_up = Some(dns_up);
            s.direct_ip_up = Some(direct_up);
        }

        // 4. Check Whitelisting IP (HTTP)
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

        // 5. Check Ports
        let count = state.lock().unwrap().port_checks.len();
        for i in 0..count {
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
