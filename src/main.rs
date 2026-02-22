use chess_prep::{
    AnalysisWorkspaceNode, EngineSession, GameFilter, GameResultFilter, Pagination,
    analyze_position, analyze_position_multipv, apply_uci_to_fen, count_games, import_pgn_file,
    delete_analysis_workspace, import_pgn_file_with_progress, init_analysis_workspace_db, init_db,
    legal_uci_moves_for_fen, list_analysis_workspaces, load_analysis_workspace,
    rename_analysis_workspace, replay_game, replay_game_fens, save_analysis_workspace, search_games,
};

use std::env;
use std::io::{BufRead, Write};

fn print_usage(program: &str) {
    eprintln!("Usage: {program} init <db_path>");
    eprintln!("       {program} import <db_path> <pgn_path>");
    eprintln!("       {program} import <db_path> <pgn_path> --tsv");
    eprintln!(
        "       {program} search <db_path> [--search-text <text>] [--result <any|1-0|0-1|1/2-1/2>] [--eco <text>] [--event-or-site <text>] [--date-from <YYYY.MM.DD>] [--date-to <YYYY.MM.DD>] [--limit <n>] [--offset <n>]"
    );
    eprintln!(
        "       {program} count <db_path> [--search-text <text>] [--result <any|1-0|0-1|1/2-1/2>] [--eco <text>] [--event-or-site <text>] [--date-from <YYYY.MM.DD>] [--date-to <YYYY.MM.DD>]"
    );
    eprintln!("       {program} replay <db_path> <game_id>");
    eprintln!("       {program} replay-meta <db_path> <game_id>");
    eprintln!("       {program} analyze <engine_path> <fen> [--depth <n>]");
    eprintln!("       {program} analyze-multipv <engine_path> <fen> [--depth <n>] [--multipv <n>]");
    eprintln!("       {program} engine-session <engine_path>");
    eprintln!("       {program} apply-uci <fen> <uci>");
    eprintln!("       {program} legal-uci <fen>");
    eprintln!("       {program} analysis-init <analysis_db_path>");
    eprintln!(
        "       {program} analysis-save <analysis_db_path> <source_db_path> <game_id> <workspace_name> <root_node_id> <current_node_id|-> <nodes_tsv_path>"
    );
    eprintln!("       {program} analysis-list <analysis_db_path> <source_db_path> <game_id>");
    eprintln!("       {program} analysis-load <analysis_db_path> <workspace_id>");
    eprintln!("       {program} analysis-rename <analysis_db_path> <workspace_id> <workspace_name>");
    eprintln!("       {program} analysis-delete <analysis_db_path> <workspace_id>");
}

fn parse_result(value: &str) -> Result<GameResultFilter, String> {
    match value {
        "any" => Ok(GameResultFilter::Any),
        "1-0" => Ok(GameResultFilter::WhiteWin),
        "0-1" => Ok(GameResultFilter::BlackWin),
        "1/2-1/2" => Ok(GameResultFilter::Draw),
        _ => Err(format!(
            "invalid result '{value}', expected one of: any, 1-0, 0-1, 1/2-1/2"
        )),
    }
}

fn parse_u32(name: &str, value: &str) -> Result<u32, String> {
    value
        .parse::<u32>()
        .map_err(|_| format!("invalid {name} '{value}', expected a non-negative integer"))
}

fn parse_i64(name: &str, value: &str) -> Result<i64, String> {
    value
        .parse::<i64>()
        .map_err(|_| format!("invalid {name} '{value}', expected an integer"))
}

fn optional_text(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_owned())
    }
}

