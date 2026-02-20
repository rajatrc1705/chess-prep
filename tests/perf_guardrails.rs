use chess_prep::{GameFilter, Pagination, import_pgn_file, init_db, replay_game, search_games};
use rusqlite::{Connection, params};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

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

fn threshold_ms(var_name: &str, default_ms: u128) -> u128 {
    std::env::var(var_name)
        .ok()
        .and_then(|value| value.parse::<u128>().ok())
        .unwrap_or(default_ms)
}

#[test]
fn import_latency_guardrail() {
    let db_path = unique_temp_path("chess_prep_perf_import", "sqlite");
    let pgn_path = unique_temp_path("chess_prep_perf_import", "pgn");
    let db_path_str = db_path.to_str().expect("db path should be valid UTF-8");
    let pgn_path_str = pgn_path.to_str().expect("pgn path should be valid UTF-8");

    let game_count = 450usize;
    let mut pgn = String::new();
    for i in 0..game_count {
        pgn.push_str(&format!(
            "[Event \"Perf Import\"]\n[Site \"Local\"]\n[Date \"2024.01.{:02}\"]\n[White \"W{i}\"]\n[Black \"B{i}\"]\n[Result \"1-0\"]\n[ECO \"C20\"]\n\n1. Nf3 Nf6 2. Ng1 Ng8 1-0\n\n",
            (i % 28) + 1
        ));
    }

    fs::write(&pgn_path, pgn).expect("should write temp pgn");
    init_db(db_path_str).expect("init_db should create schema");

    let started = Instant::now();
    let summary = import_pgn_file(db_path_str, pgn_path_str).expect("import should succeed");
    let elapsed = started.elapsed().as_millis();

    assert_eq!(summary.total, game_count);
    assert_eq!(summary.inserted, game_count);
    assert_eq!(summary.skipped, 0);
    assert_eq!(summary.errors, 0);

    let max_ms = threshold_ms("CHESS_PREP_PERF_IMPORT_MAX_MS", 12_000);
    assert!(
        elapsed <= max_ms,
        "import latency guardrail exceeded: {elapsed}ms > {max_ms}ms"
    );

    fs::remove_file(db_path).expect("should clean up temp db");
    fs::remove_file(pgn_path).expect("should clean up temp pgn");
}

#[test]
fn query_latency_guardrail() {
    let db_path = unique_temp_path("chess_prep_perf_query", "sqlite");
    let db_path_str = db_path.to_str().expect("db path should be valid UTF-8");

    init_db(db_path_str).expect("init_db should create schema");
    let mut conn = Connection::open(db_path_str).expect("should open db");
    let tx = conn.transaction().expect("should begin transaction");
    {
        let mut stmt = tx
            .prepare(
                "
                INSERT INTO games (event, site, date, white, black, result, eco, pgn)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                ",
            )
            .expect("should prepare insert");

        for i in 0..10_000 {
            stmt.execute(params![
                "Perf Query",
                "Local",
                format!("2024.02.{:02}", (i % 28) + 1),
                format!("Player {i}"),
                format!("Opponent {i}"),
                "1-0",
                "C20",
                "Nf3 Nf6 Ng1 Ng8",
            ])
            .expect("should insert game");
        }
    }
    tx.commit().expect("should commit seed data");

    let filter = GameFilter {
        search_text: Some("player 99".to_string()),
        ..GameFilter::default()
    };

    let started = Instant::now();
    let rows = search_games(
        db_path_str,
        &filter,
        Pagination {
            limit: 100,
            offset: 0,
        },
    )
    .expect("search should succeed");
    let elapsed = started.elapsed().as_millis();

    assert!(!rows.is_empty(), "query should return at least one row");

    let max_ms = threshold_ms("CHESS_PREP_PERF_QUERY_MAX_MS", 3_000);
    assert!(
        elapsed <= max_ms,
        "query latency guardrail exceeded: {elapsed}ms > {max_ms}ms"
    );

    fs::remove_file(db_path).expect("should clean up temp db");
}

#[test]
fn replay_latency_guardrail() {
    let db_path = unique_temp_path("chess_prep_perf_replay", "sqlite");
    let db_path_str = db_path.to_str().expect("db path should be valid UTF-8");

    init_db(db_path_str).expect("init_db should create schema");
    let conn = Connection::open(db_path_str).expect("should open db");

    let cycle = ["Nf3", "Nf6", "Ng1", "Ng8"];
    let cycles = 90usize;
    let movetext = (0..cycles)
        .flat_map(|_| cycle.iter().copied())
        .collect::<Vec<_>>()
        .join(" ");

    conn.execute(
        "
        INSERT INTO games (event, site, date, white, black, result, eco, pgn)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ",
        params![
            "Perf Replay",
            "Local",
            "2024.03.01",
            "Alice",
            "Bob",
            "1/2-1/2",
            "A00",
            movetext,
        ],
    )
    .expect("should insert replay row");
    let game_id = conn.last_insert_rowid();

    let started = Instant::now();
    let timeline = replay_game(db_path_str, game_id).expect("replay should succeed");
    let elapsed = started.elapsed().as_millis();

    assert_eq!(timeline.sans.len(), cycles * 4);
    assert_eq!(timeline.ucis.len(), cycles * 4);
    assert_eq!(timeline.fens.len(), cycles * 4 + 1);

    let max_ms = threshold_ms("CHESS_PREP_PERF_REPLAY_MAX_MS", 3_000);
    assert!(
        elapsed <= max_ms,
        "replay latency guardrail exceeded: {elapsed}ms > {max_ms}ms"
    );

    fs::remove_file(db_path).expect("should clean up temp db");
}
