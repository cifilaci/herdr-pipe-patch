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

// What this executable carries, read out of `assets` when it is built: the
// payload (one patched core per version), the script, the patch, the skill
// and the installers that put the skill in place.
include!(concat!(env!("OUT_DIR"), "/payloads.rs"));

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

This executable carries the script, the patched core, the patch, the skill and
the two installers. On first run they are unpacked under
%LOCALAPPDATA%\\herdr-pipe-patch\\<marker> and the script is run from there; the
unpacked files stay readable.";

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

    let args = normalise_accounts(&args);

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

/// PowerShell refuses a parameter that is given twice, so "-Account A
/// -Account B" fails before the script sees it. The values are joined into one
/// comma-separated value instead, which the script splits. Both the space form
/// and the "=" form are recognised, and the same is done for -Sids: the script
/// splits both on a comma and on a semicolon.
fn normalise_accounts(args: &[OsString]) -> Vec<OsString> {
    // The parameters whose value may be given more than once.
    const JOINED: [&str; 2] = ["-Account", "-Sids"];

    // Every occurrence of such a parameter, and the tokens it covers.
    struct Occurrence {
        start: usize,
        end: usize,
        name: String,
        values: Vec<String>,
    }

    let mut occurrences: Vec<Occurrence> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let text = args[i].to_string_lossy().to_string();
        let (name, inline) = match split_parameter(&text) {
            Some(parts) => parts,
            None => {
                i += 1;
                continue;
            }
        };
        if !JOINED.iter().any(|p| p.eq_ignore_ascii_case(&name)) {
            i += 1;
            continue;
        }
        let mut values = Vec::new();
        let mut end = i + 1;
        match inline {
            Some(value) => values.push(value),
            None => {
                while end < args.len() && !args[end].to_string_lossy().starts_with('-') {
                    values.push(args[end].to_string_lossy().to_string());
                    end += 1;
                }
            }
        }
        occurrences.push(Occurrence {
            start: i,
            end,
            name,
            values,
        });
        i = end;
    }

    // The values of each parameter, in the order they were given.
    let mut values_of: Vec<(String, Vec<String>)> = Vec::new();
    for occurrence in &occurrences {
        match values_of
            .iter_mut()
            .find(|(name, _)| name.eq_ignore_ascii_case(&occurrence.name))
        {
            Some((_, values)) => values.extend(occurrence.values.iter().cloned()),
            None => values_of.push((occurrence.name.clone(), occurrence.values.clone())),
        }
    }

    let mut out: Vec<OsString> = Vec::new();
    let mut joined: Vec<String> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let occurrence = match occurrences.iter().find(|o| o.start == i) {
            Some(occurrence) => occurrence,
            None => {
                out.push(args[i].clone());
                i += 1;
                continue;
            }
        };
        let values = values_of
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case(&occurrence.name))
            .map(|(_, values)| values.clone())
            .unwrap_or_default();
        if values.len() > 1 && !joined.iter().any(|n| n.eq_ignore_ascii_case(&occurrence.name)) {
            // The space form, not "name=value": a value that holds a $ or a
            // quote must reach PowerShell exactly as it was written.
            joined.push(occurrence.name.clone());
            out.push(OsString::from(occurrence.name.clone()));
            out.push(OsString::from(values.join(",")));
        } else if values.len() <= 1 {
            // One value, given once: the tokens are left as they are.
            for arg in &args[occurrence.start..occurrence.end] {
                out.push(arg.clone());
            }
        }
        // More than one value and this is not the first occurrence: the values
        // are already in the one that was emitted.
        i = occurrence.end;
    }
    out
}

/// The parameter name and the value of one argument, if it is a parameter at
/// all: "-Account", "-Account=Alice", or "-AccountPattern" (which takes its
/// value from the next argument).
fn split_parameter(arg: &str) -> Option<(String, Option<String>)> {
    if !arg.starts_with('-') || arg.len() < 2 {
        return None;
    }
    match arg.find('=') {
        Some(at) => Some((arg[..at].to_string(), Some(arg[at + 1..].to_string()))),
        None => Some((arg.to_string(), None)),
    }
}

/// Where the tool is unpacked: a marker directory under LOCALAPPDATA, so a new
/// build of this executable unpacks afresh and an old one keeps working.
fn unpack() -> std::io::Result<PathBuf> {
    let root = local_app_data().join("herdr-pipe-patch").join(marker());
    // The tree counts as fresh only when every file it should hold is there,
    // byte for byte. A file that is merely present - truncated, half-written -
    // is not a working tool, and it must not be left there.
    if tree_marker(&root).as_deref() == Some(marker().as_str()) {
        remove_older_copies(&root);
        return Ok(root);
    }
    if root.exists() {
        let _ = fs::remove_dir_all(&root);
    }

    for (relative, bytes) in EXTRA_FILES {
        let target = root.join(relative);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(target, bytes)?;
    }
    for version in PAYLOAD_VERSIONS {
        let dir = root.join("payload").join(version);
        fs::create_dir_all(&dir)?;
        let (core, checksum, build) = payload_files(version);
        fs::write(dir.join("herdr-core.exe"), core)?;
        fs::write(dir.join("herdr-core.exe.sha256"), checksum)?;
        fs::write(dir.join("BUILD.txt"), build)?;
    }

    // The previous build's copy is 9 MB of patched core that nothing uses any
    // more. It goes now, not on the next run.
    remove_older_copies(&root);

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
    for (_, bytes) in EXTRA_FILES {
        feed(bytes);
    }
    for version in PAYLOAD_VERSIONS {
        let (core, checksum, build) = payload_files(version);
        feed(core);
        feed(checksum.as_bytes());
        feed(build.as_bytes());
    }
    format!("{:016x}", hash)
}

/// The same marker, computed from the files that are on disk. It is what says
/// whether the unpacked tree is intact.
fn tree_marker(root: &Path) -> Option<String> {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut feed = |bytes: &[u8]| {
        for byte in bytes {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x1000_0000_01b3);
        }
    };
    for (relative, _) in EXTRA_FILES {
        feed(&fs::read(root.join(relative)).ok()?);
    }
    for version in PAYLOAD_VERSIONS {
        let dir = root.join("payload").join(version);
        feed(&fs::read(dir.join("herdr-core.exe")).ok()?);
        feed(&fs::read(dir.join("herdr-core.exe.sha256")).ok()?);
        feed(&fs::read(dir.join("BUILD.txt")).ok()?);
    }
    Some(format!("{:016x}", hash))
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
