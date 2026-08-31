import std/[json, os, osproc, strutils, strformat, times, sequtils, algorithm]
import ./types
import ./lockfile
import ./netutil
import ./logging
import ./signing

## Natywny format pakietów Zenit Linux -- `.zpk` (`bkZenitNat` w types.nim).
##
## To sformalizowana wersja tego, co robi ekosystem `own` typu `git`
## (build.<lang> + install.<lang>), tyle że zamiast instalować wprost ze
## źródeł za każdym razem, jest to SPAKOWANY, wersjonowany artefakt
## z manifestem (nazwa/wersja/architektura/zależności/suma kontrolna/
## opcjonalny podpis), który potem można instalować wielokrotnie bez
## ponownego budowania -- odpowiednik .deb/.rpm/.pkg.tar.zst, ale swój.
##
## `zpm` samo NIE BUDUJE pakietów `.zpk` -- budowanie (recipe.janet ->
## staging -> tar) robi WYŁĄCZNIE osobne narzędzie `zpk`
## (https://github.com/Zenit-Linux/zpk, `zpk build`). Ten moduł zajmuje
## się wyszukiwaniem, pobieraniem, weryfikacją (integralność + podpis)
## i instalacją/usuwaniem gotowych `.zpk` -- bit-w-bit tym samym
## formatem, który `zpk build` produkuje.
##
## Indeks repozytorium: pojedynczy JSON (`ZpkRepoIndex`) analogiczny do
## Packages.gz z APT -- lista manifestów wszystkich dostępnych pakietów.

const ManifestFileName* = "manifest.json"

proc manifestFromJson(n: JsonNode): ZpkManifest =
  var deps: seq[string] = @[]
  if n.hasKey("depends_on") and n["depends_on"].kind == JArray:
    for it in n["depends_on"]:
      if it.kind == JString: deps.add it.getStr
  var files: seq[ZpkFileEntry] = @[]
  if n.hasKey("files") and n["files"].kind == JArray:
    for it in n["files"]:
      files.add ZpkFileEntry(path: it{"path"}.getStr(""), sha256: it{"sha256"}.getStr(""))
  ZpkManifest(
    name: n{"name"}.getStr(""),
    version: n{"version"}.getStr(""),
    arch: n{"arch"}.getStr("any"),
    dependsOn: deps,
    sha256: n{"sha256"}.getStr(""),
    description: n{"description"}.getStr(""),
    buildRecipe: n{"build_recipe"}.getStr(""),
    builtAt: n{"built_at"}.getStr(""),
    files: files,
    signature: n{"signature"}.getStr(""),
    signedWith: n{"signed_with"}.getStr(""),
  )

proc packageFileName*(m: ZpkManifest): string =
  &"{m.name}-{m.version}-{m.arch}.zpk"

proc sha256sumOf(path: string): string =
  let sha = execProcess("sha256sum", args = @[path], options = {poUsePath})
  if sha.len == 0: return ""
  sha.split(' ')[0].strip()

proc sha256sumOfString(content: string): string =
  ## sha256 dowolnego tekstu -- zapisuje do pliku tymczasowego i
  ## przepuszcza przez `sha256sumOf` (jeden mechanizm liczenia sum w
  ## całym zpm, zamiast osobnej implementacji sha256 w czystym Nim).
  let tmp = getTempDir() / &"zpm-strdigest-{$epochTime().int}-{getCurrentProcessId()}.tmp"
  writeFile(tmp, content)
  defer: removeFile(tmp)
  sha256sumOf(tmp)

proc contentDigestInput(files: seq[ZpkFileEntry]): string =
  ## Kanoniczna reprezentacja "zawartości pakietu" (patrz identyczna
  ## funkcja w `zpk` repo, `zpkpkg/builder.nim`) -- MUSI dawać identyczny
  ## wynik jak po stronie `zpk build` (jedyne narzędzie, które faktycznie
  ## BUDUJE `.zpk` -- `zpm` samo tylko instaluje/weryfikuje), inaczej
  ## `zpm verify`/`zpm install` nie zweryfikowałoby poprawnego pakietu.
  var sorted = files
  sorted.sort(proc(a, b: ZpkFileEntry): int = cmp(a.path, b.path))
  var parts: seq[string] = @[]
  for f in sorted: parts.add(f.path & "\t" & f.sha256)
  parts.join("\n") & "\n"

