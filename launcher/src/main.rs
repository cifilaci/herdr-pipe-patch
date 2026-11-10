//! A launcher that packs the pipe-patch tool into one executable.
//!
//! The tool itself is a PowerShell script; this carries it, the patched core and
//! the upstream patch, unpacks them on the machine it runs on, and runs the
//! script there. Everything it unpacks stays on disk in plain sight, so the
//! script can be read before it is trusted.

use std::env;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

// The payloads this executable carries: one patched core per version, read
// out of `assets/payload` when the launcher is built.
include!(concat!(env!("OUT_DIR"), "/payloads.rs"));

const SCRIPT: &str = include_str!("../assets/herdr-pipe-patch.ps1");
const README: &str = include_str!("../assets/README.md");
const PATCH: &[u8] = include_bytes!("../assets/patches/herdr-core-pipe-extra-sids.patch");

const USAGE: &str = "\
herdr-pipe-patch - grant other accounts access to the herdr-core pipes

  herdr-pipe-patch.exe status      what is installed, and what the pipe grants
  herdr-pipe-patch.exe apply       install the patched core, set the variable, restart
  herdr-pipe-patch.exe unpatch     put the stock core back and remove the grants
  herdr-pipe-patch.exe verify      check the pipe and the codex side (-Probe to drive it)
  herdr-pipe-patch.exe build       build a patched core for a version (-Version 0.1.20)

Every option of the script itself works too, for example:
  herdr-pipe-patch.exe apply -Account CodexSandboxOffline -DryRun
  herdr-pipe-patch.exe status -HcPath C:\\path\\to\\herdr-core.exe

This executable carries the script, the patched core and the patch. On first run
they are unpacked under %LOCALAPPDATA%\\herdr-pipe-patch\\<marker> and the script
is run from there; the unpacked files stay readable.";

fn main() -> ExitCode {
    let args: Vec<OsString> = env::args_os().skip(1).collect();

    for arg in &args {
        let text = arg.to_string_lossy().to_lowercase();
        if text == "--help" || text == "-h" || text == "/?" {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        if text == "--version" {
            println!("herdr-pipe-patch {}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
    }

    let dir = match unpack() {
        Ok(dir) => dir,
        Err(e) => {
            eprintln!("herdr-pipe-patch: cannot unpack the tool: {e}");
            return ExitCode::FAILURE;
        }
    };
    let script = dir.join("herdr-pipe-patch.ps1");

    let powershell = powershell_path();
    let mut command = Command::new(&powershell);
    command
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-File")
        .arg(&script);
    for arg in &args {
        command.arg(arg);
    }

    match command.status() {
        Ok(status) => ExitCode::from(status.code().unwrap_or(1) as u8),
        Err(e) => {
            eprintln!("herdr-pipe-patch: cannot run {}: {e}", powershell.display());
            ExitCode::FAILURE
        }
    }
}

/// Where the tool is unpacked: a marker directory under LOCALAPPDATA, so a new
/// build of this executable unpacks afresh and an old one keeps working.
fn unpack() -> std::io::Result<PathBuf> {
    let root = local_app_data().join("herdr-pipe-patch").join(marker());
    let fresh = PAYLOAD_VERSIONS
        .first()
        .map(|version| root.join("payload").join(version).join("herdr-core.exe"));
    if fresh.map(|path| path.is_file()).unwrap_or(false) {
        remove_older_copies(&root);
        return Ok(root);
    }

    fs::create_dir_all(root.join("patches"))?;
    fs::write(root.join("herdr-pipe-patch.ps1"), SCRIPT)?;
    fs::write(root.join("README.md"), README)?;
    fs::write(root.join("patches").join("herdr-core-pipe-extra-sids.patch"), PATCH)?;
    for version in PAYLOAD_VERSIONS {
        let dir = root.join("payload").join(version);
        fs::create_dir_all(&dir)?;
        let (core, checksum, build) = payload_files(version);
        fs::write(dir.join("herdr-core.exe"), core)?;
        fs::write(dir.join("herdr-core.exe.sha256"), checksum)?;
        fs::write(dir.join("BUILD.txt"), build)?;
    }

    println!(
        "unpacked the tool into {}\nthe script there is plain text - read it before you trust it\n",
        root.display()
    );
    Ok(root)
}

/// A new build unpacks beside the old one; the old one is a copy of the tool
/// that nothing uses any more, and it is 9 MB of patched core.
fn remove_older_copies(current: &Path) {
    let parent = match current.parent() {
        Some(parent) => parent,
        None => return,
    };
    let entries = match fs::read_dir(parent) {
        Ok(entries) => entries,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name == current.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default() {
            continue;
        }
        let is_marker = name.len() == 16 && name.chars().all(|c| c.is_ascii_hexdigit());
        if is_marker {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
}

/// A content marker: FNV-1a over everything this executable carries, so the
/// unpacked copy changes whenever the executable does.
fn marker() -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut feed = |bytes: &[u8]| {
        for byte in bytes {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x1000_0000_01b3);
        }
    };
    feed(SCRIPT.as_bytes());
    feed(README.as_bytes());
    feed(PATCH);
    for version in PAYLOAD_VERSIONS {
        let (core, _, _) = payload_files(version);
        feed(core);
    }
    format!("{:016x}", hash)
}

fn local_app_data() -> PathBuf {
    env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn powershell_path() -> PathBuf {
    let system = env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
    let candidate = system
        .join("System32")
        .join("WindowsPowerShell")
        .join("v1.0")
        .join("powershell.exe");
    if candidate.is_file() {
        return candidate;
    }
    PathBuf::from("powershell.exe")
}
