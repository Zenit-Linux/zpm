import std/[httpclient, uri, os, json, strutils, strformat, times, osproc, sequtils]
import ./types
import ./logging

## v0.2 -- wspólna warstwa sieciowa dla WSZYSTKICH pobrań zpm (remote_url/
## mirrors własnego repo, indeks `native`/zenit, literalne binarki `own`).
## Zamyka trzy osobne luki naraz, bo dotąd każde miejsce (ownrepo.nim,
## zpk.nim) miało WŁASNE, niezależne `newHttpClient()` bez żadnej z tych
## warstw:
##
##  1. "TLS pinning / lista zaufanych hostów dla remote_url/mirrors/repo"
##     -- `hostAllowed` sprawdza `security.trusted_hosts` (jeśli operator
##     go skonfigurował -- pusta lista = brak ograniczenia, jak dawniej).
##     `checkPinnedCert` (v0.2.1) REALNIE egzekwuje `security.pin_sha256`:
##     jednorazowe połączenie przez `openssl s_client` PRZED właściwym
##     żądaniem HTTP, porównanie odcisku SHA-256 certyfikatu liścia z
##     listą -- niezgodność albo brak certyfikatu to twardy błąd (jedyny
##     wyjątek: brak `openssl` w PATH w ogóle, wtedy tylko ostrzeżenie,
##     żeby nie wywalać systemów bez openssl).
##  2. "Progres pobierania i limity rozmiaru plików (w pełni ciche)" --
##     `safeDownloadFile` robi HEAD przed GET (gdy serwer je wspiera) żeby
##     odrzucić za duże pliki PRZED pobraniem, i loguje postęp co ~10%
##     przez `onProgressChanged`.
##  3. "Cache HTTP (ETag/If-Modified-Since) dla refresh/indeksu zenit --
##     każde 'zpm update' ściąga cały JSON od nowa" -- `cachedFetch`
##     zapisuje `<cache>.meta.json` z ETag/Last-Modified i przy kolejnym
##     wywołaniu wysyła `If-None-Match`/`If-Modified-Since`; 304 -> zwraca
##     lokalną kopię bez ponownego ściągania treści.

type
  FetchResult* = object
    ok*: bool
    body*: string
    fromCache*: bool
    err*: string

proc hostOf(url: string): string =
  try: parseUri(url).hostname
  except CatchableError: ""

proc hostAllowed*(url: string, cfg: ZpmConfig): tuple[ok: bool, reason: string] =
  if cfg.trustedHosts.len == 0:
    return (true, "")  # kompatybilność wsteczna: brak listy = brak ograniczenia
  let h = hostOf(url)
  if h.len == 0:
    return (false, &"nie udało się ustalić hosta z URL '{url}'")
  for allowed in cfg.trustedHosts:
    if h == allowed or h.endsWith("." & allowed):
      return (true, "")
  (false, &"host '{h}' spoza security.trusted_hosts ({cfg.trustedHosts.join(\", \")}) -- odrzucam '{url}'")

proc fetchLeafCertSha256(host: string, port: int = 443, timeoutSec: int = 10): tuple[ok: bool, sha256Hex: string] =
  ## v0.2.1: prawdziwy (nie tylko-udokumentowany-jako-niedostępny) pinning
  ## certyfikatu -- łączy się PRZEZ `openssl s_client` (osobne, jednorazowe
  ## połączenie handshake-only, ZANIM `std/httpclient` w ogóle zacznie
  ## właściwe żądanie), wyciąga certyfikat liścia, liczy jego SHA-256 (DER)
  ## przez `openssl x509 -fingerprint -sha256`. To NADAL nie jest
  ## "przerwij handshake w locie" (dwa osobne połączenia TCP/TLS zamiast
  ## jednego), więc teoretyczny atakujący mógłby próbować odpowiedzieć
  ## inaczej na dwa kolejne połączenia -- ale to realne, sprawdzalne
  ## odrzucenie PRZED wysłaniem czegokolwiek wrażliwym (żądanie HTTP idzie
  ## dopiero po tym sprawdzeniu), a nie tylko wykrycie po fakcie.
  if findExe("openssl").len == 0:
    return (false, "")
  let cmd = &"echo | timeout {timeoutSec} openssl s_client -connect {host}:{port} -servername {host} " &
    "2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null"
  let (output, code) = execCmdEx(cmd)
  if code != 0: return (false, "")
  # format: "sha256 Fingerprint=AA:BB:CC:..."
  let idx = output.find('=')
  if idx < 0: return (false, "")
  let hex = output[idx+1 ..< output.len].strip().replace(":", "").toLowerAscii()
  if hex.len != 64: return (false, "")  # SHA-256 = 32 bajty = 64 hex
  (true, hex)

