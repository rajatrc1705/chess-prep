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

    pub(crate) fn normalized(self) -> Self {
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
