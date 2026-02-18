use chess_prep::{import_pgn_file, init_db};
use rusqlite::{Connection, params};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static UNIQUE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn unique_temp_path(stem: &str, ext: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time should be after UNIX_EPOCH")
        .as_nanos();
    let pid = std::process::id();
    let counter = UNIQUE_COUNTER.fetch_add(1, Ordering::Relaxed);

    std::env::temp_dir().join(format!("{stem}_{pid}_{nanos}_{counter}.{ext}"))
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

    let movetext: Option<String> = conn
        .query_row("SELECT pgn FROM games WHERE white = 'Alice'", [], |row| {
            row.get(0)
        })
        .expect("should query stored movetext");
    assert_eq!(movetext.as_deref(), Some("e4 e5 Nf3 Nc6"));

    fs::remove_file(db_path).expect("should clean up temp db file");
    fs::remove_file(pgn_path).expect("should clean up temp PGN file");
}

#[test]
fn reimport_cleans_up_matching_rows_with_empty_movetext() {
    let db_path = unique_temp_db_path();
    let pgn_path = unique_temp_pgn_path();

    let pgn = r#"[Event "Cleanup Test"]
[Site "Berlin"]
[Date "2024.01.01"]
[White "Alice"]
[Black "Bob"]
[Result "1-0"]
[ECO "C20"]

1. e4 e5 2. Nf3 Nc6 1-0
"#;

    fs::write(&pgn_path, pgn).expect("should write temp PGN");
    let db_path_str = db_path
        .to_str()
        .expect("temp db path should be valid UTF-8");
    let pgn_path_str = pgn_path
        .to_str()
        .expect("temp PGN path should be valid UTF-8");

    init_db(db_path_str).expect("init_db should create schema");
    let conn = Connection::open(db_path_str).expect("should open initialized database");
    conn.execute(
        "
        INSERT INTO games (event, site, date, white, black, result, eco, pgn)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL)
        ",
        params![
            "Cleanup Test",
            "Berlin",
            "2024.01.01",
            "Alice",
            "Bob",
            "1-0",
            "C20",
        ],
    )
    .expect("should seed stale empty-movetext row");

    import_pgn_file(db_path_str, pgn_path_str).expect("reimport should work");

    let count: i64 = conn
        .query_row(
            "
            SELECT COUNT(*)
            FROM games
            WHERE event = 'Cleanup Test'
              AND site = 'Berlin'
              AND date = '2024.01.01'
              AND white = 'Alice'
              AND black = 'Bob'
              AND result = '1-0'
              AND eco = 'C20'
            ",
            [],
            |row| row.get(0),
        )
        .expect("should count matching rows");
    assert_eq!(count, 1, "stale empty-movetext row should be removed");

    let movetext: Option<String> = conn
        .query_row(
            "
            SELECT pgn
            FROM games
            WHERE event = 'Cleanup Test'
              AND white = 'Alice'
            ",
            [],
            |row| row.get(0),
        )
        .expect("should read cleaned row");
    assert_eq!(movetext.as_deref(), Some("e4 e5 Nf3 Nc6"));

    fs::remove_file(db_path).expect("should clean up temp db file");
    fs::remove_file(pgn_path).expect("should clean up temp PGN file");
}

#[test]
fn reimport_skips_exact_duplicate_game_rows() {
    let db_path = unique_temp_db_path();
    let pgn_path = unique_temp_pgn_path();

    let pgn = r#"[Event "Exact Duplicate Test"]
[Site "Berlin"]
[Date "2024.02.02"]
[White "Alice"]
[Black "Bob"]
[Result "1-0"]
[ECO "C20"]

1. e4 e5 2. Nf3 Nc6 1-0
"#;

    fs::write(&pgn_path, pgn).expect("should write temp PGN");
    let db_path_str = db_path
        .to_str()
        .expect("temp db path should be valid UTF-8");
    let pgn_path_str = pgn_path
        .to_str()
        .expect("temp PGN path should be valid UTF-8");

    init_db(db_path_str).expect("init_db should create schema");

    let first = import_pgn_file(db_path_str, pgn_path_str).expect("first import should work");
    assert_eq!(first.total, 1);
    assert_eq!(first.inserted, 1);
    assert_eq!(first.skipped, 0);

    let second = import_pgn_file(db_path_str, pgn_path_str).expect("second import should work");
    assert_eq!(second.total, 1);
    assert_eq!(second.inserted, 0, "duplicate row should not be inserted");
    assert_eq!(second.skipped, 1);

    let conn = Connection::open(db_path_str).expect("should open db");
    let count: i64 = conn
        .query_row(
            "
            SELECT COUNT(*)
            FROM games
            WHERE event = 'Exact Duplicate Test'
              AND site = 'Berlin'
              AND date = '2024.02.02'
              AND white = 'Alice'
              AND black = 'Bob'
              AND result = '1-0'
              AND eco = 'C20'
            ",
            [],
            |row| row.get(0),
        )
        .expect("should count rows");
    assert_eq!(count, 1, "should keep only one exact row");

    fs::remove_file(db_path).expect("should clean up temp db file");
    fs::remove_file(pgn_path).expect("should clean up temp PGN file");
}

#[test]
fn import_cleans_up_existing_exact_duplicates_with_movetext() {
    let db_path = unique_temp_db_path();
    let pgn_path = unique_temp_pgn_path();

    let pgn = r#"[Event "Legacy Duplicate Cleanup"]
[Site "Paris"]
[Date "2024.03.03"]
[White "Carol"]
[Black "Dave"]
[Result "0-1"]
[ECO "B01"]

1. e4 d5 2. exd5 Qxd5 0-1
"#;

    fs::write(&pgn_path, pgn).expect("should write temp PGN");
    let db_path_str = db_path
        .to_str()
        .expect("temp db path should be valid UTF-8");
    let pgn_path_str = pgn_path
        .to_str()
        .expect("temp PGN path should be valid UTF-8");

    init_db(db_path_str).expect("init_db should create schema");
    let conn = Connection::open(db_path_str).expect("should open initialized database");

    // Seed two identical rows with movetext (legacy duplicate scenario).
    let duplicate_movetext = "e4 d5 exd5 Qxd5";
    for _ in 0..2 {
        conn.execute(
            "
            INSERT INTO games (event, site, date, white, black, result, eco, pgn)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ",
            params![
                "Legacy Duplicate Cleanup",
                "Paris",
                "2024.03.03",
                "Carol",
                "Dave",
                "0-1",
                "B01",
                duplicate_movetext
            ],
        )
        .expect("should seed duplicate rows");
    }

    import_pgn_file(db_path_str, pgn_path_str).expect("import should trigger cleanup");

    let count: i64 = conn
        .query_row(
            "
            SELECT COUNT(*)
            FROM games
            WHERE event = 'Legacy Duplicate Cleanup'
              AND site = 'Paris'
              AND date = '2024.03.03'
              AND white = 'Carol'
              AND black = 'Dave'
              AND result = '0-1'
              AND eco = 'B01'
              AND pgn = 'e4 d5 exd5 Qxd5'
            ",
            [],
            |row| row.get(0),
        )
        .expect("should count deduped rows");
    assert_eq!(count, 1, "legacy exact duplicates should be cleaned");

    fs::remove_file(db_path).expect("should clean up temp db file");
    fs::remove_file(pgn_path).expect("should clean up temp PGN file");
}
