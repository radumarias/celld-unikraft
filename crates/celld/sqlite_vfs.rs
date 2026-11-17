// Copyright 2026 Deno Land Inc. Apache-2.0 license.

//! `CELLD_SQLITE_VFS` names the SQLite VFS that every connection in the
//! process opens with.
//!
//! celld keeps each cell in WAL mode with more than one connection. SQLite's
//! default `unix` VFS shares the WAL index between those connections through a
//! writable `MAP_SHARED` mapping of the `-shm` file. A kernel that cannot map a
//! file shared and writable fails every cell with `SQLITE_IOERR_SHMMAP`.
//! Unikraft is one: its VFS refuses writable shared file mappings.
//!
//! SQLite's built-in `unix-excl` VFS keeps the WAL index in heap memory
//! instead, and the connections of one process still share it. It also takes
//! an exclusive lock on each database, so no other process can open it. On a
//! unikernel there is no other process, so `CELLD_SQLITE_VFS=unix-excl` gives
//! celld the same WAL behavior without the mapping.
//!
//! The VFS becomes SQLite's default before any connection opens, so it reaches
//! every crate that links the bundled SQLite, `ltx` included, without a change
//! at each open call.

use anyhow::{anyhow, bail, Context};
use std::ffi::CString;

pub const VARIABLE: &str = "CELLD_SQLITE_VFS";

/// The VFS names the bundled SQLite registers on Unix.
const KNOWN: &[&str] = &["unix", "unix-excl", "unix-dotfile", "unix-none"];

/// Installs the VFS that `CELLD_SQLITE_VFS` names as SQLite's default.
/// Returns the name it installed, or `None` when the variable is unset or
/// empty and SQLite keeps its own default.
///
/// Call it before the first connection opens: a connection keeps the VFS it
/// opened with.
pub fn install_from_environment() -> anyhow::Result<Option<String>> {
    let Some(name) = crate::env_vars::value(VARIABLE)? else {
        return Ok(None);
    };
    if name.is_empty() {
        return Ok(None);
    }
    install(&name)?;
    Ok(Some(name))
}

/// Makes the named built-in VFS SQLite's default for this process.
pub fn install(name: &str) -> anyhow::Result<()> {
    let c_name = CString::new(name).map_err(|_| anyhow!("{VARIABLE} must not contain NUL"))?;
    // SAFETY: `sqlite3_initialize` is safe to call at any time and more than
    // once. `sqlite3_vfs_find` reads the registered list under SQLite's own
    // mutex, and the pointer it returns names a static VFS that SQLite never
    // frees. Registering an already registered VFS only moves it to the head
    // of the list, which is what makes it the default.
    unsafe {
        let rc = rusqlite::ffi::sqlite3_initialize();
        if rc != rusqlite::ffi::SQLITE_OK {
            bail!("initialize SQLite for {VARIABLE}: error code {rc}");
        }
        let vfs = rusqlite::ffi::sqlite3_vfs_find(c_name.as_ptr());
        if vfs.is_null() {
            bail!(
                "{VARIABLE}={name} names no SQLite VFS in this build; use one of {}",
                KNOWN.join(", ")
            );
        }
        let rc = rusqlite::ffi::sqlite3_vfs_register(vfs, 1);
        if rc != rusqlite::ffi::SQLITE_OK {
            return Err(anyhow!("error code {rc}"))
                .with_context(|| format!("make {name} the default SQLite VFS"));
        }
    }
    Ok(())
}

/// The name of SQLite's current default VFS.
pub fn default_name() -> Option<String> {
    // SAFETY: A null name asks for the default VFS. The returned VFS and its
    // `zName` are static for the life of the process.
    unsafe {
        let vfs = rusqlite::ffi::sqlite3_vfs_find(std::ptr::null());
        if vfs.is_null() || (*vfs).zName.is_null() {
            return None;
        }
        Some(
            std::ffi::CStr::from_ptr((*vfs).zName)
                .to_string_lossy()
                .into_owned(),
        )
    }
}