proc contentDigestOf(files: seq[ZpkFileEntry]): string =
  sha256sumOfString(contentDigestInput(files))

proc extractManifestFromArchive*(zpkPath: string): tuple[ok: bool, manifest: ZpkManifest, err: string] =
  ## Wyciąga `manifest.json` Z ŚRODKA archiwum `.zpk` (v0.4 -- manifest już
  ## nie leży obok w osobnym `<plik>.zpk.json`, patrz `zpk build` w osobnym
  ## repo `zpk`). Używane przez `zpm verify` i przez `installZpk` PRZED
  ## rozpakowaniem reszty.
  if not fileExists(zpkPath):
    return (false, ZpkManifest(), &"nie znaleziono {zpkPath}")
  let (output, code) = execCmdEx(&"tar -xOf {quoteShell(zpkPath)} {quoteShell(ManifestFileName)}")
  if code != 0 or output.strip().len == 0:
    return (false, ZpkManifest(), &"nie udało się odczytać '{ManifestFileName}' z wnętrza {zpkPath} " &
      &"(kod {code}) -- czy to na pewno poprawne archiwum .zpk?")
  try:
    (true, manifestFromJson(parseJson(output)), "")
  except CatchableError as e:
    (false, ZpkManifest(), &"'{ManifestFileName}' wewnątrz {zpkPath} nie jest poprawnym JSON-em: {e.msg}")

proc verifyZpkArchive*(zpkPath: string, publicKeyPath: string = ""): tuple[ok: bool, manifest: ZpkManifest, messages: seq[string]] =
  ## `zpm verify <plik.zpk>` -- odpowiednik `zpk verify`, na wypadek gdy
  ## operator ma pod ręką tylko `zpm` (albo instaluje pakiety zbudowane
  ## przez `zpk` inną drogą niż `zpm install`). Rozpakowuje CAŁE archiwum
  ## do katalogu tymczasowego, przelicza sha256 każdego pliku ładunku i
  ## zagregowaną sumę od nowa (integralność), i jeśli manifest niesie
  ## podpis -- weryfikuje go względem `publicKeyPath` (autentyczność).
  var messages: seq[string] = @[]
  var ok = true
  let (gotManifest, manifest, err) = extractManifestFromArchive(zpkPath)
  if not gotManifest:
    return (false, ZpkManifest(), @[err])

  let extractDir = getTempDir() / &"zpm-verify-{$epochTime().int}-{getCurrentProcessId()}"
  createDir(extractDir)
  defer: removeDir(extractDir)
  let extractCode = execCmd(&"tar -C \"{extractDir}\" -xf \"{zpkPath}\"")
  if extractCode != 0:
    return (false, manifest, @[&"nie udało się rozpakować {zpkPath} do weryfikacji (kod {extractCode})"])

  var recomputed: seq[ZpkFileEntry] = @[]
  var mismatch = false
  for entry in manifest.files:
    let full = extractDir / entry.path
    if not fileExists(full):
      ok = false
      mismatch = true
      messages.add &"BRAK pliku zadeklarowanego w manifeście: {entry.path}"
      continue
    let actual = sha256sumOf(full)
    recomputed.add ZpkFileEntry(path: entry.path, sha256: actual)
    if actual != entry.sha256:
      ok = false
      mismatch = true
      messages.add &"NIEZGODNOŚĆ sha256 pliku '{entry.path}': manifest={entry.sha256} obliczono={actual}"

  if not mismatch:
    if manifest.sha256.len == 0:
      ok = false
      messages.add "manifest nie zawiera zagregowanej sumy sha256"
    else:
      let actualAggregate = contentDigestOf(recomputed)
      if actualAggregate != manifest.sha256:
        ok = false
        messages.add &"NIEZGODNOŚĆ zagregowanej sha256: manifest={manifest.sha256} obliczono={actualAggregate}"
      else:
        messages.add &"sha256 OK ({actualAggregate}, {manifest.files.len} plików)"

  let pubKey = if publicKeyPath.len > 0: publicKeyPath else: getEnv("ZPK_VERIFY_KEY")
  if manifest.signature.len > 0:
    if pubKey.len == 0:
      messages.add "pakiet ma podpis (manifest.signature), ale nie podano klucza publicznego " &
        "(--pubkey albo ZPK_VERIFY_KEY) -- pomijam weryfikację podpisu"
    elif mismatch:
      messages.add "pomijam weryfikację podpisu -- zawartość już nie zgadza się z manifestem"
    else:
      let digestTmp = getTempDir() / &"zpm-verify-sign-{$epochTime().int}-{getCurrentProcessId()}.tmp"
      writeFile(digestTmp, contentDigestInput(recomputed))
      let (sigOk, sigErr) = verifyFile(digestTmp, pubKey, manifest.signature)
      removeFile(digestTmp)
      if sigOk:
        messages.add "podpis OK -- autentyczność potwierdzona"
      else:
        ok = false
        messages.add &"podpis NIEPRAWIDŁOWY -- {sigErr}"
  else:
    messages.add "pakiet nie jest podpisany (brak manifest.signature) -- zweryfikowano tylko integralność (sha256), nie autentyczność"

  (ok, manifest, messages)

