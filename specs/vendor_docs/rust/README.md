# Rust Vendor Docs (Pinned and Reproducible)

## Goal
Prevent "from memory" API usage for external crates. All crate API reasoning must be traceable to:
1) Cargo.lock (exact version)
2) resolved feature set
3) a pinned documentation snapshot

## Structure
specs/vendor_docs/rust/
  CRATES_OF_INTEREST.yaml
  crates/<crate>/<version>/
    features.txt
    CONTEXT7_SNAPSHOT.md
    DOCSRS_LINK.txt
    metadata.json

## Determinism Rules
- Always run Cargo commands with --locked.
- metadata.json MUST include:
  - crate
  - version
  - retrieved_at_utc
  - cargo_lock_sha256
  - resolved_features_sha256
  - topics (list)
  - source ("context7" | "docsrs" | "local_doc")
- features.txt MUST be produced from the resolved workspace graph (not guesses).

## Snapshot Policy
- Only crates listed in CRATES_OF_INTEREST.yaml require snapshots.
- Only topics listed per crate are required for snapshot completeness.
- When Cargo.lock changes, any changed crate in CRATES_OF_INTEREST.yaml
  MUST have a corresponding new version directory with updated metadata.

## docs.rs Caveat
docs.rs builds may not include non-default features unless configured.
If our enabled features differ from docs.rs defaults, note it in metadata.json
and prefer a local doc build for feature-sensitive APIs.

## Reference Commands
cargo metadata --locked --format-version 1 > artifacts/verify/cargo_metadata.locked.json
cargo tree --locked -e features,normal --workspace --prefix none > artifacts/verify/cargo_tree.features_normal.txt
cargo tree --locked -e features -i <crate> --workspace --prefix none > artifacts/verify/cargo_tree.features_in.<crate>.txt
