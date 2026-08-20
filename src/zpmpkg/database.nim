import std/[os, times, strformat, strutils]
import db_connector/db_sqlite
import ./types

proc openDb*(path: string): DbConn =
  createDir(parentDir(path))
  result = open(path, "", "", "")
  result.exec(sql"""
    CREATE TABLE IF NOT EXISTS packages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      backend TEXT NOT NULL,
      version TEXT NOT NULL DEFAULT '',
      requested_by TEXT NOT NULL DEFAULT 'user',
      installed_at TEXT NOT NULL,
      origin TEXT NOT NULL DEFAULT '',
      UNIQUE(name, backend)
    )
  """)
  result.exec(sql"""
    CREATE TABLE IF NOT EXISTS history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      action TEXT NOT NULL,
      name TEXT NOT NULL,
      backend TEXT NOT NULL,
      ts TEXT NOT NULL
    )
  """)

proc recordInstall*(db: DbConn, name: string, backend: BackendKind,
                     version = "", requestedBy = "user", origin = "") =
  let now = $now()
  db.exec(sql"""
    INSERT INTO packages (name, backend, version, requested_by, installed_at, origin)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(name, backend) DO UPDATE SET
      version=excluded.version, installed_at=excluded.installed_at
  """, name, $backend, version, requestedBy, now, origin)
  db.exec(sql"INSERT INTO history (action, name, backend, ts) VALUES ('install', ?, ?, ?)",
          name, $backend, now)

proc recordRemoval*(db: DbConn, name: string, backend: BackendKind) =
  db.exec(sql"DELETE FROM packages WHERE name = ? AND backend = ?", name, $backend)
  db.exec(sql"INSERT INTO history (action, name, backend, ts) VALUES ('remove', ?, ?, ?)",
          name, $backend, $now())

proc listInstalled*(db: DbConn): seq[InstalledPackage] =
  result = @[]
  for row in db.fastRows(sql"SELECT id, name, backend, version, requested_by, installed_at, origin FROM packages ORDER BY name"):
    result.add(InstalledPackage(
      id: parseInt(row[0]),
      name: row[1],
      backend: parseEnum[BackendKind](row[2]),
      version: row[3],
      requestedBy: row[4],
      installedAt: now(),  # przechowywane jako tekst; parsowanie pominięte w prototypie
      origin: row[6]
    ))

proc isTracked*(db: DbConn, name: string, backend: BackendKind): bool =
  let rows = db.getAllRows(sql"SELECT id FROM packages WHERE name = ? AND backend = ?", name, $backend)
  rows.len > 0

proc closeDb*(db: DbConn) =
  db.close()