# ---------------------------------------------------------------------------
# Budowanie i pakowanie: recipe.janet -> staging dir -> archiwum .zpk
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Indeks repozytorium (Packages.gz-owy odpowiednik) + instalacja z .zpk
# ---------------------------------------------------------------------------

proc loadRepoIndex*(path: string): ZpkRepoIndex =
  result = ZpkRepoIndex(schemaVersion: 1, packages: @[])
  if not fileExists(path):
    return
  try:
    let data = parseJson(readFile(path))
    result.schemaVersion = data{"schema_version"}.getInt(1)
    if data.hasKey("packages") and data["packages"].kind == JArray:
      for item in data["packages"]:
        result.packages.add manifestFromJson(item)
  except CatchableError as e:
    stderr.writeLine(&"[zpm:native] Ostrzeżenie: nie udało się wczytać indeksu {path} ({e.msg}).")

proc refreshNativeIndex*(cfg: ZpmConfig): bool =
  ## `zpm update`/`zpm refresh` odświeżają też indeks natywnego repo
  ## (analogicznie do `apt update`), o ile `native.repo_index_url` jest
  ## ustawiony.
  ##
  ## v0.2: idzie teraz przez `cachedFetch` (ETag/If-Modified-Since) --
  ## zamyka lukę "każde 'zpm update' ściąga cały JSON indeksu od nowa".
  if cfg.offlineMode:
    return true
  if cfg.nativeRepoIndexUrl.len == 0:
    return true
  let cachePath = cfg.nativeRepoCacheDir / "index.json.cache"
  let r = cachedFetch(cfg.nativeRepoIndexUrl, cachePath, cfg, "zpm:native")
  if not r.ok:
    stderr.writeLine(&"[zpm:native] ✘ Odświeżenie indeksu nie powiodło się: {r.err}")
    return false
  try:
    discard parseJson(r.body)  # walidacja przed nadpisaniem, jak w refreshOwnRepository
  except CatchableError as e:
    stderr.writeLine(&"[zpm:native] ✘ Pobrany indeks nie jest poprawnym JSON-em, NIE nadpisuję: {e.msg}")
    return false
  createDir(cfg.nativeRepoCacheDir)
  writeFile(cfg.nativeRepoCacheDir / "index.json", r.body)
  if r.fromCache:
    logVerbose("[zpm:native] ✔ Serwer potwierdził brak zmian (304) -- indeks bez zmian.")
  true

proc searchNative*(cfg: ZpmConfig, query: string): seq[PackageCandidate] =
  result = @[]
  let index = loadRepoIndex(cfg.nativeRepoCacheDir / "index.json")
  let q = query.toLowerAscii
  for m in index.packages:
    if m.name.toLowerAscii.contains(q):
      result.add PackageCandidate(
        name: m.name, version: m.version,
        description: &"pakiet natywny Zenit ({m.arch}): " & m.description,
        backend: bkZenitNat, installCmd: @[], extra: packageFileName(m)
      )

