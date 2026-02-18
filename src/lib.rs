use std::io::{BufRead, BufReader, Write};
use std::ops::ControlFlow;
use std::process::{Command, Stdio};

use pgn_reader::{RawTag, Reader, SanPlus, Visitor};
use rusqlite::{Connection, Result as SqlResult, params, params_from_iter, types::Value};
use shakmaty::uci::UciMove;
use shakmaty::{Chess, EnPassantMode, Position, fen::Fen};

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

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum GameResultFilter {
    #[default]
    Any,
    WhiteWin,
    BlackWin,
    Draw,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct GameFilter {
    pub search_text: Option<String>,
    pub result: GameResultFilter,
    pub eco: Option<String>,
    pub event_or_site: Option<String>,
    pub date_from: Option<String>,
    pub date_to: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pagination {
    pub limit: u32,
    pub offset: u32,
}

impl Default for Pagination {
    fn default() -> Self {
        Self {
            limit: 50,
            offset: 0,
        }
    }
}

impl Pagination {
    const MAX_LIMIT: u32 = 500;

    fn normalized(self) -> Self {
        let limit = if self.limit == 0 {
            Self::default().limit
        } else {
            self.limit.min(Self::MAX_LIMIT)
        };
        Self {
            limit,
            offset: self.offset,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GameRow {
    pub id: i64,
    pub event: Option<String>,
    pub site: Option<String>,
    pub date: Option<String>,
    pub white: Option<String>,
    pub black: Option<String>,
    pub result: Option<String>,
    pub eco: Option<String>,
}

#[derive(Debug)]
pub enum QueryError {
    Sql(rusqlite::Error),
    InvalidDateFormat { field: &'static str, value: String },
    CountOverflow(i64),
}

#[derive(Debug)]
pub enum ReplayError {
    Sql(rusqlite::Error),
    GameNotFound(i64),
    MissingMovetext(i64),
    InvalidSan { ply: usize, san: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplayTimeline {
    pub fens: Vec<String>,
    pub sans: Vec<String>,
    pub ucis: Vec<String>,
}

#[derive(Debug)]
pub enum EngineError {
    Io(std::io::Error),
    Spawn(String),
    Protocol(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineAnalysis {
    pub depth: u32,
    pub score_cp: Option<i32>,
    pub score_mate: Option<i32>,
    pub bestmove: Option<String>,
    pub pv: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedInfoLine {
    depth: Option<u32>,
    score_cp: Option<i32>,
    score_mate: Option<i32>,
    pv: Vec<String>,
    multipv: u32,
}

impl From<std::io::Error> for ImportError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<std::io::Error> for EngineError {
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

impl From<rusqlite::Error> for ImportError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Sql(value)
    }
}

impl From<rusqlite::Error> for QueryError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Sql(value)
    }
}

impl From<rusqlite::Error> for ReplayError {
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

fn normalized_filter_text(input: &Option<String>) -> Option<String> {
    let raw = input.as_ref()?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_owned())
    }
}

fn validate_date_input(field: &'static str, value: &str) -> Result<(), QueryError> {
    let bytes = value.as_bytes();
    let valid = bytes.len() == 10
        && bytes[4] == b'.'
        && bytes[7] == b'.'
        && bytes
            .iter()
            .enumerate()
            .all(|(index, ch)| index == 4 || index == 7 || ch.is_ascii_digit());

    if valid {
        Ok(())
    } else {
        Err(QueryError::InvalidDateFormat {
            field,
            value: value.to_owned(),
        })
    }
}

fn build_where_clause(filter: &GameFilter) -> Result<(String, Vec<Value>), QueryError> {
    let mut clauses = Vec::new();
    let mut values = Vec::new();

    if let Some(search_text) = normalized_filter_text(&filter.search_text) {
        clauses.push(
            "LOWER(COALESCE(white, '') || ' ' || COALESCE(black, '') || ' ' || COALESCE(event, '') || ' ' || COALESCE(site, '')) LIKE LOWER(?)",
        );
        values.push(Value::Text(format!("%{search_text}%")));
    }

    match filter.result {
        GameResultFilter::Any => {}
        GameResultFilter::WhiteWin => {
            clauses.push("result = ?");
            values.push(Value::Text("1-0".to_string()));
        }
        GameResultFilter::BlackWin => {
            clauses.push("result = ?");
            values.push(Value::Text("0-1".to_string()));
        }
        GameResultFilter::Draw => {
            clauses.push("result = ?");
            values.push(Value::Text("1/2-1/2".to_string()));
        }
    }

    if let Some(eco) = normalized_filter_text(&filter.eco) {
        clauses.push("LOWER(COALESCE(eco, '')) LIKE LOWER(?)");
        values.push(Value::Text(format!("%{eco}%")));
    }

    if let Some(event_or_site) = normalized_filter_text(&filter.event_or_site) {
        clauses.push("LOWER(COALESCE(event, '') || ' ' || COALESCE(site, '')) LIKE LOWER(?)");
        values.push(Value::Text(format!("%{event_or_site}%")));
    }

    let date_from = normalized_filter_text(&filter.date_from);
    let date_to = normalized_filter_text(&filter.date_to);
    let has_date_filter = date_from.is_some() || date_to.is_some();

    if has_date_filter {
        clauses.push("date GLOB '[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]'");
    }

    if let Some(date_from) = date_from {
        validate_date_input("date_from", &date_from)?;
        clauses.push("date >= ?");
        values.push(Value::Text(date_from));
    }

    if let Some(date_to) = date_to {
        validate_date_input("date_to", &date_to)?;
        clauses.push("date <= ?");
        values.push(Value::Text(date_to));
    }

    let where_clause = if clauses.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", clauses.join(" AND "))
    };

    Ok((where_clause, values))
}

pub fn search_games(
    db_path: &str,
    filter: &GameFilter,
    page: Pagination,
) -> Result<Vec<GameRow>, QueryError> {
    let conn = Connection::open(db_path)?;
    let (where_clause, mut values) = build_where_clause(filter)?;
    let page = page.normalized();

    let sql = format!(
        "
        SELECT rowid, event, site, date, white, black, result, eco
        FROM games
        {where_clause}
        ORDER BY date DESC, rowid DESC
        LIMIT ? OFFSET ?
        "
    );

    values.push(Value::Integer(i64::from(page.limit)));
    values.push(Value::Integer(i64::from(page.offset)));

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(values.iter()), |row| {
        Ok(GameRow {
            id: row.get(0)?,
            event: row.get(1)?,
            site: row.get(2)?,
            date: row.get(3)?,
            white: row.get(4)?,
            black: row.get(5)?,
            result: row.get(6)?,
            eco: row.get(7)?,
        })
    })?;

    let mut games = Vec::new();
    for row in rows {
        games.push(row?);
    }
    Ok(games)
}

pub fn count_games(db_path: &str, filter: &GameFilter) -> Result<u64, QueryError> {
    let conn = Connection::open(db_path)?;
    let (where_clause, values) = build_where_clause(filter)?;

    let sql = format!(
        "
        SELECT COUNT(*)
        FROM games
        {where_clause}
        "
    );

    let count: i64 = conn.query_row(&sql, params_from_iter(values.iter()), |row| row.get(0))?;
    u64::try_from(count).map_err(|_| QueryError::CountOverflow(count))
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

pub fn replay_game(db_path: &str, game_id: i64) -> Result<ReplayTimeline, ReplayError> {
    let conn = Connection::open(db_path)?;
    let movetext: Option<String> = match conn.query_row(
        "SELECT pgn FROM games WHERE rowid = ?1",
        params![game_id],
        |row| row.get(0),
    ) {
        Ok(value) => value,
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            return Err(ReplayError::GameNotFound(game_id));
        }
        Err(err) => return Err(ReplayError::Sql(err)),
    };

    let movetext = movetext.ok_or(ReplayError::MissingMovetext(game_id))?;
    if movetext.trim().is_empty() {
        return Err(ReplayError::MissingMovetext(game_id));
    }

    let mut position = Chess::default();
    let mut fens = vec![Fen::from_position(&position, EnPassantMode::Legal).to_string()];
    let mut sans = Vec::new();
    let mut ucis = Vec::new();

    for (index, token) in movetext.split_whitespace().enumerate() {
        let san = token.to_owned();
        let san_plus =
            SanPlus::from_ascii(san.as_bytes()).map_err(|_| ReplayError::InvalidSan {
                ply: index + 1,
                san: san.clone(),
            })?;
        let mv = san_plus
            .san
            .to_move(&position)
            .map_err(|_| ReplayError::InvalidSan {
                ply: index + 1,
                san: san.clone(),
            })?;
        let uci = UciMove::from_move(mv, position.castles().mode()).to_string();
        position.play_unchecked(mv);
        fens.push(Fen::from_position(&position, EnPassantMode::Legal).to_string());
        sans.push(san);
        ucis.push(uci);
    }

    Ok(ReplayTimeline { fens, sans, ucis })
}

pub fn replay_game_fens(db_path: &str, game_id: i64) -> Result<Vec<String>, ReplayError> {
    replay_game(db_path, game_id).map(|timeline| timeline.fens)
}

fn send_uci_command(
    stdin: &mut std::process::ChildStdin,
    command: &str,
) -> Result<(), EngineError> {
    writeln!(stdin, "{command}")?;
    stdin.flush()?;
    Ok(())
}

fn wait_for_uci_token(
    reader: &mut BufReader<std::process::ChildStdout>,
    token: &str,
    max_lines: usize,
) -> Result<(), EngineError> {
    let mut line = String::new();
    for _ in 0..max_lines {
        line.clear();
        let bytes = reader.read_line(&mut line)?;
        if bytes == 0 {
            return Err(EngineError::Protocol(format!(
                "engine closed output while waiting for '{token}'"
            )));
        }
        if line.trim() == token {
            return Ok(());
        }
    }

    Err(EngineError::Protocol(format!(
        "did not receive '{token}' from engine"
    )))
}

fn parse_info_line(line: &str) -> Option<ParsedInfoLine> {
    if !line.starts_with("info ") {
        return None;
    }

    let tokens: Vec<&str> = line.split_whitespace().collect();
    let mut depth = None;
    let mut score_cp = None;
    let mut score_mate = None;
    let mut pv: Vec<String> = Vec::new();
    let mut multipv = 1u32;

    let mut index = 0usize;
    while index < tokens.len() {
        match tokens[index] {
            "depth" => {
                if let Some(next) = tokens.get(index + 1)
                    && let Ok(value) = next.parse::<u32>()
                {
                    depth = Some(value);
                }
                index += 2;
            }
            "multipv" => {
                if let Some(next) = tokens.get(index + 1)
                    && let Ok(value) = next.parse::<u32>()
                {
                    multipv = value;
                }
                index += 2;
            }
            "score" => {
                let kind = tokens.get(index + 1).copied();
                let value = tokens.get(index + 2).copied();
                if let (Some(kind), Some(value)) = (kind, value) {
                    if kind == "cp" {
                        score_cp = value.parse::<i32>().ok();
                    } else if kind == "mate" {
                        score_mate = value.parse::<i32>().ok();
                    }
                }
                index += 3;
            }
            "pv" => {
                if index + 1 < tokens.len() {
                    pv = tokens[index + 1..]
                        .iter()
                        .map(|token| (*token).to_owned())
                        .collect();
                }
                break;
            }
            _ => index += 1,
        }
    }

    if depth.is_none() && score_cp.is_none() && score_mate.is_none() && pv.is_empty() {
        None
    } else {
        Some(ParsedInfoLine {
            depth,
            score_cp,
            score_mate,
            pv,
            multipv,
        })
    }
}

fn better_info(candidate: &ParsedInfoLine, best: &Option<ParsedInfoLine>) -> bool {
    if candidate.multipv != 1 {
        return false;
    }

    match best {
        None => true,
        Some(current) => {
            let candidate_depth = candidate.depth.unwrap_or(0);
            let current_depth = current.depth.unwrap_or(0);
            candidate_depth > current_depth
                || (candidate_depth == current_depth
                    && !candidate.pv.is_empty()
                    && current.pv.is_empty())
        }
    }
}

pub fn analyze_position(
    engine_path: &str,
    fen: &str,
    depth: u32,
) -> Result<EngineAnalysis, EngineError> {
    let depth = if depth == 0 { 18 } else { depth };

    let mut child = Command::new(engine_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|err| {
            EngineError::Spawn(format!("failed to start engine '{engine_path}': {err}"))
        })?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| EngineError::Protocol("engine stdin is unavailable".to_string()))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| EngineError::Protocol("engine stdout is unavailable".to_string()))?;
    let mut reader = BufReader::new(stdout);

    send_uci_command(&mut stdin, "uci")?;
    wait_for_uci_token(&mut reader, "uciok", 20_000)?;

    send_uci_command(&mut stdin, "isready")?;
    wait_for_uci_token(&mut reader, "readyok", 20_000)?;

    send_uci_command(&mut stdin, "ucinewgame")?;
    send_uci_command(&mut stdin, &format!("position fen {fen}"))?;
    send_uci_command(&mut stdin, &format!("go depth {depth}"))?;

    let mut best: Option<ParsedInfoLine> = None;
    let mut bestmove: Option<String> = None;
    let mut line = String::new();

    for _ in 0..50_000 {
        line.clear();
        let bytes = reader.read_line(&mut line)?;
        if bytes == 0 {
            return Err(EngineError::Protocol(
                "engine closed output before sending bestmove".to_string(),
            ));
        }

        let trimmed = line.trim();
        if let Some(info) = parse_info_line(trimmed) {
            if better_info(&info, &best) {
                best = Some(info);
            }
            continue;
        }

        if trimmed.starts_with("bestmove") {
            let tokens: Vec<&str> = trimmed.split_whitespace().collect();
            if let Some(token) = tokens.get(1)
                && *token != "(none)"
            {
                bestmove = Some((*token).to_owned());
            }
            break;
        }
    }

    let _ = send_uci_command(&mut stdin, "quit");
    let _ = child.wait();

    let best = best.ok_or_else(|| {
        EngineError::Protocol("engine returned no analysis info for this position".to_string())
    })?;

    Ok(EngineAnalysis {
        depth: best.depth.unwrap_or(depth),
        score_cp: best.score_cp,
        score_mate: best.score_mate,
        bestmove,
        pv: best.pv,
    })
}

#[cfg(test)]
mod engine_tests {
    use super::parse_info_line;

    #[test]
    fn parse_info_line_cp_and_pv() {
        let line = "info depth 16 seldepth 22 multipv 1 score cp 34 nodes 11111 nps 200000 pv e2e4 e7e5 g1f3";
        let parsed = parse_info_line(line).expect("line should parse");
        assert_eq!(parsed.depth, Some(16));
        assert_eq!(parsed.score_cp, Some(34));
        assert_eq!(parsed.score_mate, None);
        assert_eq!(parsed.pv, vec!["e2e4", "e7e5", "g1f3"]);
        assert_eq!(parsed.multipv, 1);
    }

    #[test]
    fn parse_info_line_mate() {
        let line = "info depth 21 score mate -3 pv h7h8q";
        let parsed = parse_info_line(line).expect("line should parse");
        assert_eq!(parsed.depth, Some(21));
        assert_eq!(parsed.score_cp, None);
        assert_eq!(parsed.score_mate, Some(-3));
        assert_eq!(parsed.pv, vec!["h7h8q"]);
    }
}
