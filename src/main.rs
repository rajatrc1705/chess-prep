use chess_prep::{import_pgn_file, init_db};
use std::env;

fn print_usage(program: &str) {
    eprintln!("Usage: {program} init <db_path>");
    eprintln!("       {program} import <db_path> <pgn_path>");
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    match args.as_slice() {
        [program, command, db_path] if command == "init" => init_db(db_path)
            .map_err(|err| format!("failed to initialize database at '{db_path}': {err}")),
        [program, command, db_path, pgn_path] if command == "import" => {
            let summary = import_pgn_file(db_path, pgn_path).map_err(|err| {
                format!("failed to import PGN file '{pgn_path}' into '{db_path}': {err:?}")
            })?;
            println!(
                "Imported {} game(s) from '{}' into '{}' (inserted: {}, skipped: {})",
                summary.total, pgn_path, db_path, summary.inserted, summary.skipped
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
