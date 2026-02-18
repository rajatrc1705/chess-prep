use pgn_reader::SanPlus;
use rusqlite::{Connection, params};
use shakmaty::uci::UciMove;
use shakmaty::{Chess, EnPassantMode, Position, fen::Fen};

use crate::types::{ReplayError, ReplayTimeline};

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
