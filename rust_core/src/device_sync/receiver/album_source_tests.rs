use super::*;
use crate::api::CoreApi;
use crate::device_sync::{
    planner::SyncMode,
    receiver::{ReceiveOperation, Snapshot},
};
use crate::sync::CancellationToken;

type LogicalState = (
    Vec<(String, String, Option<String>)>,
    Vec<(String, Vec<Vec<rusqlite::types::Value>>)>,
);

fn logical_state(connection: &Connection) -> LogicalState {
    let schema = connection
        .prepare("SELECT type,name,sql FROM sqlite_master ORDER BY type,name")
        .unwrap()
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
        .unwrap()
        .collect::<Result<Vec<(String, String, Option<String>)>, _>>()
        .unwrap();
    let mut tables = Vec::new();
    for (_, name, _) in schema.iter().filter(|(kind, _, _)| kind == "table") {
        let quoted = name.replace('"', "\"\"");
        let mut statement = connection
            .prepare(&format!("SELECT * FROM \"{quoted}\" ORDER BY rowid"))
            .unwrap();
        let columns = statement.column_count();
        let values = statement
            .query_map([], |row| {
                (0..columns)
                    .map(|index| row.get::<_, rusqlite::types::Value>(index))
                    .collect::<Result<Vec<_>, _>>()
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        tables.push((name.clone(), values));
    }
    (schema, tables)
}

#[test]
fn pending_album_source_projection_missing_capabilities_is_read_only() {
    for missing in ["album_column", "source_table", "source_uuid", "source_name"] {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("library.sqlite3");
        let database = Database::open(&path).unwrap();
        database
            .create_album("Legacy same name", "", false)
            .unwrap();
        database.create_tag("retained legacy tag").unwrap();
        let before = {
            let connection = database.connection.lock().unwrap();
            connection
                .execute_batch(
                    "PRAGMA foreign_keys=OFF;
                     INSERT INTO device_sync_apply_journal
                       SELECT '10000000-0000-4000-8000-000000000001',1,library_uuid,
                         'prepare','10000000-0000-4000-8000-000000000002',
                         'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',NULL
                       FROM library_sync;",
                )
                .unwrap();
            match missing {
                "album_column" => connection.execute_batch(
                    "DROP TRIGGER ds_album_insert;
                     DROP TRIGGER ds_album_revision;
                     ALTER TABLE album DROP COLUMN source_library_uuid;",
                ),
                "source_table" => connection.execute_batch("DROP TABLE device_sync_source_name;"),
                "source_uuid" => connection.execute_batch(
                    "ALTER TABLE device_sync_source_name RENAME COLUMN library_uuid TO legacy_uuid;",
                ),
                "source_name" => connection.execute_batch(
                    "ALTER TABLE device_sync_source_name RENAME COLUMN display_name TO legacy_name;",
                ),
                _ => unreachable!(),
            }
            .unwrap();
            logical_state(&connection)
        };
        drop(database);
        let reopened = Database::open(&path).unwrap();
        let albums = reopened.list_albums().unwrap();
        assert_eq!(albums.len(), 2);
        for album in albums {
            assert_eq!(
                serde_json::to_value(album)
                    .unwrap()
                    .get("source_device_name"),
                Some(&serde_json::Value::Null),
                "missing {missing} must remain an unknown display source"
            );
        }
        let connection = reopened.connection.lock().unwrap();
        assert_eq!(connection.total_changes(), 0, "reads must not migrate");
        assert_eq!(logical_state(&connection), before, "missing {missing}");
    }
}

#[test]
fn received_same_name_albums_display_independent_sources_with_one_favorite() {
    let a_root = tempfile::tempdir().unwrap();
    let b_root = tempfile::tempdir().unwrap();
    let source = CoreApi::open(a_root.path()).unwrap();
    let target = CoreApi::open(b_root.path()).unwrap();
    source
        .create_album("Same name".into(), "".into(), false)
        .unwrap();
    target
        .create_album("Same name".into(), "".into(), false)
        .unwrap();
    let mut receive = ReceiveOperation::prepare(
        target.database(),
        Snapshot::read(&source.database(), "Phone 日本語").unwrap(),
        "Desktop",
        SyncMode::Merge,
    )
    .unwrap();
    let mut authorization = receive.authorize().unwrap();
    receive
        .apply(
            Some(&mut authorization),
            None,
            &CancellationToken::default(),
            &mut |_| {},
        )
        .unwrap();
    let albums = target.list_albums().unwrap();
    let favorites = albums
        .iter()
        .filter(|album| album.system_key.as_deref() == Some("favorites"))
        .collect::<Vec<_>>();
    assert_eq!(favorites.len(), 1);
    assert_eq!(
        serde_json::to_value(favorites[0])
            .unwrap()
            .get("source_device_name"),
        Some(&serde_json::Value::Null)
    );
    let mut sources = albums
        .iter()
        .filter(|album| album.name == "Same name")
        .map(|album| {
            serde_json::to_value(album).unwrap()["source_device_name"]
                .as_str()
                .map(str::to_owned)
        })
        .collect::<Vec<_>>();
    sources.sort();
    assert_eq!(
        sources,
        vec![Some("Desktop".into()), Some("Phone 日本語".into())]
    );
    let database = target.database();
    database
        .connection
        .lock()
        .unwrap()
        .execute("DELETE FROM device_sync_source_name", [])
        .unwrap();
    for album in database.list_albums().unwrap() {
        assert_eq!(
            serde_json::to_value(album)
                .unwrap()
                .get("source_device_name"),
            Some(&serde_json::Value::Null),
            "absent names must not be invented from identity or role"
        );
    }
}
