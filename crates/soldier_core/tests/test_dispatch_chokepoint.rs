use std::fs;
use std::path::{Path, PathBuf};

const CHOKEPOINT_RELATIVE_PATH: &str = "src/execution/build_order_intent.rs";
const DISPATCH_MARKER: &str = "DispatchStep::DispatchAttempt";

fn collect_rs_files(dir: &Path, out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            collect_rs_files(&path, out)?;
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("rs") {
            out.push(path);
        }
    }
    Ok(())
}

fn rel_path(path: &Path, base: &Path) -> String {
    path.strip_prefix(base)
        .unwrap_or(path)
        .display()
        .to_string()
}

#[test]
fn test_dispatch_chokepoint_no_direct_exchange_client_usage() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let src_dir = manifest_dir.join("src");
    let chokepoint = manifest_dir.join(CHOKEPOINT_RELATIVE_PATH);
    let chokepoint = chokepoint
        .canonicalize()
        .expect("chokepoint file missing");

    let mut rs_files = Vec::new();
    collect_rs_files(&src_dir, &mut rs_files).expect("failed to list source files");

    let mut offenders = Vec::new();
    let mut chokepoint_seen = false;

    for file in rs_files {
        let contents = fs::read_to_string(&file)
            .unwrap_or_else(|err| panic!("failed to read {}: {err}", file.display()));
        if contents.contains(DISPATCH_MARKER) {
            let canonical = file
                .canonicalize()
                .unwrap_or_else(|err| panic!("failed to canonicalize {}: {err}", file.display()));
            if canonical == chokepoint {
                chokepoint_seen = true;
            } else {
                offenders.push(rel_path(&canonical, &manifest_dir));
            }
        }
    }

    assert!(
        chokepoint_seen,
        "dispatch marker '{DISPATCH_MARKER}' missing from chokepoint {}",
        rel_path(&chokepoint, &manifest_dir)
    );
    assert!(
        offenders.is_empty(),
        "dispatch marker '{DISPATCH_MARKER}' found outside chokepoint: {}",
        offenders.join(", ")
    );
}

#[test]
fn test_dispatch_visibility_is_restricted() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let chokepoint = manifest_dir.join(CHOKEPOINT_RELATIVE_PATH);
    let contents =
        fs::read_to_string(&chokepoint).expect("failed to read chokepoint module");

    let mut signature = None;
    for line in contents.lines() {
        if line.contains("fn record_dispatch_step") {
            signature = Some(line.trim().to_string());
            break;
        }
    }

    let signature = signature.expect("expected record_dispatch_step signature");
    if signature.trim_start().starts_with("pub fn record_dispatch_step") {
        panic!(
            "dispatch helper visibility too wide; expected pub(crate) or narrower, got: {signature}"
        );
    }
}
