use std::ops::ControlFlow;

use pgn_reader::{Reader, Visitor};
use rusqlite::{Connection, Result as SqlResult};

#[derive(Debug)]
pub enum ImportError {
    Io(std::io::Error),
    Sql(rusqlite::Error),
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ImportSummary {
    pub total: usize,
    pub inserted: usize,
    pub skipped: usize,
}

// implement From trait;
impl From<std::io::Error> for ImportError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

// # starts an attribute in rust, derive is an attribute that asks rust to auto-generate trait implementations
#[derive(Default)]
struct GameCounter {
    total: usize,
}

impl From<rusqlite::Error> for ImportError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Sql(value)
    }
}

pub fn init_db(path: &str) -> SqlResult<()> {
    let conn = Connection::open(path)?;

    conn.execute_batch(
        "
            CREATE TABLE IF NOT EXISTS games (
                event TEXT,
                site TEXT,
                date TEXT,
                white TEXT,
                black TEXT,
                result TEXT,
                eco TEXT,
                pgn TEXT
                );

                CREATE INDEX IF NOT EXISTS idx_games_white ON games(white);
                CREATE INDEX IF NOT EXISTS idx_games_black ON games(black);
                CREATE INDEX IF NOT EXISTS idx_games_date ON games(date);
                CREATE INDEX IF NOT EXISTS idx_games_result ON games(result);
                CREATE INDEX IF NOT EXISTS idx_games_eco ON games(eco);
                CREATE INDEX IF NOT EXISTS idx_games_event ON games(event);
                CREATE INDEX IF NOT EXISTS idx_games_site ON games(site);
        ",
    )?;

    Ok(())
}

impl Visitor for GameCounter {
    type Tags = ();
    type Movetext = ();
    type Output = ();

    fn begin_tags(&mut self) -> ControlFlow<Self::Output, Self::Tags> {
        ControlFlow::Continue(())
    }

    fn begin_movetext(&mut self, _tags: Self::Tags) -> ControlFlow<Self::Output, Self::Movetext> {
        ControlFlow::Continue(())
    }

    fn end_game(&mut self, _movetext: Self::Movetext) -> Self::Output {
        self.total += 1
    }
}

fn import_pgn_file(
    db_path: &str,
    pgn_path: &str,
) -> std::result::Result<ImportSummary, ImportError> {
    let _conn = Connection::open(db_path)?;

    let file = std::fs::File::open(pgn_path)?;
    let mut reader = Reader::new(file);
    let mut counter = GameCounter::default();

    while reader.read_game(&mut counter)?.is_some() {}

    Ok(ImportSummary {
        total: counter.total,
        inserted: 0,
        skipped: 0,
    })
}
