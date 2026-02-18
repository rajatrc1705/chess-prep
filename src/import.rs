use std::ops::ControlFlow;

use pgn_reader::{RawTag, Reader, SanPlus, Visitor};
use rusqlite::{Connection, Result as SqlResult, params};

use crate::types::{ImportError, ImportSummary};

#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct GameHeaders {
    event: Option<String>,
    site: Option<String>,
    date: Option<String>,
    white: Option<String>,
    black: Option<String>,
    result: Option<String>,
    eco: Option<String>,
    movetext: String,
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

    fn san(
        &mut self,
        movetext: &mut Self::Movetext,
        san_plus: SanPlus,
    ) -> ControlFlow<Self::Output> {
        if !movetext.movetext.is_empty() {
            movetext.movetext.push(' ');
        }
        movetext.movetext.push_str(&san_plus.to_string());
        ControlFlow::Continue(())
    }

    fn end_game(&mut self, movetext: Self::Movetext) -> Self::Output {
        self.games.push(movetext);
    }
}

fn cleanup_stale_empty_movetext_rows(tx: &rusqlite::Transaction<'_>) -> SqlResult<usize> {
    tx.execute(
        "
        DELETE FROM games AS stale
        WHERE COALESCE(TRIM(stale.pgn), '') = ''
          AND EXISTS (
              SELECT 1
              FROM games AS fresh
              WHERE fresh.rowid != stale.rowid
                AND COALESCE(TRIM(fresh.pgn), '') <> ''
                AND COALESCE(fresh.event, '') = COALESCE(stale.event, '')
                AND COALESCE(fresh.site, '') = COALESCE(stale.site, '')
                AND COALESCE(fresh.date, '') = COALESCE(stale.date, '')
                AND COALESCE(fresh.white, '') = COALESCE(stale.white, '')
                AND COALESCE(fresh.black, '') = COALESCE(stale.black, '')
                AND COALESCE(fresh.result, '') = COALESCE(stale.result, '')
                AND COALESCE(fresh.eco, '') = COALESCE(stale.eco, '')
          )
        ",
        [],
    )
}

fn cleanup_exact_duplicate_rows(tx: &rusqlite::Transaction<'_>) -> SqlResult<usize> {
    tx.execute(
        "
        DELETE FROM games
        WHERE rowid NOT IN (
            SELECT MIN(rowid)
            FROM games
            GROUP BY
                COALESCE(event, ''),
                COALESCE(site, ''),
                COALESCE(date, ''),
                COALESCE(white, ''),
                COALESCE(black, ''),
                COALESCE(result, ''),
                COALESCE(eco, ''),
                COALESCE(TRIM(pgn), '')
        )
        ",
        [],
    )
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
        let mut insert_stmt = tx.prepare(
            "
            INSERT INTO games (event, site, date, white, black, result, eco, pgn)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            ",
        )?;
        let mut exists_stmt = tx.prepare(
            "
            SELECT 1
            FROM games
            WHERE COALESCE(event, '') = COALESCE(?1, '')
              AND COALESCE(site, '') = COALESCE(?2, '')
              AND COALESCE(date, '') = COALESCE(?3, '')
              AND COALESCE(white, '') = COALESCE(?4, '')
              AND COALESCE(black, '') = COALESCE(?5, '')
              AND COALESCE(result, '') = COALESCE(?6, '')
              AND COALESCE(eco, '') = COALESCE(?7, '')
              AND COALESCE(TRIM(pgn), '') = COALESCE(TRIM(?8), '')
            LIMIT 1
            ",
        )?;

        let mut inserted = 0usize;
        for game in &collector.games {
            let movetext = game.movetext.trim();
            let movetext = if movetext.is_empty() {
                None
            } else {
                Some(movetext)
            };

            let exists = exists_stmt.exists(params![
                game.event.as_deref(),
                game.site.as_deref(),
                game.date.as_deref(),
                game.white.as_deref(),
                game.black.as_deref(),
                game.result.as_deref(),
                game.eco.as_deref(),
                movetext
            ])?;
            if exists {
                continue;
            }

            insert_stmt.execute(params![
                game.event.as_deref(),
                game.site.as_deref(),
                game.date.as_deref(),
                game.white.as_deref(),
                game.black.as_deref(),
                game.result.as_deref(),
                game.eco.as_deref(),
                movetext
            ])?;
            inserted += 1;
        }
        inserted
    };
    let _ = cleanup_stale_empty_movetext_rows(&tx)?;
    let _ = cleanup_exact_duplicate_rows(&tx)?;
    tx.commit()?;

    Ok(ImportSummary {
        total,
        inserted,
        skipped: total.saturating_sub(inserted),
    })
}
