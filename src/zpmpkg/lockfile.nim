import std/[json, os, osproc, strutils, strformat, times]
import ./types

## zpm.lock -- odpowiedź na "dwa buildy tego samego dnia dają różny wynik".
##
## Dla narzędzia typu `git` z `ref: "main"` sam JSON own-repository.json
## NIE wystarcza do odtworzenia builda -- "main" to ruchomy cel. Po udanym
## zbudowaniu zpm zapisuje w zpm.lock DOKŁADNY commit, na którym się to
## udało. Każdy kolejny `zpm own build/install` -- jeśli lockfile istnieje
## i ma wpis dla danego narzędzia -- checkoutuje TEN commit, a nie "main"
## na nowo. `zpm lock --update [nazwa...]` świadomie przesuwa pin na
## aktualny stan `ref`.

const DefaultLockSchemaVersion* = 1

proc emptyLock*(): ZpmLockFile =
  ZpmLockFile(schemaVersion: DefaultLockSchemaVersion, sourceDateEpoch: 0, entries: @[])

proc loadLock*(path: string): ZpmLockFile =
  ## Tolerancyjne wczytanie -- brakujący/zepsuty lockfile to po prostu
  ## "nic jeszcze nie zablokowane", NIE błąd krytyczny (tak jak brak
  ## own-repository.json nie wywala reszty zpm).
  result = emptyLock()
  if not fileExists(path):
    return
  try:
    let data = parseJson(readFile(path))
    result.schemaVersion = data{"schema_version"}.getInt(DefaultLockSchemaVersion)
    if result.schemaVersion != DefaultLockSchemaVersion:
      stderr.writeLine(&"[zpm:lock] Ostrzeżenie: {path} ma schema_version={result.schemaVersion}, " &
        &"ten zpm rozumie tylko {DefaultLockSchemaVersion} -- ignoruję plik (traktuję jako pusty), " &
        "żeby nie zinterpretować pól po swojemu. Uruchom `zpm lock` żeby przepisać go w bieżącym formacie.")
      return emptyLock()
    result.sourceDateEpoch = data{"source_date_epoch"}.getInt(0).int64
    if data.hasKey("entries") and data["entries"].kind == JArray:
      for item in data["entries"]:
        result.entries.add LockEntry(
          name: item{"name"}.getStr(""),
          kind: (if item{"kind"}.getStr("binary") == "git": otkGit else: otkBinary),
          resolvedRef: item{"resolved_ref"}.getStr(""),
          sha256: item{"sha256"}.getStr(""),
          sourceUrl: item{"source_url"}.getStr(""),
          lockedAt: item{"locked_at"}.getStr(""),
        )
  except CatchableError as e:
    stderr.writeLine(&"[zpm:lock] Ostrzeżenie: nie udało się wczytać {path} ({e.msg}) -- traktuję jako pusty.")
    result = emptyLock()

proc saveLock*(path: string, lock: ZpmLockFile) =
  createDir(parentDir(path))
  var root = newJObject()
  root["schema_version"] = %lock.schemaVersion
  root["source_date_epoch"] = %lock.sourceDateEpoch
  var entries = newJArray()
  for e in lock.entries:
    var item = newJObject()
    item["name"] = %e.name
    item["kind"] = %($e.kind)
    item["resolved_ref"] = %e.resolvedRef
    item["sha256"] = %e.sha256
    item["source_url"] = %e.sourceUrl
    item["locked_at"] = %e.lockedAt
    entries.add item
  root["entries"] = entries
  let tmp = path & ".tmp"
  writeFile(tmp, root.pretty())
  moveFile(tmp, path)

proc findEntry*(lock: ZpmLockFile, name: string): tuple[found: bool, entry: LockEntry] =
  for e in lock.entries:
    if e.name == name: return (true, e)
  (false, LockEntry())

proc upsertEntry*(lock: var ZpmLockFile, entry: LockEntry) =
  for i, e in lock.entries:
    if e.name == entry.name:
      lock.entries[i] = entry
      return
  lock.entries.add entry

proc removeEntry*(lock: var ZpmLockFile, name: string) =
  var kept: seq[LockEntry] = @[]
  for e in lock.entries:
    if e.name != name: kept.add e
  lock.entries = kept

proc resolveGitCommit*(repoDir: string): string =
  ## Dokładny SHA aktualnego HEAD-a już zaczekoutowanego repo -- to jest
  ## wartość, którą pinujemy w zpm.lock (nigdy branch/tag wprost, bo te
  ## się przesuwają).
  let (output, code) = execCmdEx(&"git -C \"{repoDir}\" rev-parse HEAD")
  if code != 0: return ""
  output.strip()

proc gitCommitDate*(repoDir, commit: string): int64 =
  ## Data commitu jako unix timestamp -- domyślne źródło SOURCE_DATE_EPOCH,
  ## gdy config go nie wymusza jawnie (patrz cfg.sourceDateEpoch == 0).
  let (output, code) = execCmdEx(&"git -C \"{repoDir}\" show -s --format=%ct \"{commit}\"")
  if code != 0: return 0
  try: parseBiggestInt(output.strip())
  except ValueError: 0

proc effectiveSourceDateEpoch*(cfg: ZpmConfig, repoDir, commit: string): int64 =
  if cfg.sourceDateEpoch != 0: return cfg.sourceDateEpoch
  let fromCommit = gitCommitDate(repoDir, commit)
  if fromCommit != 0: return fromCommit
  getTime().toUnix()

proc nowIso8601*(): string =
  now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
