use chess_prep::init_db;
use std::env;

fn print_usage(program: &str) {
    eprintln!("Usage: {program} init <db_path>");
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();

    if args.len() != 3 || args[1] != "init" {
        print_usage(&args[0]);
        return Err("invalid command".to_string());
    }

    init_db(&args[2])
        .map_err(|err| format!("failed to initialize database at '{}': {err}", args[2]))
}

fn main() {
    if let Err(err) = run() {
        eprintln!("Error: {err}");
        std::process::exit(1);
    }
}