proc findManifest(cfg: ZpmConfig, name: string): tuple[found: bool, m: ZpkManifest] =
  let index = loadRepoIndex(cfg.nativeRepoCacheDir / "index.json")
  for m in index.packages:
    if m.name == name: return (true, m)
  (false, ZpkManifest())

proc nativeReceiptPath(cfg: ZpmConfig, name, rootPath: string): string =
  let rootTag = if rootPath.len == 0 or rootPath == "/": "host" else: rootPath.strip(chars = {'/'}).replace("/", "_")
  cfg.nativeStateDir / &"{name}@{rootTag}.json"

proc saveNativeReceipt(cfg: ZpmConfig, r: ZpkInstallReceipt) =
  createDir(cfg.nativeStateDir)
  var j = newJObject()
  j["name"] = %r.name
  j["version"] = %r.version
  j["root_path"] = %r.rootPath
  j["installed_at"] = %r.installedAt
  var filesArr = newJArray()
  for f in r.files:
    var fj = newJObject()
    fj["path"] = %f.path
    fj["sha256"] = %f.sha256
    filesArr.add fj
  j["files"] = filesArr
  let path = nativeReceiptPath(cfg, r.name, r.rootPath)
  let tmp = path & ".tmp"
  writeFile(tmp, j.pretty())
  moveFile(tmp, path)

proc loadNativeReceipt*(cfg: ZpmConfig, name, rootPath: string): tuple[found: bool, r: ZpkInstallReceipt] =
  let path = nativeReceiptPath(cfg, name, rootPath)
  if not fileExists(path): return (false, ZpkInstallReceipt())
  try:
    let j = parseJson(readFile(path))
    var files: seq[ZpkFileEntry] = @[]
    if j.hasKey("files") and j["files"].kind == JArray:
      for it in j["files"]:
        files.add ZpkFileEntry(path: it{"path"}.getStr(""), sha256: it{"sha256"}.getStr(""))
    (true, ZpkInstallReceipt(
      name: j{"name"}.getStr(""), version: j{"version"}.getStr(""),
      rootPath: j{"root_path"}.getStr(""), files: files,
      installedAt: j{"installed_at"}.getStr("")
    ))
  except CatchableError:
    (false, ZpkInstallReceipt())

proc allNativeReceipts*(cfg: ZpmConfig): seq[ZpkInstallReceipt] =
  ## v0.2.1 -- odpowiednik `state.allOwnReceipts` dla ekosystemu `native`
  ## (.zpk): zamyka część luki "own (git) i native (.zpk) mają osobne
  ## mechanizmy pokwitowań" -- teraz OBA są odpytywalne przez analogiczny
  ## interfejs (`allOwnReceipts`/`allNativeReceipts`), co jest fundamentem
  ## dla ujednoliconego widoku w `zpm list --all` (orchestrator.nim).
  result = @[]
  if not dirExists(cfg.nativeStateDir): return
  for kind, path in walkDir(cfg.nativeStateDir):
    if kind == pcFile and path.endsWith(".json"):
      try:
        let j = parseJson(readFile(path))
        var files: seq[ZpkFileEntry] = @[]
        if j.hasKey("files") and j["files"].kind == JArray:
          for it in j["files"]:
            files.add ZpkFileEntry(path: it{"path"}.getStr(""), sha256: it{"sha256"}.getStr(""))
        result.add ZpkInstallReceipt(
          name: j{"name"}.getStr(""), version: j{"version"}.getStr(""),
          rootPath: j{"root_path"}.getStr(""), files: files,
          installedAt: j{"installed_at"}.getStr("")
        )
      except CatchableError:
        discard

proc removeNativeReceiptFile(cfg: ZpmConfig, name, rootPath: string) =
  let path = nativeReceiptPath(cfg, name, rootPath)
  if fileExists(path): removeFile(path)

