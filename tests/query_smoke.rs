use chess_prep::{
    GameFilter, GameResultFilter, Pagination, QueryError, count_games, init_db, search_games,
};
use rusqlite::{Connection, params};
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
        "chess_prep_query_test_{pid}_{nanos}_{counter}.sqlite"
    ))
}

fn seed_db(path: &str) {
    let conn = Connection::open(path).expect("should open seeded db");
    let games = [
        (
            "Training Match",
            "Berlin",
            "2024.01.01",
            "Alice",
            "Bob",
            "1-0",
            "C20",
        ),
        (
            "Training Match",
            "Berlin",
            "2024.01.02",
            "Carol",
            "Dave",
            "0-1",
            "B01",
        ),
        (
            "World Championship",
            "Singapore",
            "2024.11.22",
            "Magnus Carlsen",
            "Ian Nepomniachtchi",
            "1-0",
            "C84",
        ),
        (
            "Candidates",
            "Toronto",
            "2024.11.22",
            "Fabiano Caruana",
            "Ding Liren",
            "1/2-1/2",
            "D37",
        ),
        (
            "Archive",
            "Unknown",
            "2024.??.??",
            "Old Player",
            "Legacy",
            "*",
            "A00",
        ),
        (
            "Archive",
            "Nowhere",
            "????.??.??",
            "Mystery",
            "Ghost",
            "1-0",
            "E00",
        ),
        (
            "Tata Steel",
            "Wijk aan Zee",
            "2025.02.10",
            "Gukesh D",
            "Praggnanandhaa R",
            "1-0",
            "E32",
        ),
    ];

    for game in games {
        conn.execute(
            "
            INSERT INTO games (event, site, date, white, black, result, eco, pgn)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, NULL)
            ",
            params![game.0, game.1, game.2, game.3, game.4, game.5, game.6],
        )
        .expect("should insert seeded game");
    }
}

fn with_seeded_db(test: impl FnOnce(&str)) {
    let db_path = unique_temp_db_path();
    let db_path_str = db_path.to_str().expect("db path should be valid UTF-8");

    init_db(db_path_str).expect("init_db should create schema");
    seed_db(db_path_str);
    test(db_path_str);

    fs::remove_file(db_path).expect("should clean up temp db");
}

#[test]
fn search_text_matches_across_fields_case_insensitively() {
    with_seeded_db(|db_path| {
        let mut filter = GameFilter {
            search_text: Some("singapore".to_string()),
            ..GameFilter::default()
        };

        let by_site =
            search_games(db_path, &filter, Pagination::default()).expect("search should work");
        assert_eq!(by_site.len(), 1);
        assert_eq!(by_site[0].white.as_deref(), Some("Magnus Carlsen"));

        filter.search_text = Some("carlsen".to_string());
        let by_player =
            search_games(db_path, &filter, Pagination::default()).expect("search should work");
        assert_eq!(by_player.len(), 1);
        assert_eq!(by_player[0].site.as_deref(), Some("Singapore"));
    });
}

#[test]
fn result_filter_returns_expected_games() {
    with_seeded_db(|db_path| {
        let filter = GameFilter {
            result: GameResultFilter::BlackWin,
            ..GameFilter::default()
        };

        let games =
            search_games(db_path, &filter, Pagination::default()).expect("search should work");
        assert_eq!(games.len(), 1);
        assert_eq!(games[0].white.as_deref(), Some("Carol"));
        assert_eq!(games[0].result.as_deref(), Some("0-1"));
    });
}

#[test]
fn eco_filter_is_case_insensitive_substring() {
    with_seeded_db(|db_path| {
        let filter = GameFilter {
            eco: Some("c8".to_string()),
            ..GameFilter::default()
        };

        let games =
            search_games(db_path, &filter, Pagination::default()).expect("search should work");
        assert_eq!(games.len(), 1);
        assert_eq!(games[0].eco.as_deref(), Some("C84"));
    });
}

