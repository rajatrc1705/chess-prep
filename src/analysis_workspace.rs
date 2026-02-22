use std::{
    collections::HashSet,
    time::{SystemTime, UNIX_EPOCH},
};

use rusqlite::{Connection, OptionalExtension, params};

use crate::types::{
    AnalysisWorkspaceError, AnalysisWorkspaceNode, AnalysisWorkspaceSummary,
    LoadedAnalysisWorkspace,
};

pub fn init_analysis_workspace_db(path: &str) -> Result<(), AnalysisWorkspaceError> {
    let conn = Connection::open(path)?;
    conn.execute_batch("PRAGMA foreign_keys = ON;")?;
    ensure_schema(&conn)?;
    Ok(())
}

fn ensure_schema(conn: &Connection) -> Result<(), AnalysisWorkspaceError> {
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS analysis_workspaces (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_db_path TEXT NOT NULL,
            game_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            root_node_id TEXT NOT NULL,
            current_node_id TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_analysis_workspaces_game
        ON analysis_workspaces(source_db_path, game_id, updated_at DESC, id DESC);

        CREATE TABLE IF NOT EXISTS analysis_nodes (
            workspace_id INTEGER NOT NULL,
            node_id TEXT NOT NULL,
            parent_node_id TEXT,
            san TEXT,
            uci TEXT,
            fen TEXT NOT NULL,
            comment TEXT NOT NULL DEFAULT '',
            nags TEXT NOT NULL DEFAULT '',
            sort_index INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (workspace_id, node_id),
            FOREIGN KEY (workspace_id) REFERENCES analysis_workspaces(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_analysis_nodes_parent
        ON analysis_nodes(workspace_id, parent_node_id, sort_index, node_id);
        ",
    )?;
    Ok(())
}

pub fn save_analysis_workspace(
    analysis_db_path: &str,
    source_db_path: &str,
    game_id: i64,
    name: &str,
    root_node_id: &str,
    current_node_id: Option<&str>,
    nodes: &[AnalysisWorkspaceNode],
) -> Result<i64, AnalysisWorkspaceError> {
    let source_db_path = source_db_path.trim();
    let name = name.trim();
    let root_node_id = root_node_id.trim();
    let current_node_id = current_node_id
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);

    if source_db_path.is_empty() {
        return Err(AnalysisWorkspaceError::InvalidInput(
            "source_db_path is required".to_string(),
        ));
    }
    if name.is_empty() {
        return Err(AnalysisWorkspaceError::InvalidInput(
            "workspace name is required".to_string(),
        ));
    }
    if root_node_id.is_empty() {
        return Err(AnalysisWorkspaceError::InvalidInput(
            "root_node_id is required".to_string(),
        ));
    }
    if nodes.is_empty() {
        return Err(AnalysisWorkspaceError::InvalidInput(
            "at least one analysis node is required".to_string(),
        ));
    }

    for node in nodes {
        if node.id.trim().is_empty() {
            return Err(AnalysisWorkspaceError::InvalidInput(
                "node id cannot be empty".to_string(),
            ));
        }
        if node.fen.trim().is_empty() {
            return Err(AnalysisWorkspaceError::InvalidInput(
                "node fen cannot be empty".to_string(),
            ));
        }
    }

    let node_ids: HashSet<&str> = nodes.iter().map(|node| node.id.trim()).collect();

    if !node_ids.contains(root_node_id) {
        return Err(AnalysisWorkspaceError::InvalidInput(format!(
            "root node '{root_node_id}' was not found in node payload"
        )));
    }

    if let Some(current) = current_node_id.as_deref()
        && !node_ids.contains(current)
    {
        return Err(AnalysisWorkspaceError::InvalidInput(format!(
            "current node '{current}' was not found in node payload"
        )));
    }

    for node in nodes {
        if let Some(parent) = node
            .parent_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            && !node_ids.contains(parent)
        {
            return Err(AnalysisWorkspaceError::InvalidInput(format!(
                "parent node '{parent}' for node '{}' was not found in node payload",
                node.id
            )));
        }
    }

    let now = now_unix_seconds()?;

    let mut conn = Connection::open(analysis_db_path)?;
    conn.execute_batch("PRAGMA foreign_keys = ON;")?;
    ensure_schema(&conn)?;

    let tx = conn.transaction()?;
    tx.execute(
        "
        INSERT INTO analysis_workspaces (
            source_db_path, game_id, name, root_node_id, current_node_id, created_at, updated_at
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
        ",
        params![
            source_db_path,
            game_id,
            name,
            root_node_id,
            current_node_id,
            now
        ],
    )?;
    let workspace_id = tx.last_insert_rowid();

    {
        let mut stmt = tx.prepare(
            "
            INSERT INTO analysis_nodes (
                workspace_id, node_id, parent_node_id, san, uci, fen, comment, nags, sort_index
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
            ",
        )?;

        for node in nodes {
            let node_id = node.id.trim();
            let parent_node_id = node
                .parent_id
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty());
            let san = node
                .san
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty());
            let uci = node
                .uci
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty());
            let fen = node.fen.trim();
            let comment = node.comment.as_str();
            let nags = serialize_nags(&node.nags);

            stmt.execute(params![
                workspace_id,
                node_id,
                parent_node_id,
                san,
                uci,
                fen,
                comment,
                nags,
                node.sort_index
            ])?;
        }
    }

    tx.commit()?;
    Ok(workspace_id)
}