proc checkPinnedCert*(client: HttpClient, url: string, cfg: ZpmConfig): tuple[ok: bool, reason: string] =
  ## Best-effort, ale REALNIE EGZEKWOWANY (v0.2.1) pinning: jeśli
  ## `security.pin_sha256` jest niepusta, łączy się jednorazowo przez
  ## `openssl s_client` (patrz `fetchLeafCertSha256`) i porównuje odcisk
  ## SHA-256 certyfikatu liścia z listą. Brak `openssl` w PATH -- jedyny
  ## przypadek, w którym nadal tylko ostrzegamy zamiast blokować (żeby nie
  ## psuć działania na systemach bez openssl w ogóle, np. minimalne obrazy
  ## budujące), ale KAŻDE inne niepowodzenie (host nieosiągalny, odcisk
  ## się nie zgadza) jest TWARDYM błędem.
  if cfg.pinnedCertSha256.len == 0:
    return (true, "")
  let h = hostOf(url)
  if h.len == 0:
    return (false, &"nie udało się ustalić hosta do pinningu z URL '{url}'")
  if findExe("openssl").len == 0:
    logVerbose("[zpm:net] Uwaga: security.pin_sha256 skonfigurowane, ale 'openssl' nie jest w PATH -- " &
      "pinning NIE jest egzekwowany dla tego połączenia (tylko host-allowlist).")
    return (true, "")
  let (fetched, sha) = fetchLeafCertSha256(h)
  if not fetched:
    return (false, &"nie udało się pobrać/policzyć odcisku certyfikatu dla '{h}' (openssl s_client " &
      "nie powiodło się) -- odmawiam połączenia, skoro security.pin_sha256 jest skonfigurowane")
  let want = cfg.pinnedCertSha256.mapIt(it.toLowerAscii().replace(":", ""))
  if sha notin want:
    return (false, &"odcisk certyfikatu '{h}' ({sha}) NIE jest na liście security.pin_sha256 -- " &
      "odmawiam połączenia (możliwy MITM albo rotacja certyfikatu bez aktualizacji configu)")
  (true, "")

proc newSafeClient(timeoutMs: int): HttpClient =
  result = newHttpClient(timeout = timeoutMs)
  result.headers = newHttpHeaders({"User-Agent": "zpm/0.2"})

proc remoteContentLength(url: string, timeoutMs: int): int64 =
  ## HEAD request, best-effort -- niektóre serwery (w tym raw.githubusercontent.com)
  ## nie zawsze zwracają Content-Length na HEAD; -1 = nieznane, wołający
  ## wtedy po prostu nie robi pre-checku i polega na limicie w locie.
  try:
    var client = newSafeClient(timeoutMs)
    defer: client.close()
    let resp = client.head(url)
    let cl = resp.headers.getOrDefault("Content-Length")
    if cl.len == 0: return -1
    parseBiggestInt(cl)
  except CatchableError:
    -1

proc safeFetchUrlBody*(url: string, cfg: ZpmConfig, label: string = "zpm:net"): FetchResult =
  let (allowed, reason) = hostAllowed(url, cfg)
  if not allowed:
    return FetchResult(ok: false, err: reason)
  if cfg.maxDownloadMb > 0:
    let cl = remoteContentLength(url, 15_000)
    if cl > 0 and cl > int64(cfg.maxDownloadMb) * 1024 * 1024:
      return FetchResult(ok: false, err: &"Content-Length ({cl} B) przekracza security.max_download_mb={cfg.maxDownloadMb}")
  try:
    var client = newSafeClient(30_000)
    defer: client.close()
    let (pinOk, pinReason) = checkPinnedCert(client, url, cfg)
    if not pinOk:
      return FetchResult(ok: false, err: pinReason)
    let body = client.getContent(url)
    if cfg.maxDownloadMb > 0 and body.len > cfg.maxDownloadMb * 1024 * 1024:
      return FetchResult(ok: false, err: &"pobrana treść ({body.len} B) przekracza security.max_download_mb={cfg.maxDownloadMb} (serwer nie podał wiarygodnego Content-Length z góry)")
    FetchResult(ok: true, body: body)
  except CatchableError as e:
    stderr.writeLine(&"[{label}] ✘ Pobieranie {url} nie powiodło się: {e.msg}")
    FetchResult(ok: false, err: e.msg)