fn parse_analysis_nodes_tsv(path: &str) -> Result<Vec<AnalysisWorkspaceNode>, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|err| format!("failed to read nodes TSV '{path}': {err}"))?;

    let mut nodes = Vec::new();

    for (line_index, line) in content.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }

        let columns: Vec<&str> = line.split('\t').collect();
        if columns.len() != 8 {
            return Err(format!(
                "invalid nodes TSV line {}: expected 8 columns, got {}",
                line_index + 1,
                columns.len()
            ));
        }

        let sort_index = columns[7].parse::<i32>().map_err(|_| {
            format!(
                "invalid sort_index at line {}: '{}'",
                line_index + 1,
                columns[7]
            )
        })?;

        let nags = columns[6]
            .split(',')
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>();

        nodes.push(AnalysisWorkspaceNode {
            id: columns[0].trim().to_owned(),
            parent_id: optional_text(columns[1]),
            san: optional_text(columns[2]),
            uci: optional_text(columns[3]),
            fen: columns[4].to_owned(),
            comment: columns[5].to_owned(),
            nags,
            sort_index,
        });
    }

    if nodes.is_empty() {
        return Err("nodes TSV has no rows".to_string());
    }

    Ok(nodes)
}

fn parse_search_options(args: &[String]) -> Result<(GameFilter, Pagination), String> {
    let mut filter = GameFilter::default();
    let mut page = Pagination::default();
    let mut i = 0usize;

    while i < args.len() {
        match args[i].as_str() {
            "--search-text" => {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| "missing value for --search-text".to_string())?;
                filter.search_text = Some(value.clone());
                i += 2;
            }
            "--result" => {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| "missing value for --result".to_string())?;
                filter.result = parse_result(value)?;
                i += 2;
            }
            "--eco" => {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| "missing value for --eco".to_string())?;
                filter.eco = Some(value.clone());
                i += 2;
            }
            "--event-or-site" => {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| "missing value for --event-or-site".to_string())?;
                filter.event_or_site = Some(value.clone());
                i += 2;
            }
            "--date-from" => {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| "missing value for --date-from".to_string())?;
                filter.date_from = Some(value.clone());
                i += 2;
            }
            "--date-to" => {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| "missing value for --date-to".to_string())?;
                filter.date_to = Some(value.clone());
                i += 2;
            }
            "--limit" => {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| "missing value for --limit".to_string())?;
                page.limit = parse_u32("limit", value)?;
                i += 2;
            }
            "--offset" => {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| "missing value for --offset".to_string())?;
                page.offset = parse_u32("offset", value)?;
                i += 2;
            }
            unknown => {
                return Err(format!("unknown option '{unknown}'"));
            }
        }
    }

    Ok((filter, page))
}

#[derive(Debug, Clone, Copy)]
struct AnalyzeOptions {
    depth: u32,
    multipv: u32,
}

fn parse_multipv(value: &str) -> Result<u32, String> {
    let parsed = parse_u32("multipv", value)?;
    if parsed == 0 || parsed > 10 {
        return Err("invalid multipv, expected an integer in range 1..=10".to_string());
    }
    Ok(parsed)
}

fn parse_analyze_options(args: &[String]) -> Result<u32, String> {
    Ok(parse_analyze_multipv_options(args)?.depth)
}

fn parse_analyze_multipv_options(args: &[String]) -> Result<AnalyzeOptions, String> {
    let mut depth = 18u32;
    let mut multipv = 1u32;
    let mut i = 0usize;

    while i < args.len() {
        match args[i].as_str() {
            "--depth" => {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| "missing value for --depth".to_string())?;
                depth = parse_u32("depth", value)?;
                i += 2;
            }
            "--multipv" => {
                let value = args
                    .get(i + 1)
                    .ok_or_else(|| "missing value for --multipv".to_string())?;
                multipv = parse_multipv(value)?;
                i += 2;
            }
            unknown => return Err(format!("unknown option '{unknown}'")),
        }
    }

    Ok(AnalyzeOptions { depth, multipv })
}

fn tsv_escape(value: Option<&str>) -> String {
    value.unwrap_or("").replace(['\t', '\n', '\r'], " ")
}