#[test]
fn event_or_site_filter_matches_combined_fields() {
    with_seeded_db(|db_path| {
        let filter = GameFilter {
            event_or_site: Some("wijk".to_string()),
            ..GameFilter::default()
        };

        let games =
            search_games(db_path, &filter, Pagination::default()).expect("search should work");
        assert_eq!(games.len(), 1);
        assert_eq!(games[0].event.as_deref(), Some("Tata Steel"));
    });
}

#[test]
fn date_range_uses_strict_full_date_policy() {
    with_seeded_db(|db_path| {
        let filter = GameFilter {
            date_from: Some("2024.01.01".to_string()),
            date_to: Some("2024.12.31".to_string()),
            ..GameFilter::default()
        };

        let games =
            search_games(db_path, &filter, Pagination::default()).expect("search should work");
        assert_eq!(games.len(), 4);
        assert!(games.iter().all(|g| {
            let date = g.date.as_deref().unwrap_or_default();
            date != "2024.??.??" && date != "????.??.??"
        }));
    });
}

#[test]
fn combined_filters_intersect_results() {
    with_seeded_db(|db_path| {
        let filter = GameFilter {
            search_text: Some("training".to_string()),
            result: GameResultFilter::WhiteWin,
            ..GameFilter::default()
        };

        let games =
            search_games(db_path, &filter, Pagination::default()).expect("search should work");
        assert_eq!(games.len(), 1);
        assert_eq!(games[0].white.as_deref(), Some("Alice"));
    });
}

#[test]
fn deterministic_sort_uses_rowid_tie_break_for_same_date() {
    with_seeded_db(|db_path| {
        let filter = GameFilter {
            date_from: Some("2024.11.22".to_string()),
            date_to: Some("2024.11.22".to_string()),
            ..GameFilter::default()
        };

        let games =
            search_games(db_path, &filter, Pagination::default()).expect("search should work");
        assert_eq!(games.len(), 2);
        assert_eq!(games[0].white.as_deref(), Some("Fabiano Caruana"));
        assert_eq!(games[1].white.as_deref(), Some("Magnus Carlsen"));
    });
}

#[test]
fn pagination_and_count_are_consistent() {
    with_seeded_db(|db_path| {
        let filter = GameFilter {
            date_from: Some("2024.01.01".to_string()),
            date_to: Some("2025.12.31".to_string()),
            ..GameFilter::default()
        };

        let total = count_games(db_path, &filter).expect("count should work");
        assert_eq!(total, 5);

        let page1 = search_games(
            db_path,
            &filter,
            Pagination {
                limit: 2,
                offset: 0,
            },
        )
        .expect("page 1 should work");
        let page2 = search_games(
            db_path,
            &filter,
            Pagination {
                limit: 2,
                offset: 2,
            },
        )
        .expect("page 2 should work");

        assert_eq!(page1.len(), 2);
        assert_eq!(page2.len(), 2);
        assert_eq!(page1[0].white.as_deref(), Some("Gukesh D"));
        assert_eq!(page1[1].white.as_deref(), Some("Fabiano Caruana"));
        assert_eq!(page2[0].white.as_deref(), Some("Magnus Carlsen"));
        assert_eq!(page2[1].white.as_deref(), Some("Carol"));

        assert!(
            page1
                .iter()
                .all(|g| page2.iter().all(|other| g.id != other.id))
        );
    });
}

#[test]
fn invalid_date_format_returns_error() {
    with_seeded_db(|db_path| {
        let filter = GameFilter {
            date_from: Some("2024-01-01".to_string()),
            ..GameFilter::default()
        };

        let err = search_games(db_path, &filter, Pagination::default())
            .expect_err("invalid date should fail search");
        assert!(matches!(
            err,
            QueryError::InvalidDateFormat {
                field: "date_from",
                ..
            }
        ));

        let err = count_games(db_path, &filter).expect_err("invalid date should fail count");
        assert!(matches!(
            err,
            QueryError::InvalidDateFormat {
                field: "date_from",
                ..
            }
        ));
    });
}
