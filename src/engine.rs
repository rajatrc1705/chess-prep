use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

use crate::types::{EngineAnalysis, EngineError};

#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedInfoLine {
    depth: Option<u32>,
    score_cp: Option<i32>,
    score_mate: Option<i32>,
    pv: Vec<String>,
    multipv: u32,
}

fn send_uci_command(stdin: &mut std::process::ChildStdin, command: &str) -> Result<(), EngineError> {
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
                || (candidate_depth == current_depth && !candidate.pv.is_empty() && current.pv.is_empty())
        }
    }
}

pub fn analyze_position(engine_path: &str, fen: &str, depth: u32) -> Result<EngineAnalysis, EngineError> {
    let depth = if depth == 0 { 18 } else { depth };

    let mut child = Command::new(engine_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|err| EngineError::Spawn(format!("failed to start engine '{engine_path}': {err}")))?;

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
