// Copyright 2026 Deno Land Inc. Apache-2.0 license.

//! `CELLD_SQLITE_VFS=unix-excl` must keep celld's WAL contract without a
//! shared file mapping. This binary is its own process, so changing the
//! default VFS reaches no other test.

// The test inspects the files SQLite writes on the host file system, which is
// what the node-storage rule exists to keep out of the node.
#![allow(clippy::disallowed_methods)]

use rusqlite::Connection;

#[test]
fn unix_excl_keeps_wal_shared_between_connections_without_a_shm_file() {
    celld::sqlite_vfs::install("unix-excl").unwrap();
    assert_eq!(
        celld::sqlite_vfs::default_name().as_deref(),
        Some("unix-excl")
    );

    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("cell.db");
    let writer = Connection::open(&path).unwrap();
    let mode: String = writer
        .query_row("PRAGMA journal_mode=WAL", [], |row| row.get(0))
        .unwrap();
    assert_eq!(mode, "wal");
    writer
        .execute_batch("CREATE TABLE t (v INTEGER); INSERT INTO t VALUES (1);")
        .unwrap();

    // A second connection of the same process reads through the same
    // heap-resident WAL index, as celld's read-lock connection does.
    let reader = Connection::open(&path).unwrap();
    let sum: i64 = reader
        .query_row("SELECT sum(v) FROM t", [], |row| row.get(0))
        .unwrap();
    assert_eq!(sum, 1);
    writer.execute("INSERT INTO t VALUES (2)", []).unwrap();
    let sum: i64 = reader
        .query_row("SELECT sum(v) FROM t", [], |row| row.get(0))
        .unwrap();
    assert_eq!(sum, 3);

    assert!(directory.path().join("cell.db-wal").exists());
    assert!(
        !directory.path().join("cell.db-shm").exists(),
        "unix-excl keeps the WAL index in heap memory"
    );
}

#[test]
fn an_unknown_vfs_is_refused_with_the_names_that_exist() {
    let error = celld::sqlite_vfs::install("no-such-vfs")
        .unwrap_err()
        .to_string();
    assert!(error.contains("CELLD_SQLITE_VFS=no-such-vfs"), "{error}");
    assert!(error.contains("unix-excl"), "{error}");
}
