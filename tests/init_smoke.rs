use chess_prep::{import_pgn_file, init_db};
use rusqlite::Connection;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn unique_temp_path(stem: &str, ext: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time should be after UNIX_EPOCH")
        .as_nanos();

    std::env::temp_dir().join(format!("{stem}_{nanos}.{ext}"))
}

fn unique_temp_db_path() -> PathBuf {
    unique_temp_path("chess_prep_test", "sqlite")
}

fn unique_temp_pgn_path() -> PathBuf {
    unique_temp_path("chess_prep_test", "pgn")
}

#[test]
fn init_db_creates_games_table() {
    let db_path = unique_temp_db_path();

    init_db(
        db_path
            .to_str()
            .expect("temp db path should be valid UTF-8"),
    )
    .expect("init_db should create schema");

    let conn = Connection::open(&db_path).expect("should open initialized database");
    let exists: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='games'",
            [],
            |row| row.get(0),
        )
        .expect("should query sqlite_master");

    assert_eq!(exists, 1, "games table should exist");

    fs::remove_file(db_path).expect("should clean up temp db file");
}

#[test]
fn import_pgn_file_inserts_games_and_tags() {
    let db_path = unique_temp_db_path();
    let pgn_path = unique_temp_pgn_path();

    let pgn = r#"[Event "Game One"]
[Site "https://example.org/1"]
[Date "2024.01.01"]
[White "Alice"]
[Black "Bob"]
[Result "1-0"]
[ECO "C20"]

1. e4 e5 2. Nf3 Nc6 1-0

[Event "Game Two"]
[Site "https://example.org/2"]
[Date "2024.01.02"]
[White "Carol"]
[Black "Dave"]
[Result "0-1"]
[ECO "B01"]

1. e4 d5 2. exd5 Qxd5 0-1
"#;

    fs::write(&pgn_path, pgn).expect("should write temp PGN");
    init_db(
        db_path
            .to_str()
            .expect("temp db path should be valid UTF-8"),
    )
    .expect("init_db should create schema");

    let summary = import_pgn_file(
        db_path
            .to_str()
            .expect("temp db path should be valid UTF-8"),
        pgn_path
            .to_str()
            .expect("temp PGN path should be valid UTF-8"),
    )
    .expect("import_pgn_file should import games");

    assert_eq!(summary.total, 2, "should parse 2 games");
    assert_eq!(summary.inserted, 2, "should insert 2 games");
    assert_eq!(summary.skipped, 0, "should skip 0 games");

    let conn = Connection::open(&db_path).expect("should open initialized database");
    let count: i64 = conn
        .query_row("SELECT COUNT(*) FROM games", [], |row| row.get(0))
        .expect("should count games");
    assert_eq!(count, 2, "games table should contain imported games");

    let (event, result): (String, String) = conn
        .query_row(
            "SELECT event, result FROM games WHERE white = 'Alice'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("should query imported tag values");
    assert_eq!(event, "Game One");
    assert_eq!(result, "1-0");

    fs::remove_file(db_path).expect("should clean up temp db file");
    fs::remove_file(pgn_path).expect("should clean up temp PGN file");
}
