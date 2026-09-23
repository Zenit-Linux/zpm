import std/[os, json, times, tables]

## v0.6 -- lokalny cache wyników "jaka jest najnowsza wersja repo X" (patrz
## ownrepo.nim, `fetchLatestGithubRelease`/`resolveVersionPlaceholder`).
##
## Dwa niezależne mechanizmy oszczędzania zapytań sieciowych, połączone w
## jednym pliku na dysku:
##   1. TTL (domyślnie 1h, patrz `defaultTtlSeconds`) -- w oknie ważności
##      wynik jest zwracany BEZ JAKIEGOKOLWIEK zapytania sieciowego.
##   2. ETag -- po wygaśnięciu TTL, zamiast zwykłego zapytania, wysyłamy
##      `If-None-Match: <etag>`; GitHub NIE liczy odpowiedzi `304 Not
##      Modified` do limitu zapytań API, więc odświeżenie TTL bez realnej
##      zmiany wersji jest efektywnie darmowe.
## Krytyczne dla "miliony użytkowników instalują to samo codziennie": ten
## cache jest per-maszyna, więc N instalacji tego samego pakietu na tej
## samej maszynie w oknie TTL to JEDNO zapytanie sieciowe (najwyżej), nie N.

type
  CachedVersion* = object
    tag*: string
    etag*: string
    fetchedAt*: string   ## ISO8601 UTC

const defaultTtlSeconds* = 3600  ## 1h -- kompromis między świeżością a
  ## realnym zapotrzebowaniem (nowe wydania narzędzi nie pojawiają się co
  ## minutę); można by to z czasem zrobić konfigurowalnym przez config.hcl.

proc cacheFilePath*(): string =
  getCacheDir() / "zpm" / "latest-versions.json"

proc loadCacheTable(): Table[string, CachedVersion] =
  result = initTable[string, CachedVersion]()
  let path = cacheFilePath()
  if not fileExists(path): return
  try:
    let j = parseJson(readFile(path))
    for k, v in j.pairs:
      result[k] = CachedVersion(
        tag: v{"tag"}.getStr(""),
        etag: v{"etag"}.getStr(""),
        fetchedAt: v{"fetched_at"}.getStr(""),
      )
  except CatchableError:
    discard  ## uszkodzony/nieoczekiwany cache -- traktuj jak pusty, nie wywalaj builda

proc saveCacheTable(t: Table[string, CachedVersion]) =
  try:
    createDir(cacheFilePath().parentDir)
    var j = newJObject()
    for k, v in t.pairs:
      j[k] = %*{"tag": v.tag, "etag": v.etag, "fetched_at": v.fetchedAt}
    writeFile(cacheFilePath(), pretty(j) & "\n")
  except CatchableError:
    discard  ## cache to czysta optymalizacja -- błąd zapisu nigdy nie może wywalić builda

proc secondsSince(iso: string): int64 =
  try:
    let t = parse(iso, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
    (now().utc - t).inSeconds
  except CatchableError:
    high(int64)  ## nieparsowalna data -- traktuj jako "nieskończenie stare" (wymuś odświeżenie)

proc getFreshCached*(ownerRepo: string, ttlSeconds: int = defaultTtlSeconds): CachedVersion =
  ## Zwraca wpis z cache TYLKO jeśli mieści się w oknie TTL; w przeciwnym
  ## razie pusty `CachedVersion` (tag == "" -> wołający wie, że trzeba
  ## odświeżyć). Użyj `getStaleForRevalidation`, żeby dostać ETag do
  ## warunkowego zapytania nawet po wygaśnięciu TTL.
  let t = loadCacheTable()
  if ownerRepo notin t: return CachedVersion()
  let c = t[ownerRepo]
  if secondsSince(c.fetchedAt) <= ttlSeconds.int64: return c
  CachedVersion()

proc getStaleForRevalidation*(ownerRepo: string): CachedVersion =
  ## Zwraca wpis z cache NIEZALEŻNIE od wieku -- do wysłania jako
  ## `If-None-Match` przy odświeżaniu. Pusty wynik = nigdy wcześniej nie
  ## cache'owaliśmy tego repo (pierwsze zapytanie, ETag nie istnieje).
  let t = loadCacheTable()
  t.getOrDefault(ownerRepo, CachedVersion())

proc setCached*(ownerRepo, tag, etag: string) =
  var t = loadCacheTable()
  t[ownerRepo] = CachedVersion(tag: tag, etag: etag, fetchedAt: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  saveCacheTable(t)

proc touchCacheTimestamp*(ownerRepo: string) =
  ## Wywoływane po `304 Not Modified` -- wersja się nie zmieniła, więc
  ## odświeżamy TYLKO znacznik czasu (przedłużamy TTL), zachowując
  ## dotychczasowy tag/ETag bez żadnej zmiany.
  var t = loadCacheTable()
  if ownerRepo in t:
    t[ownerRepo].fetchedAt = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    saveCacheTable(t)

proc clearTtlCache*(): bool =
  ## Usuwa CAŁY plik cache TTL (`zpm cache clear`, patrz ownrepo.nim ::
  ## clearAllNetworkCaches, ktore laczy to z pozostalymi cache'ami sieci).
  let path = cacheFilePath()
  if fileExists(path):
    removeFile(path)
    return true
  false
