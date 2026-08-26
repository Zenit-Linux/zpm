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
      status TEXT NOT NULL DEFAULT 'installed',
      UNIQUE(name, backend)
    )
  """)
  # Migracja "w miejscu" dla baz założonych PRZED dodaniem kolumny `status`
  # -- SQLite nie ma "ADD COLUMN IF NOT EXISTS", więc łapiemy błąd duplikatu.
  try:
    result.exec(sql"ALTER TABLE packages ADD COLUMN status TEXT NOT NULL DEFAULT 'installed'")
  except DbError:
    discard  # kolumna już istnieje -- normalny przypadek dla świeżo utworzonej bazy powyżej
  result.exec(sql"""
    CREATE TABLE IF NOT EXISTS history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      action TEXT NOT NULL,
      name TEXT NOT NULL,
      backend TEXT NOT NULL,
      ts TEXT NOT NULL
    )
  """)

const TimestampFormat = "yyyy-MM-dd'T'HH:mm:sszzz"

proc nowStr(): string = now().format(TimestampFormat)

proc recordInstall*(db: DbConn, name: string, backend: BackendKind,
                     version = "", requestedBy = "user", origin = "") =
  let ts = nowStr()
  db.exec(sql"""
    INSERT INTO packages (name, backend, version, requested_by, installed_at, origin, status)
    VALUES (?, ?, ?, ?, ?, ?, 'installed')
    ON CONFLICT(name, backend) DO UPDATE SET
      version=excluded.version, installed_at=excluded.installed_at, status='installed'
  """, name, $backend, version, requestedBy, ts, origin)
  db.exec(sql"INSERT INTO history (action, name, backend, ts) VALUES ('install', ?, ?, ?)",
          name, $backend, ts)

proc recordFailed*(db: DbConn, name: string, backend: BackendKind,
                    requestedBy = "user", origin = "") =
  ## Instalacja, która rozpoczęła się (miała jakiś efekt uboczny -- np.
  ## częściowo zbudowane/zainstalowane narzędzie `own` typu git) ale się
  ## NIE powiodła do końca. Bez tego taki pakiet po prostu nie pojawia
  ## się w bazie wcale -- `zpm list`/`zpm doctor` nie mają jak ostrzec, że
  ## system może być w niespójnym stanie.
  let ts = nowStr()
  db.exec(sql"""
    INSERT INTO packages (name, backend, version, requested_by, installed_at, origin, status)
    VALUES (?, ?, '', ?, ?, ?, 'failed')
    ON CONFLICT(name, backend) DO UPDATE SET
      installed_at=excluded.installed_at, status='failed'
  """, name, $backend, requestedBy, ts, origin)
  db.exec(sql"INSERT INTO history (action, name, backend, ts) VALUES ('install-failed', ?, ?, ?)",
          name, $backend, ts)

proc recordRemoval*(db: DbConn, name: string, backend: BackendKind) =
  db.exec(sql"DELETE FROM packages WHERE name = ? AND backend = ?", name, $backend)
  db.exec(sql"INSERT INTO history (action, name, backend, ts) VALUES ('remove', ?, ?, ?)",
          name, $backend, nowStr())

proc parseInstalledAt(raw: string): DateTime =
  ## `installed_at` jest zapisywane przez `nowStr()` powyżej (format
  ## ISO8601 ze strefą). To jest MIEJSCE, gdzie kiedyś stał `now()` na
  ## sztywno (realny bug: kolumna była zapisywana poprawnie, ale przy
  ## odczycie i tak podstawiano bieżący czas) -- teraz faktycznie parsuje
  ## to, co jest w bazie, z tolerancyjnym fallbackiem dla starszych/
  ## nietypowych wartości zamiast wywalać całe `zpm list`.
  try:
    parse(raw, TimestampFormat)
  except TimeParseError, ValueError:
    try:
      parse(raw, "yyyy-MM-dd'T'HH:mm:ss")
    except TimeParseError, ValueError:
      stderr.writeLine(&"[zpm:db] Ostrzeżenie: nie udało się sparsować installed_at='{raw}', używam bieżącego czasu.")
      now()

proc listInstalled*(db: DbConn, includeFailed = false): seq[InstalledPackage] =
  ## v0.3.1 -- POPRAWKA prawdziwego błędu kompilacji na Nim 2.2 + realnym
  ## `db_connector`: `fastRows` to ITERATOR w linii (`iterator fastRows`),
  ## którego NIE MOŻNA przypisać do `let`/zwrócić warunkowo jak zwykłej
  ## procedury (`let rows = if ... : db.fastRows(...) else: db.fastRows(...)`)
  ## -- to działa TYLKO bezpośrednio w nagłówku `for`. Kompilator zgłaszał
  ## to mylącym komunikatem "attempting to call routine: fastRows" / rzekomą
  ## niejednoznacznością przeciążeń, co wyglądało jak problem z sygnaturą,
  ## a było problemem ze SPOSOBEM UŻYCIA. (Mój lokalny sandbox testowy nie
  ## złapał tego, bo kompilował z podstawionym `std/db_sqlite`, gdzie
  ## `fastRows` akurat miało nieco inną charakterystykę wnioskowania typów
  ## przy tym niepoprawnym użyciu -- na realnym `db_connector`/Nim 2.2 błąd
  ## ujawnia się poprawnie i twardo.)
  result = @[]
  let queryStr =
    if includeFailed:
      "SELECT id, name, backend, version, requested_by, installed_at, origin, status FROM packages ORDER BY name"
    else:
      "SELECT id, name, backend, version, requested_by, installed_at, origin, status FROM packages WHERE status != 'failed' ORDER BY name"
  for row in db.fastRows(sql(queryStr)):
    result.add(InstalledPackage(
      id: parseInt(row[0]),
      name: row[1],
      backend: parseEnum[BackendKind](row[2]),
      version: row[3],
      requestedBy: row[4],
      installedAt: parseInstalledAt(row[5]),
      origin: row[6],
      status: row[7]
    ))

proc isTracked*(db: DbConn, name: string, backend: BackendKind): bool =
  let rows = db.getAllRows(sql"SELECT id FROM packages WHERE name = ? AND backend = ? AND status != 'failed'", name, $backend)
  rows.len > 0

proc closeDb*(db: DbConn) =
  db.close()
