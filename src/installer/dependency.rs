use std::collections::HashSet;
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;

pub async fn resolve_and_install_dependency(
    query: &str,
    tx: mpsc::UnboundedSender<String>,
) -> Result<(), String> {
    let raw_query = query.trim();
    if raw_query.is_empty() {
        send_log(&tx, "[ERROR] Dependency search query cannot be empty.");
        return Err("Empty search query".to_string());
    }

    send_log(
        &tx,
        &format!("[INFO] Resolving package dependency for query: '{}'...", raw_query),
    );

    // Build dnf provides search patterns
    let patterns = if raw_query.contains('/') {
        vec![raw_query.to_string()]
    } else if raw_query.contains(".so") {
        vec![format!("*/{}", raw_query), format!("*{}*", raw_query)]
    } else {
        vec![
            format!("*/{}", raw_query),
            format!("*{}*", raw_query),
            raw_query.to_string(),
        ]
    };

    let mut found_packages: HashSet<String> = HashSet::new();
    let ignored_fields: HashSet<&str> = [
        "Repo", "Filename", "Matched from", "Provide", "Description", "Summary",
        "URL", "License", "Source", "Size", "Buildtime", "Vendor", "Arch",
        "Epoch", "Name", "Version", "Release", "Loaded plugins", "Last metadata expiration check",
    ]
    .iter()
    .cloned()
    .collect();

    for pattern in &patterns {
        send_log(&tx, &format!("$ dnf provides \"{}\"", pattern));

        let mut child = match Command::new("dnf")
            .args(["provides", pattern])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => {
                send_log(&tx, &format!("[WARN] Failed to run dnf provides: {}", e));
                continue;
            }
        };

        if let Some(stdout) = child.stdout.take() {
            let mut reader = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                // Parse package header lines from dnf provides output:
                // e.g., "qt5-qtsvg-5.15.2-4.el8.x86_64 : Qt5 - Support for SVG format"
                // e.g., "libpng12-1.2.57-10.el8.x86_64 : Old version of Libpng"
                if line.contains(" : ") && !line.starts_with(' ') && !line.starts_with('\t') {
                    if let Some(pkg_spec) = line.split(" : ").next() {
                        let pkg_spec = pkg_spec.trim();
                        // Ignore DNF metadata field lines like "Repo : ...", "Filename : ..."
                        if !pkg_spec.is_empty()
                            && !pkg_spec.contains(' ')
                            && !pkg_spec.contains('/')
                            && !ignored_fields.contains(pkg_spec)
                        {
                            let base_name = extract_base_package_name(pkg_spec);
                            if !base_name.is_empty() && !ignored_fields.contains(base_name.as_str()) {
                                found_packages.insert(base_name);
                            }
                        }
                    }
                }
            }
        }

        let _ = child.wait().await;
        if !found_packages.is_empty() {
            break;
        }
    }

    let target_packages: Vec<String> = if !found_packages.is_empty() {
        found_packages.into_iter().collect()
    } else {
        send_log(
            &tx,
            &format!(
                "[WARN] No specific package resolved via 'dnf provides' for '{}'. Fallback to direct package name.",
                raw_query
            ),
        );
        vec![raw_query.to_string()]
    };

    send_log(
        &tx,
        &format!(
            "[INFO] Identified candidate package(s) for installation: {}",
            target_packages.join(", ")
        ),
    );

    // Perform dnf install
    let mut install_args = vec!["install", "-y"];
    for pkg in &target_packages {
        install_args.push(pkg.as_str());
    }

    run_cmd("dnf", &install_args, &tx).await?;

    send_log(
        &tx,
        &format!(
            "[SUCCESS] Dependency '{}' resolved & installed successfully ({})!",
            raw_query,
            target_packages.join(", ")
        ),
    );

    Ok(())
}

/// Extract base package name from full RPM spec string like "qt5-qtsvg-5.15.2-4.el8.x86_64" -> "qt5-qtsvg"
fn extract_base_package_name(pkg_spec: &str) -> String {
    let spec = pkg_spec.trim();
    if spec.is_empty() {
        return String::new();
    }

    // Split off architecture if present (e.g. .x86_64, .i686, .noarch)
    let without_arch = match spec.rfind('.') {
        Some(idx) => &spec[..idx],
        None => spec,
    };

    // RPM package format is NAME-VERSION-RELEASE.
    // Splitting by '-' from the right: last part is RELEASE, second to last is VERSION.
    let parts: Vec<&str> = without_arch.split('-').collect();
    if parts.len() >= 3 {
        // Rejoin all parts except last 2 (version and release)
        parts[..parts.len() - 2].join("-")
    } else {
        spec.to_string()
    }
}

fn send_log(tx: &mpsc::UnboundedSender<String>, msg: &str) {
    tx.send(msg.to_string()).ok();
}

async fn run_cmd(
    cmd: &str,
    args: &[&str],
    tx: &mpsc::UnboundedSender<String>,
) -> Result<(), String> {
    send_log(tx, &format!("$ {} {}", cmd, args.join(" ")));

    let mut child = Command::new(cmd)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to spawn {}: {}", cmd, e))?;

    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();

    let tx_out = tx.clone();
    let mut reader_out = BufReader::new(stdout).lines();
    tokio::spawn(async move {
        while let Ok(Some(line)) = reader_out.next_line().await {
            tx_out.send(line).ok();
        }
    });

    let tx_err = tx.clone();
    let mut reader_err = BufReader::new(stderr).lines();
    tokio::spawn(async move {
        while let Ok(Some(line)) = reader_err.next_line().await {
            tx_err.send(format!("[STDERR] {}", line)).ok();
        }
    });

    let status = child.wait().await.map_err(|e| e.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("Command '{}' failed with code {:?}", cmd, status.code()))
    }
}
