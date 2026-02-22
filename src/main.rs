use chess_prep::{
    GameFilter, GameResultFilter, Pagination, analyze_position, apply_uci_to_fen, count_games,
    import_pgn_file, import_pgn_file_with_progress, init_db, legal_uci_moves_for_fen, replay_game,
    replay_game_fens, search_games,
};

use std::env;

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
    eprintln!("       {program} apply-uci <fen> <uci>");
    eprintln!("       {program} legal-uci <fen>");
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

fn parse_analyze_options(args: &[String]) -> Result<u32, String> {
    let mut depth = 18u32;
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
            unknown => return Err(format!("unknown option '{unknown}'")),
        }
    }

    Ok(depth)
}

fn tsv_escape(value: Option<&str>) -> String {
    value.unwrap_or("").replace(['\t', '\n', '\r'], " ")
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
