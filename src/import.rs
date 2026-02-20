use std::io::{BufRead, BufReader, Cursor, Read};
use std::ops::ControlFlow;
use std::process::{Child, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

use pgn_reader::{RawTag, Reader, SanPlus, Visitor};
use rusqlite::{Connection, Result as SqlResult, params};

use crate::types::{ImportError, ImportSummary};

const PROGRESS_EMIT_GAMES_INTERVAL: usize = 1_000;
const PROGRESS_EMIT_TIME_INTERVAL: Duration = Duration::from_millis(300);

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
struct SingleGameCollector;

impl Visitor for SingleGameCollector {
    type Tags = GameHeaders;
    type Movetext = GameHeaders;
    type Output = GameHeaders;

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
        movetext
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

fn ensure_exact_dedupe_index(tx: &rusqlite::Transaction<'_>) -> SqlResult<()> {
    tx.execute_batch(
        "
        CREATE UNIQUE INDEX IF NOT EXISTS idx_games_exact_unique
        ON games(
            COALESCE(event, ''),
            COALESCE(site, ''),
            COALESCE(date, ''),
            COALESCE(white, ''),
            COALESCE(black, ''),
            COALESCE(result, ''),
            COALESCE(eco, ''),
            COALESCE(TRIM(pgn), '')
        );
        ",
    )
}

struct ZstdProcessReader {
    child: Option<Child>,
    stdout: ChildStdout,
    eof_validated: bool,
}

impl Read for ZstdProcessReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.eof_validated {
            return Ok(0);
        }

        let bytes_read = self.stdout.read(buf)?;
        if bytes_read > 0 {
            return Ok(bytes_read);
        }

        if let Some(mut child) = self.child.take() {
            let status = child.wait()?;
            if !status.success() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!("zstd failed with status {status}"),
                ));
            }
        }

        self.eof_validated = true;
        Ok(0)
    }
}

impl Drop for ZstdProcessReader {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn open_pgn_reader(pgn_path: &str) -> std::result::Result<Box<dyn Read>, ImportError> {
    if pgn_path.to_ascii_lowercase().ends_with(".zst") {
        let mut child = Command::new("zstd")
            .arg("-d")
            .arg("-c")
            .arg(pgn_path)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| std::io::Error::other("failed to capture zstd stdout pipe"))?;

        return Ok(Box::new(ZstdProcessReader {
            child: Some(child),
            stdout,
            eof_validated: false,
        }));
    }

    let file = std::fs::File::open(pgn_path)?;
    Ok(Box::new(file))
}

fn parse_game_chunk(chunk: &str) -> std::io::Result<GameHeaders> {
    let cursor = Cursor::new(chunk.as_bytes());
    let mut reader = Reader::new(cursor);
    let mut collector = SingleGameCollector;

    match reader.read_game(&mut collector)? {
        Some(game) => Ok(game),
        None => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "chunk did not contain a PGN game",
        )),
    }
}

fn ingest_game_chunk(
    insert_stmt: &mut rusqlite::Statement<'_>,
    chunk: &str,
    summary: &mut ImportSummary,
) -> std::result::Result<(), ImportError> {
    summary.total += 1;

    match parse_game_chunk(chunk) {
        Ok(game) => {
            let movetext = game.movetext.trim();
            let movetext = if movetext.is_empty() {
                None
            } else {
                Some(movetext)
            };

            let inserted_rows = insert_stmt.execute(params![
                game.event.as_deref(),
                game.site.as_deref(),
                game.date.as_deref(),
                game.white.as_deref(),
                game.black.as_deref(),
                game.result.as_deref(),
                game.eco.as_deref(),
                movetext
            ])?;

            if inserted_rows == 1 {
                summary.inserted += 1;
            } else {
                summary.skipped += 1;
            }
        }
        Err(_) => {
            summary.errors += 1;
        }
    }

    Ok(())
}

fn maybe_emit_progress<F>(summary: ImportSummary, last_emit: &mut Instant, on_progress: &mut F)
where
    F: FnMut(ImportSummary),
{
    if summary.total == 0 {
        return;
    }

    if summary.total.is_multiple_of(PROGRESS_EMIT_GAMES_INTERVAL)
        || last_emit.elapsed() >= PROGRESS_EMIT_TIME_INTERVAL
    {
        on_progress(summary);
        *last_emit = Instant::now();
    }
}

pub fn import_pgn_file(
    db_path: &str,
    pgn_path: &str,
) -> std::result::Result<ImportSummary, ImportError> {
    import_pgn_file_with_progress(db_path, pgn_path, |_| {})
}

pub fn import_pgn_file_with_progress<F>(
    db_path: &str,
    pgn_path: &str,
    mut on_progress: F,
) -> std::result::Result<ImportSummary, ImportError>
where
    F: FnMut(ImportSummary),
{
    let mut conn = Connection::open(db_path)?;
    let reader = open_pgn_reader(pgn_path)?;
    let mut reader = BufReader::new(reader);

    let tx = conn.transaction()?;
    let _ = cleanup_exact_duplicate_rows(&tx)?;
    ensure_exact_dedupe_index(&tx)?;

    let mut insert_stmt = tx.prepare(
        "
        INSERT OR IGNORE INTO games (event, site, date, white, black, result, eco, pgn)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ",
    )?;

    let mut summary = ImportSummary::default();
    on_progress(summary);
    let mut last_emit = Instant::now();

    let mut chunk = String::new();
    let mut line = String::new();
    loop {
        line.clear();
        let bytes_read = reader.read_line(&mut line)?;
        if bytes_read == 0 {
            if !chunk.trim().is_empty() {
                ingest_game_chunk(&mut insert_stmt, &chunk, &mut summary)?;
                maybe_emit_progress(summary, &mut last_emit, &mut on_progress);
            }
            break;
        }

        if line.starts_with("[Event ") && !chunk.trim().is_empty() {
            ingest_game_chunk(&mut insert_stmt, &chunk, &mut summary)?;
            maybe_emit_progress(summary, &mut last_emit, &mut on_progress);
            chunk.clear();
        }

        chunk.push_str(&line);
    }

    let _ = cleanup_stale_empty_movetext_rows(&tx)?;
    let _ = cleanup_exact_duplicate_rows(&tx)?;
    ensure_exact_dedupe_index(&tx)?;
    drop(insert_stmt);
    tx.commit()?;

    on_progress(summary);
    Ok(summary)
}