pub fn rename_analysis_workspace(
    analysis_db_path: &str,
    workspace_id: i64,
    name: &str,
) -> Result<(), AnalysisWorkspaceError> {
    let name = name.trim();
    if name.is_empty() {
        return Err(AnalysisWorkspaceError::InvalidInput(
            "workspace name is required".to_string(),
        ));
    }

    let now = now_unix_seconds()?;
    let conn = Connection::open(analysis_db_path)?;
    conn.execute_batch("PRAGMA foreign_keys = ON;")?;
    ensure_schema(&conn)?;

    let changed = conn.execute(
        "
        UPDATE analysis_workspaces
        SET name = ?2, updated_at = ?3
        WHERE id = ?1
        ",
        params![workspace_id, name, now],
    )?;

    if changed == 0 {
        return Err(AnalysisWorkspaceError::NotFound(workspace_id));
    }

    Ok(())
}

pub fn delete_analysis_workspace(
    analysis_db_path: &str,
    workspace_id: i64,
) -> Result<(), AnalysisWorkspaceError> {
    let conn = Connection::open(analysis_db_path)?;
    conn.execute_batch("PRAGMA foreign_keys = ON;")?;
    ensure_schema(&conn)?;

    let changed = conn.execute(
        "
        DELETE FROM analysis_workspaces
        WHERE id = ?1
        ",
        params![workspace_id],
    )?;

    if changed == 0 {
        return Err(AnalysisWorkspaceError::NotFound(workspace_id));
    }

    Ok(())
}

