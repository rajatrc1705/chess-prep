use chess_prep::{
    AnalysisWorkspaceError, AnalysisWorkspaceNode, init_analysis_workspace_db,
    list_analysis_workspaces, load_analysis_workspace, save_analysis_workspace,
};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static UNIQUE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn unique_temp_db_path() -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time should be after UNIX_EPOCH")
        .as_nanos();
    let pid = std::process::id();
    let counter = UNIQUE_COUNTER.fetch_add(1, Ordering::Relaxed);

    std::env::temp_dir().join(format!(
        "chess_prep_analysis_workspace_test_{pid}_{nanos}_{counter}.sqlite"
    ))
}

#[test]
fn analysis_workspace_roundtrip_save_list_load() {
    let db_path = unique_temp_db_path();
    let db_path_str = db_path.to_str().expect("path should be valid utf-8");

    init_analysis_workspace_db(db_path_str).expect("analysis db init should succeed");

    let nodes = vec![
        AnalysisWorkspaceNode {
            id: "root".to_string(),
            parent_id: None,
            san: None,
            uci: None,
            fen: "startfen".to_string(),
            comment: "".to_string(),
            nags: vec![],
            sort_index: 0,
        },
        AnalysisWorkspaceNode {
            id: "n1".to_string(),
            parent_id: Some("root".to_string()),
            san: Some("e4".to_string()),
            uci: Some("e2e4".to_string()),
            fen: "fen_after_e4".to_string(),
            comment: "prep note".to_string(),
            nags: vec!["!".to_string()],
            sort_index: 0,
        },
    ];

    let workspace_id = save_analysis_workspace(
        db_path_str,
        "/tmp/source.sqlite",
        7,
        "Stage2 Test",
        "root",
        Some("n1"),
        &nodes,
    )
    .expect("save should succeed");

    let list =
        list_analysis_workspaces(db_path_str, "/tmp/source.sqlite", 7).expect("list should work");
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].id, workspace_id);
    assert_eq!(list[0].name, "Stage2 Test");

    let loaded = load_analysis_workspace(db_path_str, workspace_id).expect("load should work");
    assert_eq!(loaded.workspace.root_node_id, "root");
    assert_eq!(loaded.workspace.current_node_id.as_deref(), Some("n1"));
    assert_eq!(loaded.nodes.len(), 2);
    assert!(loaded.nodes.iter().any(|node| node.id == "n1"));

    fs::remove_file(db_path).expect("cleanup should work");
}

#[test]
fn analysis_workspace_rejects_empty_nodes() {
    let db_path = unique_temp_db_path();
    let db_path_str = db_path.to_str().expect("path should be valid utf-8");

    let err = save_analysis_workspace(
        db_path_str,
        "/tmp/source.sqlite",
        10,
        "Empty",
        "root",
        None,
        &[],
    )
    .expect_err("save should fail for empty nodes");

    assert!(matches!(err, AnalysisWorkspaceError::InvalidInput(_)));
}
