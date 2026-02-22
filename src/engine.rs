use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::str::FromStr;

use crate::types::{EngineAnalysis, EngineError, EngineLine};
use shakmaty::uci::UciMove;
use shakmaty::{CastlingMode, Chess, Position, fen::Fen, san::San};

#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedInfoLine {
    depth: Option<u32>,
    score_cp: Option<i32>,
    score_mate: Option<i32>,
    pv: Vec<String>,
    multipv: u32,
}

pub struct EngineSession {
    child: Child,
    stdin: ChildStdin,
    reader: BufReader<ChildStdout>,
}

fn send_uci_command(stdin: &mut ChildStdin, command: &str) -> Result<(), EngineError> {
    writeln!(stdin, "{command}")?;
    stdin.flush()?;
    Ok(())
}

fn wait_for_uci_token(
    reader: &mut BufReader<ChildStdout>,
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

fn better_info(candidate: &ParsedInfoLine, current: &ParsedInfoLine) -> bool {
    let candidate_depth = candidate.depth.unwrap_or(0);
    let current_depth = current.depth.unwrap_or(0);
    candidate_depth > current_depth
        || (candidate_depth == current_depth && !candidate.pv.is_empty() && current.pv.is_empty())
}

fn normalized_depth(depth: u32) -> u32 {
    if depth == 0 { 18 } else { depth }
}

fn normalized_multipv(multipv: u32) -> u32 {
    multipv.clamp(1, 10)
}

fn pv_uci_to_san(fen: &str, pv: &[String]) -> Vec<String> {
    let parsed_fen = match Fen::from_str(fen) {
        Ok(value) => value,
        Err(_) => return Vec::new(),
    };

    let mut position: Chess = match parsed_fen.into_position(CastlingMode::Standard) {
        Ok(value) => value,
        Err(_) => return Vec::new(),
    };

    let mut san_tokens: Vec<String> = Vec::new();

    for uci in pv {
        let parsed_uci = match UciMove::from_ascii(uci.as_bytes()) {
            Ok(value) => value,
            Err(_) => break,
        };

        let mv = match parsed_uci.to_move(&position) {
            Ok(value) => value,
            Err(_) => break,
        };

        let san = San::from_move(&position, mv).to_string();
        san_tokens.push(san);
        position.play_unchecked(mv);
    }

    san_tokens
}

fn spawn_engine(engine_path: &str) -> Result<Child, EngineError> {
    Command::new(engine_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|err| EngineError::Spawn(format!("failed to start engine '{engine_path}': {err}")))
}

fn collect_analysis_result(
    reader: &mut BufReader<ChildStdout>,
    fen: &str,
    requested_depth: u32,
    requested_multipv: u32,
) -> Result<EngineAnalysis, EngineError> {
    let mut best_by_rank: BTreeMap<u32, ParsedInfoLine> = BTreeMap::new();
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
            if info.multipv == 0 || info.multipv > requested_multipv {
                continue;
            }

            let should_update = match best_by_rank.get(&info.multipv) {
                Some(current) => better_info(&info, current),
                None => true,
            };
            if should_update {
                best_by_rank.insert(info.multipv, info);
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

    if best_by_rank.is_empty() {
        return Err(EngineError::Protocol(
            "engine returned no analysis info for this position".to_string(),
        ));
    }

    let mut lines: Vec<EngineLine> = best_by_rank
        .into_iter()
        .map(|(rank, info)| {
            let san_pv = pv_uci_to_san(fen, &info.pv);
            EngineLine {
                multipv_rank: rank,
                depth: info.depth.unwrap_or(requested_depth),
                score_cp: info.score_cp,
                score_mate: info.score_mate,
                pv: info.pv,
                san_pv,
            }
        })
        .collect();
    lines.sort_by_key(|line| line.multipv_rank);

    let primary = lines
        .iter()
        .find(|line| line.multipv_rank == 1)
        .or_else(|| lines.first())
        .ok_or_else(|| {
            EngineError::Protocol("engine returned no analysis info for this position".to_string())
        })?;

    let bestmove = primary
        .san_pv
        .first()
        .cloned()
        .or(bestmove)
        .or_else(|| primary.pv.first().cloned());

    Ok(EngineAnalysis {
        depth: primary.depth,
        score_cp: primary.score_cp,
        score_mate: primary.score_mate,
        bestmove,
        pv: primary.pv.clone(),
        lines,
    })
}

fn analyze_with_engine_io(
    stdin: &mut ChildStdin,
    reader: &mut BufReader<ChildStdout>,
    fen: &str,
    depth: u32,
    multipv: u32,
) -> Result<EngineAnalysis, EngineError> {
    let depth = normalized_depth(depth);
    let multipv = normalized_multipv(multipv);
    send_uci_command(stdin, &format!("setoption name MultiPV value {multipv}"))?;
    send_uci_command(stdin, "isready")?;
    wait_for_uci_token(reader, "readyok", 20_000)?;
    send_uci_command(stdin, &format!("position fen {fen}"))?;
    send_uci_command(stdin, &format!("go depth {depth}"))?;
    collect_analysis_result(reader, fen, depth, multipv)
}

impl EngineSession {
    pub fn start(engine_path: &str) -> Result<Self, EngineError> {
        let mut child = spawn_engine(engine_path)?;
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

        Ok(Self {
            child,
            stdin,
            reader,
        })
    }

    pub fn analyze(&mut self, fen: &str, depth: u32) -> Result<EngineAnalysis, EngineError> {
        analyze_with_engine_io(&mut self.stdin, &mut self.reader, fen, depth, 1)
    }

    pub fn analyze_multipv(
        &mut self,
        fen: &str,
        depth: u32,
        multipv: u32,
    ) -> Result<EngineAnalysis, EngineError> {
        analyze_with_engine_io(&mut self.stdin, &mut self.reader, fen, depth, multipv)
    }
}

impl Drop for EngineSession {
    fn drop(&mut self) {
        let _ = send_uci_command(&mut self.stdin, "quit");
        let _ = self.child.wait();
    }
}

pub fn analyze_position(
    engine_path: &str,
    fen: &str,
    depth: u32,
) -> Result<EngineAnalysis, EngineError> {
    analyze_position_multipv(engine_path, fen, depth, 1)
}

pub fn analyze_position_multipv(
    engine_path: &str,
    fen: &str,
    depth: u32,
    multipv: u32,
) -> Result<EngineAnalysis, EngineError> {
    let mut session = EngineSession::start(engine_path)?;
    session.analyze_multipv(fen, depth, multipv)
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
