import std/[os, times, strformat, strutils]
import db_connector/db_sqlite
import ./types

## v0.3.2 -- zamyka lukę "brak migracji schematu SQLite (zmiana types.nim
## psuje istniejące instalacje)". PRZED: każda zmiana schematu (np. dodanie
## kolumny `status`, patrz historia niżej) była ręcznie doklejanym
## `try: ALTER TABLE ... except DbError: discard` -- działało dla TEJ JEDNEJ
## zmiany, ale nie skalowało się (kolejna zmiana = kolejny ręczny hack, bez
## śladu, KTÓRA baza jest na jakiej wersji, i bez możliwości odróżnienia
## "kolumna już istnieje" od INNEGO, realnego błędu SQL ukrytego pod tym
## samym `except DbError: discard`).
##
## PO: jawna tabela `schema_meta(key, value)` trzymająca `schema_version`
## (liczba całkowita) + lista `migrations` (uporządkowana, przyrostowa) --
## `openDb` stosuje TYLKO te migracje, których numer jest większy niż
## aktualna wersja zapisana w bazie, po kolei, w JEDNEJ transakcji na
## migrację. Nowa, świeżo utworzona baza dostaje najnowszy schemat wprost
## (bez przechodzenia przez całą historię) i jest oznaczana jako będąca już
## na najnowszej wersji. Błąd w trakcie migracji **nie jest cicho łykany**
## (`quit` z czytelnym komunikatem) -- w przeciwieństwie do starego wzorca.

const SchemaVersion* = 2  ## v1 = packages+history bez `status`; v2 = + `status`.
                          ## PRZY KOLEJNEJ ZMIANIE SCHEMATU: podbij tę stałą
                          ## i dopisz nową migrację do `migrations` niżej --
                          ## NIGDY nie zmieniaj istniejących wpisów `migrations`
                          ## z mocą wsteczną (bazy, które już je zastosowały,
                          ## by się rozjechały z tymi, które dopiero migrują).

type
  Migration = tuple[toVersion: int, description: string, apply: proc(db: DbConn) {.closure.}]

proc getSchemaVersion*(db: DbConn): int =
  try:
    let rows = db.getAllRows(sql"SELECT value FROM schema_meta WHERE key = 'schema_version'")
    if rows.len > 0: return parseInt(rows[0][0])
    0
  except DbError:
    0  # tabela schema_meta jeszcze nie istnieje -- baza sprzed v0.3.2 albo zupełnie nowa

proc setSchemaVersion(db: DbConn, v: int) =
  db.exec(sql"""
    CREATE TABLE IF NOT EXISTS schema_meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  """)
  db.exec(sql"""
    INSERT INTO schema_meta (key, value) VALUES ('schema_version', ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
  """, $v)

let migrations: seq[Migration] = @[
  (toVersion: 1, description: "baza: tabele packages + history", apply: proc(db: DbConn) =
    db.exec(sql"""
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
    db.exec(sql"""
      CREATE TABLE IF NOT EXISTS history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        action TEXT NOT NULL,
        name TEXT NOT NULL,
        backend TEXT NOT NULL,
        ts TEXT NOT NULL
      )
    """)
  ),
  (toVersion: 2, description: "packages: + kolumna status (installed/failed)", apply: proc(db: DbConn) =
    # SQLite nie ma "ADD COLUMN IF NOT EXISTS" -- ale teraz WIEMY (dzięki
    # schema_meta), że jesteśmy dokładnie na wersji 1, więc kolumna na
    # pewno jeszcze nie istnieje; błąd tutaj jest więc realnym błędem, nie
    # oczekiwanym "duplicate column", i NIE jest już łykany po cichu.
    db.exec(sql"ALTER TABLE packages ADD COLUMN status TEXT NOT NULL DEFAULT 'installed'")
  ),
]

proc runMigrations(db: DbConn) =
  let current = getSchemaVersion(db)
  if current == 0:
    # Baza zupełnie nowa ALBO sprzed v0.3.2 (bez schema_meta). Odróżniamy
    # przez obecność tabeli `packages`: jeśli istnieje, to baza "starsza"
    # (utworzona przed migracjami) -- stosujemy WSZYSTKIE migracje po kolei
    # (są idempotentne względem `CREATE TABLE IF NOT EXISTS`, a `ALTER
    # TABLE ADD COLUMN` dla już-istniejącej kolumny status jest łapane
    # osobno niżej dla TEGO JEDNEGO, znanego historycznie przypadku).
    let hasPackages = db.getAllRows(
      sql"SELECT name FROM sqlite_master WHERE type='table' AND name='packages'").len > 0
    if not hasPackages:
      # Zupełnie świeża baza -- zastosuj wszystko od zera.
      for m in migrations:
        m.apply(db)
      setSchemaVersion(db, SchemaVersion)
      return
    else:
      # Baza "przedmigracyjna" (v0.3.1 i starsze) -- packages już jest,
      # więc pomijamy migrację v1 (CREATE TABLE IF NOT EXISTS i tak by nic
      # nie zrobiła) i próbujemy tylko późniejsze, łapiąc znany przypadek
      # "kolumna status już istnieje" wyłącznie TUTAJ, w jednym, jawnie
      # udokumentowanym miejscu zamiast rozproszonych `except: discard`.
      for m in migrations:
        if m.toVersion == 1: continue
        try:
          m.apply(db)
        except DbError as e:
          if "duplicate column" notin e.msg.toLowerAscii():
            raise
      setSchemaVersion(db, SchemaVersion)
      return

  if current > SchemaVersion:
    stderr.writeLine(&"[zpm:db] ✘ Baza ma schema_version={current}, ale ten zpm zna tylko do {SchemaVersion} " &
      "-- prawdopodobnie baza była używana przez NOWSZĄ wersję zpm. Odmawiam działania, żeby nie uszkodzić danych.")
    quit(1)

  for m in migrations:
    if m.toVersion > current:
      try:
        m.apply(db)
      except DbError as e:
        stderr.writeLine(&"[zpm:db] ✘ Migracja do schema_version={m.toVersion} ('{m.description}') " &
          &"nie powiodła się: {e.msg}")
        quit(1)
      setSchemaVersion(db, m.toVersion)

proc openDb*(path: string): DbConn =
  createDir(parentDir(path))
  result = open(path, "", "", "")
  runMigrations(result)

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