pub fn list_analysis_workspaces(
    analysis_db_path: &str,
    source_db_path: &str,
    game_id: i64,
) -> Result<Vec<AnalysisWorkspaceSummary>, AnalysisWorkspaceError> {
    let conn = Connection::open(analysis_db_path)?;
    conn.execute_batch("PRAGMA foreign_keys = ON;")?;
    ensure_schema(&conn)?;

    let mut stmt = conn.prepare(
        "
        SELECT id, source_db_path, game_id, name, root_node_id, current_node_id, created_at, updated_at
        FROM analysis_workspaces
        WHERE source_db_path = ?1 AND game_id = ?2
        ORDER BY updated_at DESC, id DESC
        ",
    )?;

    let rows = stmt.query_map(params![source_db_path.trim(), game_id], |row| {
        Ok(AnalysisWorkspaceSummary {
            id: row.get(0)?,
            source_db_path: row.get(1)?,
            game_id: row.get(2)?,
            name: row.get(3)?,
            root_node_id: row.get(4)?,
            current_node_id: row.get(5)?,
            created_at: row.get(6)?,
            updated_at: row.get(7)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn load_analysis_workspace(
    analysis_db_path: &str,
    workspace_id: i64,
) -> Result<LoadedAnalysisWorkspace, AnalysisWorkspaceError> {
    let conn = Connection::open(analysis_db_path)?;
    conn.execute_batch("PRAGMA foreign_keys = ON;")?;
    ensure_schema(&conn)?;

    let workspace = conn
        .query_row(
            "
            SELECT id, source_db_path, game_id, name, root_node_id, current_node_id, created_at, updated_at
            FROM analysis_workspaces
            WHERE id = ?1
            ",
            params![workspace_id],
            |row| {
                Ok(AnalysisWorkspaceSummary {
                    id: row.get(0)?,
                    source_db_path: row.get(1)?,
                    game_id: row.get(2)?,
                    name: row.get(3)?,
                    root_node_id: row.get(4)?,
                    current_node_id: row.get(5)?,
                    created_at: row.get(6)?,
                    updated_at: row.get(7)?,
                })
            },
        )
        .optional()?
        .ok_or(AnalysisWorkspaceError::NotFound(workspace_id))?;

    let mut stmt = conn.prepare(
        "
        SELECT node_id, parent_node_id, san, uci, fen, comment, nags, sort_index
        FROM analysis_nodes
        WHERE workspace_id = ?1
        ORDER BY
            CASE WHEN parent_node_id IS NULL THEN 0 ELSE 1 END ASC,
            COALESCE(parent_node_id, '') ASC,
            sort_index ASC,
            node_id ASC
        ",
    )?;

    let rows = stmt.query_map(params![workspace_id], |row| {
        let nags_text: String = row.get(6)?;
        Ok(AnalysisWorkspaceNode {
            id: row.get(0)?,
            parent_id: row.get(1)?,
            san: row.get(2)?,
            uci: row.get(3)?,
            fen: row.get(4)?,
            comment: row.get(5)?,
            nags: parse_nags(&nags_text),
            sort_index: row.get(7)?,
        })
    })?;

    let mut nodes = Vec::new();
    for row in rows {
        nodes.push(row?);
    }

    Ok(LoadedAnalysisWorkspace { workspace, nodes })
}

fn serialize_nags(nags: &[String]) -> String {
    nags.iter()
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>()
        .join(",")
}

fn now_unix_seconds() -> Result<i64, AnalysisWorkspaceError> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| {
            AnalysisWorkspaceError::InvalidInput("system clock is before UNIX_EPOCH".to_string())
        })?
        .as_secs() as i64)
}

fn parse_nags(raw: &str) -> Vec<String> {
    raw.split(',')
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static UNIQUE_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn unique_temp_db_path() -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time should be after UNIX_EPOCH")
            .as_nanos();
        let pid = std::process::id();
        let counter = UNIQUE_COUNTER.fetch_add(1, Ordering::Relaxed);

        std::env::temp_dir().join(format!(
            "chess_prep_analysis_workspace_{pid}_{nanos}_{counter}.sqlite"
        ))
    }

    #[test]
    fn save_list_load_roundtrip() {
        let db_path = unique_temp_db_path();
        let db_path_str = db_path.to_str().expect("db path should be utf-8");

        init_analysis_workspace_db(db_path_str).expect("init analysis db");

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
                fen: "fen1".to_string(),
                comment: "good practical move".to_string(),
                nags: vec!["!".to_string()],
                sort_index: 0,
            },
        ];

        let workspace_id = save_analysis_workspace(
            db_path_str,
            "/tmp/source.sqlite",
            42,
            "Test Workspace",
            "root",
            Some("n1"),
            &nodes,
        )
        .expect("save workspace should succeed");

        let list = list_analysis_workspaces(db_path_str, "/tmp/source.sqlite", 42)
            .expect("list should succeed");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, workspace_id);
        assert_eq!(list[0].name, "Test Workspace");

        let loaded = load_analysis_workspace(db_path_str, workspace_id).expect("load should work");
        assert_eq!(loaded.workspace.root_node_id, "root");
        assert_eq!(loaded.workspace.current_node_id.as_deref(), Some("n1"));
        assert_eq!(loaded.nodes.len(), 2);
        assert!(
            loaded
                .nodes
                .iter()
                .any(|n| n.id == "n1" && n.comment == "good practical move")
        );

        fs::remove_file(db_path).expect("cleanup should work");
    }

    #[test]
    fn rejects_empty_nodes_on_save() {
        let db_path = unique_temp_db_path();
        let db_path_str = db_path.to_str().expect("db path should be utf-8");

        let err = save_analysis_workspace(
            db_path_str,
            "/tmp/source.sqlite",
            99,
            "Empty Nodes",
            "root",
            None,
            &[],
        )
        .expect_err("save should fail");

        assert!(matches!(err, AnalysisWorkspaceError::InvalidInput(_)));
    }

    #[test]
    fn rename_and_delete_workspace_roundtrip() {
        let db_path = unique_temp_db_path();
        let db_path_str = db_path.to_str().expect("db path should be utf-8");

        init_analysis_workspace_db(db_path_str).expect("init analysis db");

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
                fen: "fen1".to_string(),
                comment: "".to_string(),
                nags: vec![],
                sort_index: 0,
            },
        ];

        let workspace_id = save_analysis_workspace(
            db_path_str,
            "/tmp/source.sqlite",
            7,
            "Initial Name",
            "root",
            Some("n1"),
            &nodes,
        )
        .expect("save should succeed");

        rename_analysis_workspace(db_path_str, workspace_id, "Renamed Workspace")
            .expect("rename should succeed");

        let list = list_analysis_workspaces(db_path_str, "/tmp/source.sqlite", 7)
            .expect("list should succeed");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "Renamed Workspace");

        delete_analysis_workspace(db_path_str, workspace_id).expect("delete should succeed");

        let list_after_delete = list_analysis_workspaces(db_path_str, "/tmp/source.sqlite", 7)
            .expect("list after delete should succeed");
        assert!(list_after_delete.is_empty());
    }
}
