use std::ops::ControlFlow;

use pgn_reader::{RawTag, Reader, Visitor};
use rusqlite::{Connection, Result as SqlResult, params};

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

impl From<std::io::Error> for ImportError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct GameHeaders {
    event: Option<String>,
    site: Option<String>,
    date: Option<String>,
    white: Option<String>,
    black: Option<String>,
    result: Option<String>,
    eco: Option<String>,
}

impl GameHeaders {
    fn set_tag(&mut self, name: &[u8], value: RawTag<'_>) {
        let value = value.decode_utf8_lossy().into_owned();
        match name {
            b"Event" => self.event = Some(value),
            b"Site" => self.site = Some(value),
            b"Date" => self.date = Some(value),
            b"White" => self.white = Some(value),
            b"Black" => self.black = Some(value),
            b"Result" => self.result = Some(value),
            b"ECO" => self.eco = Some(value),
            _ => {}
        }
    }
}

#[derive(Default)]
struct GameCollector {
    games: Vec<GameHeaders>,
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

impl Visitor for GameCollector {
    type Tags = GameHeaders;
    type Movetext = GameHeaders;
    type Output = ();

    fn begin_tags(&mut self) -> ControlFlow<Self::Output, Self::Tags> {
        ControlFlow::Continue(GameHeaders::default())
    }

    fn tag(
        &mut self,
        tags: &mut Self::Tags,
        name: &[u8],
        value: RawTag<'_>,
    ) -> ControlFlow<Self::Output> {
        tags.set_tag(name, value);
        ControlFlow::Continue(())
    }

    fn begin_movetext(&mut self, tags: Self::Tags) -> ControlFlow<Self::Output, Self::Movetext> {
        ControlFlow::Continue(tags)
    }

    fn end_game(&mut self, movetext: Self::Movetext) -> Self::Output {
        self.games.push(movetext);
    }
}

pub fn import_pgn_file(
    db_path: &str,
    pgn_path: &str,
) -> std::result::Result<ImportSummary, ImportError> {
    let mut conn = Connection::open(db_path)?;

    let file = std::fs::File::open(pgn_path)?;
    let mut reader = Reader::new(file);
    let mut collector = GameCollector::default();

    while reader.read_game(&mut collector)?.is_some() {}

    let total = collector.games.len();
    let tx = conn.transaction()?;
    let inserted = {
        let mut stmt = tx.prepare(
            "
            INSERT INTO games (event, site, date, white, black, result, eco, pgn)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ",
        )?;

        let mut inserted = 0usize;
        for game in &collector.games {
            stmt.execute(params![
                game.event.as_deref(),
                game.site.as_deref(),
                game.date.as_deref(),
                game.white.as_deref(),
                game.black.as_deref(),
                game.result.as_deref(),
                game.eco.as_deref(),
                Option::<&str>::None
            ])?;
            inserted += 1;
        }
        inserted
    };
    tx.commit()?;

    Ok(ImportSummary {
        total,
        inserted,
        skipped: total.saturating_sub(inserted),
    })
}
