use std::str::FromStr;

use shakmaty::uci::UciMove;
use shakmaty::{CastlingMode, Chess, EnPassantMode, Position, fen::Fen, san::San};

use crate::types::{AnalysisError, AppliedMove};

// fen is the current position, uci is the candidate move
pub fn apply_uci_to_fen(fen: &str, uci: &str) -> Result<AppliedMove, AnalysisError> {
    // parses fen format correctly
    let parsed_fen = Fen::from_str(fen).map_err(|_| AnalysisError::InvalidFen(fen.to_owned()))?;
    let mut position: Chess = parsed_fen
        .into_position(CastlingMode::Standard)
        .map_err(|_| AnalysisError::InvalidFen(fen.to_owned()))?;

    // checks move legality
    let parsed_uci = UciMove::from_ascii(uci.as_bytes())
        .map_err(|_| AnalysisError::InvalidUci(uci.to_owned()))?;

    // resolves the parsed UCI into an internal Move
    let mv = parsed_uci
        .to_move(&position)
        .map_err(|_| AnalysisError::IllegalMove(uci.to_owned()))?;

    // to be displayed on the frontend
    let san = San::from_move(&position, mv).to_string();
    let canonical_uci = UciMove::from_move(mv, position.castles().mode()).to_string();

    // mutates the position by playing the move
    position.play_unchecked(mv);
    let next_fen = Fen::from_position(&position, EnPassantMode::Legal).to_string();

    Ok(AppliedMove {
        san,
        uci: canonical_uci,
        fen: next_fen,
    })
}

pub fn legal_uci_moves_for_fen(fen: &str) -> Result<Vec<String>, AnalysisError> {
    let parsed_fen = Fen::from_str(fen).map_err(|_| AnalysisError::InvalidFen(fen.to_owned()))?;
    let position: Chess = parsed_fen
        .into_position(CastlingMode::Standard)
        .map_err(|_| AnalysisError::InvalidFen(fen.to_owned()))?;

    let castling_mode = position.castles().mode();
    let legal_moves = position.legal_moves();

    Ok(legal_moves
        .into_iter()
        .map(|mv| UciMove::from_move(mv, castling_mode).to_string())
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_legal_uci_move() {
        let start = "rn1qkbnr/pppbpppp/8/3p4/8/3P4/PPP1PPPP/RNBQKBNR w KQkq - 0 2";
        let out = apply_uci_to_fen(start, "e2e4").expect("legal move");
        assert_eq!(out.uci, "e2e4");
        assert_eq!(out.san, "e4");
        assert!(!out.fen.is_empty());
    }

    #[test]
    fn rejects_invalid_fen() {
        let err = apply_uci_to_fen("not-a-fen", "e2e4").unwrap_err();
        match err {
            AnalysisError::InvalidFen(_) => {}
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn rejects_invalid_uci() {
        let start = "rn1qkbnr/pppbpppp/8/3p4/8/3P4/PPP1PPPP/RNBQKBNR w KQkq - 0 2";
        let err = apply_uci_to_fen(start, "bad").unwrap_err();
        match err {
            AnalysisError::InvalidUci(_) => {}
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn rejects_illegal_uci() {
        let start = "rn1qkbnr/pppbpppp/8/3p4/8/3P4/PPP1PPPP/RNBQKBNR w KQkq - 0 2";
        let err = apply_uci_to_fen(start, "e2e5").unwrap_err();
        match err {
            AnalysisError::IllegalMove(_) => {}
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn legal_moves_include_common_opening_moves() {
        let start = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        let legal_moves = legal_uci_moves_for_fen(start).expect("legal moves");

        assert!(legal_moves.contains(&"e2e4".to_string()));
        assert!(legal_moves.contains(&"g1f3".to_string()));
    }

    #[test]
    fn legal_moves_reject_invalid_fen() {
        let err = legal_uci_moves_for_fen("not-a-fen").unwrap_err();
        match err {
            AnalysisError::InvalidFen(_) => {}
            other => panic!("unexpected error: {other:?}"),
        }
    }
}