fn write_session_line(line: &str) -> Result<(), String> {
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "{line}").map_err(|err| format!("failed to write session output: {err}"))?;
    stdout
        .flush()
        .map_err(|err| format!("failed to flush session output: {err}"))
}

fn run_engine_session(engine_path: &str) -> Result<(), String> {
    let mut session = EngineSession::start(engine_path)
        .map_err(|err| format!("failed to start engine session '{engine_path}': {err:?}"))?;

    write_session_line("ready")?;

    let stdin = std::io::stdin();
    let mut input = String::new();
    let mut handle = stdin.lock();

    loop {
        input.clear();
        let bytes = handle
            .read_line(&mut input)
            .map_err(|err| format!("failed to read session command: {err}"))?;
        if bytes == 0 {
            break;
        }

        let command_line = input.trim_end_matches(['\n', '\r']);
        if command_line.trim().is_empty() {
            continue;
        }

        if command_line == "quit" {
            write_session_line("bye")?;
            break;
        }

        if command_line == "ping" {
            write_session_line("pong")?;
            continue;
        }

        if command_line.starts_with("analyze-multipv\t") {
            let mut parts = command_line.splitn(4, '\t');
            let _ = parts.next();
            let depth_text = parts.next().unwrap_or_default();
            let multipv_text = parts.next().unwrap_or_default();
            let fen = parts.next().unwrap_or_default().trim();
            if fen.is_empty() {
                write_session_line("err\tfen is required")?;
                continue;
            }

            let depth = match parse_u32("depth", depth_text) {
                Ok(value) => value,
                Err(message) => {
                    write_session_line(&format!("err\t{}", tsv_escape(Some(&message))))?;
                    continue;
                }
            };

            let multipv = match parse_multipv(multipv_text) {
                Ok(value) => value,
                Err(message) => {
                    write_session_line(&format!("err\t{}", tsv_escape(Some(&message))))?;
                    continue;
                }
            };

            match session.analyze_multipv(fen, depth, multipv) {
                Ok(analysis) => {
                    let summary = format!(
                        "ok-multipv\t{}\t{}\t{}\t{}\t{}",
                        analysis.depth,
                        analysis
                            .score_cp
                            .map(|value| value.to_string())
                            .unwrap_or_default(),
                        analysis
                            .score_mate
                            .map(|value| value.to_string())
                            .unwrap_or_default(),
                        tsv_escape(analysis.bestmove.as_deref()),
                        tsv_escape(Some(&analysis.pv.join(" ")))
                    );
                    write_session_line(&summary)?;

                    for line in analysis.lines {
                        let row = format!(
                            "line\t{}\t{}\t{}\t{}\t{}\t{}",
                            line.multipv_rank,
                            line.depth,
                            line.score_cp
                                .map(|value| value.to_string())
                                .unwrap_or_default(),
                            line.score_mate
                                .map(|value| value.to_string())
                                .unwrap_or_default(),
                            tsv_escape(Some(&line.pv.join(" "))),
                            tsv_escape(Some(&line.san_pv.join(" ")))
                        );
                        write_session_line(&row)?;
                    }
                    write_session_line("done")?;
                }
                Err(err) => {
                    let message = format!("{err:?}");
                    write_session_line(&format!("err\t{}", tsv_escape(Some(&message))))?;
                }
            }
            continue;
        }

        if command_line.starts_with("analyze\t") {
            let mut parts = command_line.splitn(3, '\t');
            let _ = parts.next();
            let depth_text = parts.next().unwrap_or_default();
            let fen = parts.next().unwrap_or_default().trim();
            if fen.is_empty() {
                write_session_line("err\tfen is required")?;
                continue;
            }

            let depth = match parse_u32("depth", depth_text) {
                Ok(value) => value,
                Err(message) => {
                    write_session_line(&format!("err\t{}", tsv_escape(Some(&message))))?;
                    continue;
                }
            };

            match session.analyze(fen, depth) {
                Ok(analysis) => {
                    let line = format!(
                        "ok\t{}\t{}\t{}\t{}\t{}",
                        analysis.depth,
                        analysis
                            .score_cp
                            .map(|value| value.to_string())
                            .unwrap_or_default(),
                        analysis
                            .score_mate
                            .map(|value| value.to_string())
                            .unwrap_or_default(),
                        tsv_escape(analysis.bestmove.as_deref()),
                        tsv_escape(Some(&analysis.pv.join(" ")))
                    );
                    write_session_line(&line)?;
                }
                Err(err) => {
                    let message = format!("{err:?}");
                    write_session_line(&format!("err\t{}", tsv_escape(Some(&message))))?;
                }
            }
            continue;
        }

        write_session_line("err\tunknown command")?;
    }

    Ok(())
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    match args.as_slice() {
        [_, command, db_path] if command == "init" => init_db(db_path)
            .map_err(|err| format!("failed to initialize database at '{db_path}': {err}")),
        [program, command, db_path, pgn_path] if command == "import" => {
            let summary = import_pgn_file(db_path, pgn_path).map_err(|err| {
                format!("failed to import PGN file '{pgn_path}' into '{db_path}': {err:?}")
            })?;
            println!(
                "Imported {} game(s) from '{}' into '{}' (inserted: {}, skipped: {}, errors: {})",
                summary.total, pgn_path, db_path, summary.inserted, summary.skipped, summary.errors
            );
            Ok(())
        }
        [_, command, db_path, pgn_path, tsv] if command == "import" && tsv == "--tsv" => {
            let summary = import_pgn_file_with_progress(db_path, pgn_path, |progress| {
                println!(
                    "progress\t{}\t{}\t{}\t{}",
                    progress.total, progress.inserted, progress.skipped, progress.errors
                );
            })
            .map_err(|err| {
                format!("failed to import PGN file '{pgn_path}' into '{db_path}': {err:?}")
            })?;
            println!(
                "summary\t{}\t{}\t{}\t{}",
                summary.total, summary.inserted, summary.skipped, summary.errors
            );
            Ok(())
        }
        [_, command, db_path, rest @ ..] if command == "search" => {
            let (filter, page) = parse_search_options(rest)?;
            let rows = search_games(db_path, &filter, page)
                .map_err(|err| format!("failed to search games in '{db_path}': {err:?}"))?;

            for row in rows {
                println!(
                    "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                    row.id,
                    tsv_escape(row.white.as_deref()),
                    tsv_escape(row.black.as_deref()),
                    tsv_escape(row.result.as_deref()),
                    tsv_escape(row.date.as_deref()),
                    tsv_escape(row.eco.as_deref()),
                    tsv_escape(row.event.as_deref()),
                    tsv_escape(row.site.as_deref())
                );
            }
            Ok(())
        }
        [_, command, db_path, rest @ ..] if command == "count" => {
            let (filter, _) = parse_search_options(rest)?;
            let total = count_games(db_path, &filter)
                .map_err(|err| format!("failed to count games in '{db_path}': {err:?}"))?;
            println!("{total}");
            Ok(())
        }
        [_, command, db_path, game_id] if command == "replay" => {
            let game_id = game_id
                .parse::<i64>()
                .map_err(|_| format!("invalid game_id '{game_id}', expected an integer rowid"))?;
            let fens = replay_game_fens(db_path, game_id).map_err(|err| {
                format!("failed to replay game {game_id} from '{db_path}': {err:?}")
            })?;

            for fen in fens {
                println!("{fen}");
            }
            Ok(())
        }
        [_, command, db_path, game_id] if command == "replay-meta" => {
            let game_id = game_id
                .parse::<i64>()
                .map_err(|_| format!("invalid game_id '{game_id}', expected an integer rowid"))?;
            let timeline = replay_game(db_path, game_id).map_err(|err| {
                format!("failed to replay game {game_id} from '{db_path}': {err:?}")
            })?;

            for (ply, fen) in timeline.fens.iter().enumerate() {
                let san = ply
                    .checked_sub(1)
                    .and_then(|index| timeline.sans.get(index))
                    .map(|value| value.as_str());
                let uci = ply
                    .checked_sub(1)
                    .and_then(|index| timeline.ucis.get(index))
                    .map(|value| value.as_str());

                println!(
                    "{}\t{}\t{}\t{}",
                    ply,
                    tsv_escape(Some(fen)),
                    tsv_escape(uci),
                    tsv_escape(san)
                );
            }
            Ok(())
        }
        [_, command, fen, uci] if command == "apply-uci" => {
            let applied = apply_uci_to_fen(fen, uci)
                .map_err(|err| format!("failed to apply uci '{uci}' on fen '{fen}': {err:?}"))?;
            println!(
                "{}\t{}\t{}",
                tsv_escape(Some(&applied.san)),
                tsv_escape(Some(&applied.uci)),
                tsv_escape(Some(&applied.fen))
            );
            Ok(())
        }
        [_, command, fen] if command == "legal-uci" => {
            let legal_moves = legal_uci_moves_for_fen(fen)
                .map_err(|err| format!("failed to list legal moves for fen '{fen}': {err:?}"))?;
            for uci in legal_moves {
                println!("{uci}");
            }
            Ok(())
        }

        [_, command, engine_path, fen, rest @ ..] if command == "analyze" => {
            let depth = parse_analyze_options(rest)?;
            let analysis = analyze_position(engine_path, fen, depth).map_err(|err| {
                format!("failed to analyze position with engine '{engine_path}': {err:?}")
            })?;

            println!(
                "{}\t{}\t{}\t{}\t{}",
                analysis.depth,
                analysis
                    .score_cp
                    .map(|value| value.to_string())
                    .unwrap_or_default(),
                analysis
                    .score_mate
                    .map(|value| value.to_string())
                    .unwrap_or_default(),
                tsv_escape(analysis.bestmove.as_deref()),
                tsv_escape(Some(&analysis.pv.join(" ")))
            );
            Ok(())
        }
        [_, command, engine_path, fen, rest @ ..] if command == "analyze-multipv" => {
            let options = parse_analyze_multipv_options(rest)?;
            let analysis =
                analyze_position_multipv(engine_path, fen, options.depth, options.multipv)
                    .map_err(|err| {
                        format!("failed to analyze position with engine '{engine_path}': {err:?}")
                    })?;

            println!(
                "summary\t{}\t{}\t{}\t{}\t{}",
                analysis.depth,
                analysis
                    .score_cp
                    .map(|value| value.to_string())
                    .unwrap_or_default(),
                analysis
                    .score_mate
                    .map(|value| value.to_string())
                    .unwrap_or_default(),
                tsv_escape(analysis.bestmove.as_deref()),
                tsv_escape(Some(&analysis.pv.join(" ")))
            );

            for line in analysis.lines {
                println!(
                    "line\t{}\t{}\t{}\t{}\t{}\t{}",
                    line.multipv_rank,
                    line.depth,
                    line.score_cp
                        .map(|value| value.to_string())
                        .unwrap_or_default(),
                    line.score_mate
                        .map(|value| value.to_string())
                        .unwrap_or_default(),
                    tsv_escape(Some(&line.pv.join(" "))),
                    tsv_escape(Some(&line.san_pv.join(" ")))
                );
            }
            Ok(())
        }
        [_, command, engine_path] if command == "engine-session" => run_engine_session(engine_path),
        [_, command, analysis_db_path] if command == "analysis-init" => {
            init_analysis_workspace_db(analysis_db_path).map_err(|err| {
                format!(
                    "failed to initialize analysis workspace db at '{analysis_db_path}': {err:?}"
                )
            })
        }

        [
            _,
            command,
            analysis_db_path,
            source_db_path,
            game_id,
            workspace_name,
            root_node_id,
            current_node_id,
            nodes_tsv_path,
        ] if command == "analysis-save" => {
            let game_id = parse_i64("game_id", game_id)?;
            let nodes = parse_analysis_nodes_tsv(nodes_tsv_path)?;
            let current_node_id = if current_node_id == "-" {
                None
            } else {
                Some(current_node_id.as_str())
            };

            let workspace_id = save_analysis_workspace(
                analysis_db_path,
                source_db_path,
                game_id,
                workspace_name,
                root_node_id,
                current_node_id,
                &nodes,
            )
            .map_err(|err| format!("failed to save analysis workspace: {err:?}"))?;

            println!("{workspace_id}");
            Ok(())
        }

        [_, command, analysis_db_path, source_db_path, game_id] if command == "analysis-list" => {
            let game_id = parse_i64("game_id", game_id)?;
            let workspaces = list_analysis_workspaces(analysis_db_path, source_db_path, game_id)
                .map_err(|err| format!("failed to list analysis workspaces: {err:?}"))?;

            for workspace in workspaces {
                println!(
                    "workspace\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                    workspace.id,
                    tsv_escape(Some(&workspace.source_db_path)),
                    workspace.game_id,
                    tsv_escape(Some(&workspace.name)),
                    tsv_escape(Some(&workspace.root_node_id)),
                    tsv_escape(workspace.current_node_id.as_deref()),
                    workspace.created_at,
                    workspace.updated_at
                );
            }
            Ok(())
        }

        [_, command, analysis_db_path, workspace_id] if command == "analysis-load" => {
            let workspace_id = parse_i64("workspace_id", workspace_id)?;
            let loaded = load_analysis_workspace(analysis_db_path, workspace_id)
                .map_err(|err| format!("failed to load analysis workspace: {err:?}"))?;

            let workspace = loaded.workspace;
            println!(
                "workspace\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                workspace.id,
                tsv_escape(Some(&workspace.source_db_path)),
                workspace.game_id,
                tsv_escape(Some(&workspace.name)),
                tsv_escape(Some(&workspace.root_node_id)),
                tsv_escape(workspace.current_node_id.as_deref()),
                workspace.created_at,
                workspace.updated_at
            );

            for node in loaded.nodes {
                let nags = if node.nags.is_empty() {
                    String::new()
                } else {
                    node.nags.join(",")
                };

                println!(
                    "node\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                    tsv_escape(Some(&node.id)),
                    tsv_escape(node.parent_id.as_deref()),
                    tsv_escape(node.san.as_deref()),
                    tsv_escape(node.uci.as_deref()),
                    tsv_escape(Some(&node.fen)),
                    tsv_escape(Some(&node.comment)),
                    tsv_escape(Some(&nags)),
                    node.sort_index
                );
            }

            Ok(())
        }
        [_, command, analysis_db_path, workspace_id, workspace_name] if command == "analysis-rename" => {
            let workspace_id = parse_i64("workspace_id", workspace_id)?;
            rename_analysis_workspace(analysis_db_path, workspace_id, workspace_name)
                .map_err(|err| format!("failed to rename analysis workspace: {err:?}"))?;
            println!("ok");
            Ok(())
        }
        [_, command, analysis_db_path, workspace_id] if command == "analysis-delete" => {
            let workspace_id = parse_i64("workspace_id", workspace_id)?;
            delete_analysis_workspace(analysis_db_path, workspace_id)
                .map_err(|err| format!("failed to delete analysis workspace: {err:?}"))?;
            println!("ok");
            Ok(())
        }

        [program, ..] => {
            print_usage(program);
            Err("invalid command".to_string())
        }
        [] => Err("missing program name".to_string()),
    }
}

fn main() {
    if let Err(err) = run() {
        eprintln!("Error: {err}");
        std::process::exit(1);
    }
}