proc installZpk*(zpkPath, rootPath: string, cfg: ZpmConfig, manifest: ZpkManifest): int =
  ## Rozpakowuje archiwum .zpk do `rootPath` (domyślnie "/") -- struktura
  ## wewnątrz archiwum jest już względna wobec korzenia systemu (kontrakt
  ## `ZPM_PACKAGE_STAGE_DIR`, patrz `zpk build` w osobnym repo `zpk`). Po
  ## sukcesie zapisuje `ZpkInstallReceipt` (lista plików z manifestu) --
  ## BEZ TEGO `zpm remove` dla tego backendu nie ma jak wiedzieć, co
  ## dokładnie skasować.
  if not fileExists(zpkPath):
    stderr.writeLine(&"[zpm:native] ✘ Brak pliku {zpkPath}.")
    return 1
  let root = if rootPath.len > 0: rootPath else: "/"
  createDir(root)
  let code = execCmd(&"tar -C \"{root}\" -xf \"{zpkPath}\"")
  if code != 0:
    stderr.writeLine(&"[zpm:native] ✘ Rozpakowanie {zpkPath} do {root} nie powiodło się (kod {code}).")
    return code
  # `manifest.json` sam trafia do stagingu/archiwum przy budowaniu (patrz
  # `zpk build`) -- nie chcemy go liczyć jako "plik pakietu" do
  # ewentualnego usunięcia razem z resztą (to metadane, nie zawartość pakietu).
  var files: seq[ZpkFileEntry] = @[]
  for f in manifest.files:
    if f.path != ManifestFileName: files.add f
  saveNativeReceipt(cfg, ZpkInstallReceipt(
    name: manifest.name, version: manifest.version, rootPath: root,
    files: files, installedAt: nowIso8601()
  ))
  log(&"[zpm:native] ✔ Zainstalowano {zpkPath.extractFilename} (root={root}, {files.len} plików).")
  0

proc verifyAndReport(cfg: ZpmConfig, path: string): tuple[ok: bool, manifest: ZpkManifest] =
  ## Pełna weryfikacja PRZED instalacją: integralność (per-plik + suma
  ## zagregowana) ZAWSZE, autentyczność JEŚLI pakiet podpisany i
  ## `native.verify_pubkey` skonfigurowane, twarde odrzucenie nieopisanych
  ## pakietów JEŚLI `native.require_signature=true`.
  let (ok, manifest, messages) = verifyZpkArchive(path, cfg.nativeVerifyPubkey)
  for msg in messages:
    logVerbose(&"[zpm:native] {msg}")
  if not ok:
    for msg in messages:
      stderr.writeLine(&"[zpm:native] ✘ {path}: {msg}")
    return (false, manifest)
  if manifest.signature.len == 0 and cfg.nativeRequireSignature:
    stderr.writeLine(&"[zpm:native] ✘ {path}: pakiet NIE jest podpisany, a native.require_signature=true -- odmawiam instalacji.")
    return (false, manifest)
  if manifest.signature.len > 0 and cfg.nativeVerifyPubkey.len == 0:
    log(&"[zpm:native] ⚠ {path}: pakiet ma podpis, ale native.verify_pubkey nie jest skonfigurowane -- zainstalowano na podstawie samej integralności (sha256), BEZ potwierdzenia autentyczności.")
  (true, manifest)

