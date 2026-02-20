use rusqlite::{Connection, Result as SqlResult};

pub fn init_db(path: &str) -> SqlResult<()> {
    let mut conn = Connection::open(path)?;

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

    let tx = conn.transaction()?;
    tx.execute(
        "
        DELETE FROM games
        WHERE rowid NOT IN (
            SELECT MIN(rowid)
            FROM games
            GROUP BY
                COALESCE(event, ''),
                COALESCE(site, ''),
                COALESCE(date, ''),
                COALESCE(white, ''),
                COALESCE(black, ''),
                COALESCE(result, ''),
                COALESCE(eco, ''),
                COALESCE(TRIM(pgn), '')
        )
        ",
        [],
    )?;
    tx.execute_batch(
        "
        CREATE UNIQUE INDEX IF NOT EXISTS idx_games_exact_unique
        ON games(
            COALESCE(event, ''),
            COALESCE(site, ''),
            COALESCE(date, ''),
            COALESCE(white, ''),
            COALESCE(black, ''),
            COALESCE(result, ''),
            COALESCE(eco, ''),
            COALESCE(TRIM(pgn), '')
        );
        ",
    )?;
    tx.commit()?;

    Ok(())
}
