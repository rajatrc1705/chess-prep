use chess_prep::{ReplayError, import_pgn_file, init_db, replay_game, replay_game_fens};
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
    unique_temp_path("chess_prep_replay_test", "sqlite")
}

fn unique_temp_pgn_path() -> PathBuf {
    unique_temp_path("chess_prep_replay_test", "pgn")
}

#[test]
fn replay_returns_fen_timeline_for_known_game() {
    let db_path = unique_temp_db_path();
    let pgn_path = unique_temp_pgn_path();
    let db_path_str = db_path.to_str().expect("db path should be valid UTF-8");
    let pgn_path_str = pgn_path.to_str().expect("pgn path should be valid UTF-8");

    let pgn = r#"[Event "Replay Test"]
[Site "Berlin"]
[Date "2024.01.01"]
[White "Alice"]
[Black "Bob"]
[Result "1-0"]
[ECO "C20"]

1. e4 e5 2. Nf3 1-0
"#;

    fs::write(&pgn_path, pgn).expect("should write temp PGN");
    init_db(db_path_str).expect("init_db should create schema");
    import_pgn_file(db_path_str, pgn_path_str).expect("import should work");

    let conn = Connection::open(db_path_str).expect("should open db");
    let game_id: i64 = conn
        .query_row("SELECT rowid FROM games WHERE white = 'Alice'", [], |row| {
            row.get(0)
        })
        .expect("should fetch imported game rowid");

    let fens = replay_game_fens(db_path_str, game_id).expect("replay should work");
    assert_eq!(fens.len(), 4, "start + 3 plies expected");
    assert_eq!(
        fens[0],
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    );
    assert_eq!(
        fens[1],
        "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
    );
    assert_eq!(
        fens[2],
        "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
    );
    assert_eq!(
        fens[3],
        "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2"
    );

    let timeline = replay_game(db_path_str, game_id).expect("timeline replay should work");
    assert_eq!(timeline.sans, vec!["e4", "e5", "Nf3"]);
    assert_eq!(timeline.ucis, vec!["e2e4", "e7e5", "g1f3"]);
    assert_eq!(timeline.fens, fens);

    fs::remove_file(db_path).expect("should clean up temp db");
    fs::remove_file(pgn_path).expect("should clean up temp pgn");
}

#[test]
fn replay_returns_missing_movetext_for_null_pgn_column() {
    let db_path = unique_temp_db_path();
    let db_path_str = db_path.to_str().expect("db path should be valid UTF-8");

    init_db(db_path_str).expect("init_db should create schema");
    let conn = Connection::open(db_path_str).expect("should open db");
    conn.execute(
        "
        INSERT INTO games (event, site, date, white, black, result, eco, pgn)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL)
        ",
        params![
            "Replay Missing",
            "Nowhere",
            "2024.01.01",
            "Alice",
            "Bob",
            "1-0",
            "C20",
        ],
    )
    .expect("should insert game");
    let game_id = conn.last_insert_rowid();

    let err = replay_game_fens(db_path_str, game_id).expect_err("replay should fail");
    assert!(matches!(err, ReplayError::MissingMovetext(id) if id == game_id));

    fs::remove_file(db_path).expect("should clean up temp db");
}

#[test]
fn replay_returns_invalid_san_error_for_bad_movetext() {
    let db_path = unique_temp_db_path();
    let db_path_str = db_path.to_str().expect("db path should be valid UTF-8");

    init_db(db_path_str).expect("init_db should create schema");
    let conn = Connection::open(db_path_str).expect("should open db");
    conn.execute(
        "
        INSERT INTO games (event, site, date, white, black, result, eco, pgn)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ",
        params![
            "Replay Invalid",
            "Nowhere",
            "2024.01.01",
            "Alice",
            "Bob",
            "1-0",
            "C20",
            "e4 ???",
        ],
    )
    .expect("should insert game");
    let game_id = conn.last_insert_rowid();

    let err = replay_game_fens(db_path_str, game_id).expect_err("replay should fail");
    assert!(matches!(
        err,
        ReplayError::InvalidSan { ply: 2, san } if san == "???"
    ));

    fs::remove_file(db_path).expect("should clean up temp db");
}