proc installNative*(cfg: ZpmConfig, name, rootPath: string): int =
  let (found, indexManifest) = findManifest(cfg, name)
  if not found:
    log(&"[zpm:native] Pakiet '{name}' nie występuje w lokalnym indeksie. Spróbuj `zpm update` / `zpm refresh` najpierw.")
    return 1
  let cachedPath = cfg.nativeRepoCacheDir / packageFileName(indexManifest)
  if not fileExists(cachedPath):
    if cfg.offlineMode:
      log(&"[zpm:native] ✘ [offline] Brak {cachedPath} w cache'u, a sieć jest wyłączona.")
      return 1
    # URL pakietu = katalog indeksu + nazwa pliku (konwencja jak przy APT: Packages + pool/).
    let base = cfg.nativeRepoIndexUrl.rsplit('/', maxsplit = 1)[0]
    let url = base & "/" & packageFileName(indexManifest)
    log(&"[zpm:native] Pobieram {url} ...")
    createDir(cfg.nativeRepoCacheDir)
    let (dlOk, dlErr) = safeDownloadFile(url, cachedPath, cfg, "zpm:native")
    if not dlOk:
      stderr.writeLine(&"[zpm:native] ✘ Pobieranie nie powiodło się: {dlErr}")
      return 1
  # v0.4 -- integralność NIE jest już "sha256 całego pliku .zpk zgodny z
  # indeksem" (indeks niesie sumę ZAWARTOŚCI, nie bajtów archiwum -- patrz
  # `contentDigestOf`); zamiast tego archiwum jest w pełni weryfikowane
  # (per-plik + suma zagregowana + PODPIS, jeśli obecny) dokładnie tak
  # samo jak przez `zpm verify` / `zpk verify`.
  let (verifyOk, manifest) = verifyAndReport(cfg, cachedPath)
  if not verifyOk:
    removeFile(cachedPath)
    return 1
  installZpk(cachedPath, rootPath, cfg, manifest)

proc installLocalZpk*(zpkPath, rootPath: string, cfg: ZpmConfig): int =
  ## v0.4 -- instalacja BEZPOŚREDNIO z lokalnego pliku `.zpk` (np. `zpm
  ## install ./moj-pakiet-1.0.0-x86_64.zpk`), BEZ przechodzenia przez
  ## indeks repozytorium -- wcześniej jedyną drogą do zainstalowania
  ## czegokolwiek natywnego było `zpm install <nazwa>` po `zpm update`
  ## (indeks musiał już znać pakiet), więc pakiet zbudowany przez `zpk`
  ## (osobne narzędzie, jedyne, które faktycznie BUDUJE `.zpk`) albo
  ## pobrany ręcznie skądinąd nie dał się zainstalować wprost.
  ## Manifest wyciągany jest Z ARCHIWUM (v0.4, patrz `extractManifestFromArchive`),
  ## nie z osobnego pliku obok -- ten sam kontrakt co `zpm verify`.
  let (verifyOk, manifest) = verifyAndReport(cfg, zpkPath)
  if not verifyOk:
    return 1
  installZpk(zpkPath, rootPath, cfg, manifest)

proc removeNative*(cfg: ZpmConfig, name, rootPath: string): int =
  ## Realne usuwanie pakietu `.zpk` -- dokładnie te pliki, które
  ## `installZpk` zapisał w pokwitowaniu (`ZpkInstallReceipt`), NIE
  ## zgadywanie. To jest bezpośrednie domknięcie braku opisanego w
  ## README: "Usuwanie `.zpk` jawnie odmawia".
  let root = if rootPath.len > 0: rootPath else: "/"
  let (found, receipt) = loadNativeReceipt(cfg, name, root)
  if not found:
    stderr.writeLine(&"[zpm:native] ✘ Brak pokwitowania instalacji dla '{name}' (root={root}) -- " &
      "nie było zainstalowane przez `zpm install`/`installNative`, albo pokwitowanie zostało usunięte ręcznie.")
    return 1

  var removed = 0
  var dirsToCheck: seq[string] = @[]
  for f in receipt.files:
    let full = root / f.path
    if fileExists(full) or symlinkExists(full):
      removeFile(full)
      inc removed
      dirsToCheck.add parentDir(full)

  # Posprzątaj katalogi, które zostały puste PO usunięciu plików pakietu
  # (best-effort, od najgłębszych w górę; katalog nadal zawierający coś
  # obcego jest po prostu zostawiany w spokoju).
  var uniqueDirs = dirsToCheck
  uniqueDirs.sort(proc(a, b: string): int = cmp(b.len, a.len))
  for d in uniqueDirs:
    try:
      if dirExists(d) and toSeq(walkDir(d)).len == 0:
        removeDir(d)
    except CatchableError:
      discard

  removeNativeReceiptFile(cfg, name, root)
  log(&"[zpm:native] ✔ Usunięto '{name}' (root={root}, {removed}/{receipt.files.len} plików skasowanych).")
  0