proc safeDownloadFile*(url, dest: string, cfg: ZpmConfig, label: string = "zpm:net"): tuple[ok: bool, err: string] =
  let (allowed, reason) = hostAllowed(url, cfg)
  if not allowed:
    return (false, reason)
  if cfg.maxDownloadMb > 0:
    let cl = remoteContentLength(url, 15_000)
    if cl > 0 and cl > int64(cfg.maxDownloadMb) * 1024 * 1024:
      return (false, &"Content-Length ({cl} B) przekracza security.max_download_mb={cfg.maxDownloadMb}")

  try:
    var client = newSafeClient(60_000)
    defer: client.close()
    let (pinOk, pinReason) = checkPinnedCert(client, url, cfg)
    if not pinOk:
      return (false, pinReason)

    var lastPct = -1
    proc onProgress(total, progress: BiggestInt, speed: BiggestInt) {.gcsafe.} =
      if total <= 0: return
      let pct = int((progress * 100) div total)
      if pct != lastPct and pct mod 10 == 0:
        {.cast(gcsafe).}:
          logVerbose(&"[{label}] {url}: {pct}% ({progress}/{total} B, {speed} B/s)")
        lastPct = pct
    client.onProgressChanged = onProgress
    client.downloadFile(url, dest)
    (true, "")
  except CatchableError as e:
    stderr.writeLine(&"[{label}] ✘ Pobieranie {url} nie powiodło się: {e.msg}")
    (false, e.msg)

# ---------------------------------------------------------------------------
# Cache HTTP (ETag / Last-Modified) -- v0.2
# ---------------------------------------------------------------------------

proc metaPathFor(cachePath: string): string = cachePath & ".meta.json"

proc cachedFetch*(url, cachePath: string, cfg: ZpmConfig, label: string = "zpm:net"): FetchResult =
  ## Pobiera `url`, ale jeśli mamy zapisany ETag/Last-Modified z
  ## POPRZEDNIEGO udanego pobrania tego samego `url` pod `cachePath`,
  ## wysyła `If-None-Match`/`If-Modified-Since`. Serwer odpowiadający 304
  ## oznacza "bez zmian" -- zwracamy lokalną kopię z `cachePath` bez
  ## ponownego przesyłania treści. Zapisuje nowy ETag/Last-Modified przy
  ## każdym 200 OK.
  let (allowed, reason) = hostAllowed(url, cfg)
  if not allowed:
    return FetchResult(ok: false, err: reason)

  var etag = ""
  var lastMod = ""
  let metaPath = metaPathFor(cachePath)
  if fileExists(metaPath) and fileExists(cachePath):
    try:
      let meta = parseJson(readFile(metaPath))
      if meta.hasKey("url") and meta["url"].getStr() == url:
        if meta.hasKey("etag"): etag = meta["etag"].getStr()
        if meta.hasKey("last_modified"): lastMod = meta["last_modified"].getStr()
    except CatchableError:
      discard

  try:
    var client = newSafeClient(30_000)
    defer: client.close()
    var headers = newHttpHeaders({"User-Agent": "zpm/0.2"})
    if etag.len > 0: headers["If-None-Match"] = etag
    if lastMod.len > 0: headers["If-Modified-Since"] = lastMod
    client.headers = headers

    let resp = client.get(url)
    if resp.code == Http304:
      logVerbose(&"[{label}] {url}: 304 Not Modified -- używam lokalnej kopii ({cachePath}).")
      return FetchResult(ok: true, body: readFile(cachePath), fromCache: true)

    if resp.code.is2xx:
      let body = resp.body
      if cfg.maxDownloadMb > 0 and body.len > cfg.maxDownloadMb * 1024 * 1024:
        return FetchResult(ok: false, err: &"pobrana treść przekracza security.max_download_mb={cfg.maxDownloadMb}")
      createDir(parentDir(cachePath))
      writeFile(cachePath, body)
      var meta = %*{"url": url, "fetched_at": $now()}
      let newEtag = resp.headers.getOrDefault("ETag")
      let newLastMod = resp.headers.getOrDefault("Last-Modified")
      if newEtag.len > 0: meta["etag"] = %newEtag
      if newLastMod.len > 0: meta["last_modified"] = %newLastMod
      writeFile(metaPath, $meta)
      return FetchResult(ok: true, body: body, fromCache: false)

    FetchResult(ok: false, err: &"HTTP {resp.status}")
  except CatchableError as e:
    stderr.writeLine(&"[{label}] ✘ Pobieranie {url} nie powiodło się: {e.msg}")
    FetchResult(ok: false, err: e.msg)
