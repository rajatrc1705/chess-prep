use rusqlite::{Connection, params_from_iter, types::Value};

use crate::types::{GameFilter, GameResultFilter, GameRow, Pagination, QueryError};

fn normalized_filter_text(input: &Option<String>) -> Option<String> {
    let raw = input.as_ref()?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_owned())
    }
}

fn validate_date_input(field: &'static str, value: &str) -> Result<(), QueryError> {
    let bytes = value.as_bytes();
    let valid = bytes.len() == 10
        && bytes[4] == b'.'
        && bytes[7] == b'.'
        && bytes
            .iter()
            .enumerate()
            .all(|(index, ch)| index == 4 || index == 7 || ch.is_ascii_digit());

    if valid {
        Ok(())
    } else {
        Err(QueryError::InvalidDateFormat {
            field,
            value: value.to_owned(),
        })
    }
}

fn build_where_clause(filter: &GameFilter) -> Result<(String, Vec<Value>), QueryError> {
    let mut clauses = Vec::new();
    let mut values = Vec::new();

    if let Some(search_text) = normalized_filter_text(&filter.search_text) {
        clauses.push(
            "LOWER(COALESCE(white, '') || ' ' || COALESCE(black, '') || ' ' || COALESCE(event, '') || ' ' || COALESCE(site, '')) LIKE LOWER(?)",
        );
        values.push(Value::Text(format!("%{search_text}%")));
    }

    match filter.result {
        GameResultFilter::Any => {}
        GameResultFilter::WhiteWin => {
            clauses.push("result = ?");
            values.push(Value::Text("1-0".to_string()));
        }
        GameResultFilter::BlackWin => {
            clauses.push("result = ?");
            values.push(Value::Text("0-1".to_string()));
        }
        GameResultFilter::Draw => {
            clauses.push("result = ?");
            values.push(Value::Text("1/2-1/2".to_string()));
        }
    }

    if let Some(eco) = normalized_filter_text(&filter.eco) {
        clauses.push("LOWER(COALESCE(eco, '')) LIKE LOWER(?)");
        values.push(Value::Text(format!("%{eco}%")));
    }

    if let Some(event_or_site) = normalized_filter_text(&filter.event_or_site) {
        clauses.push("LOWER(COALESCE(event, '') || ' ' || COALESCE(site, '')) LIKE LOWER(?)");
        values.push(Value::Text(format!("%{event_or_site}%")));
    }

    let date_from = normalized_filter_text(&filter.date_from);
    let date_to = normalized_filter_text(&filter.date_to);
    let has_date_filter = date_from.is_some() || date_to.is_some();

    if has_date_filter {
        clauses.push("date GLOB '[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]'");
    }

    if let Some(date_from) = date_from {
        validate_date_input("date_from", &date_from)?;
        clauses.push("date >= ?");
        values.push(Value::Text(date_from));
    }

    if let Some(date_to) = date_to {
        validate_date_input("date_to", &date_to)?;
        clauses.push("date <= ?");
        values.push(Value::Text(date_to));
    }

    let where_clause = if clauses.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", clauses.join(" AND "))
    };

    Ok((where_clause, values))
}

pub fn search_games(
    db_path: &str,
    filter: &GameFilter,
    page: Pagination,
) -> Result<Vec<GameRow>, QueryError> {
    let conn = Connection::open(db_path)?;
    let (where_clause, mut values) = build_where_clause(filter)?;
    let page = page.normalized();

    let sql = format!(
        "
        SELECT rowid, event, site, date, white, black, result, eco
        FROM games
        {where_clause}
        ORDER BY date DESC, rowid DESC
        LIMIT ? OFFSET ?
        "
    );

    values.push(Value::Integer(i64::from(page.limit)));
    values.push(Value::Integer(i64::from(page.offset)));

    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(values.iter()), |row| {
        Ok(GameRow {
            id: row.get(0)?,
            event: row.get(1)?,
            site: row.get(2)?,
            date: row.get(3)?,
            white: row.get(4)?,
            black: row.get(5)?,
            result: row.get(6)?,
            eco: row.get(7)?,
        })
    })?;

    let mut games = Vec::new();
    for row in rows {
        games.push(row?);
    }
    Ok(games)
}

pub fn count_games(db_path: &str, filter: &GameFilter) -> Result<u64, QueryError> {
    let conn = Connection::open(db_path)?;
    let (where_clause, values) = build_where_clause(filter)?;

    let sql = format!(
        "
        SELECT COUNT(*)
        FROM games
        {where_clause}
        "
    );

    let count: i64 = conn.query_row(&sql, params_from_iter(values.iter()), |row| row.get(0))?;
    u64::try_from(count).map_err(|_| QueryError::CountOverflow(count))
}
