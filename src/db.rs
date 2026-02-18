use rusqlite::{Connection, Result as SqlResult};

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
