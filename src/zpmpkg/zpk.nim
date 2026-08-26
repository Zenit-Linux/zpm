import std/[json, os, osproc, strutils, strformat, times, sequtils, algorithm]
import ./types
import ./lockfile
import ./netutil
import ./logging

## Natywny format pakietów Zenit Linux -- `.zpk` (`bkZenitNat` w types.nim).
##
## To sformalizowana wersja tego, co robi ekosystem `own` typu `git`
## (build.<lang> + install.<lang>), tyle że zamiast instalować wprost ze
## źródeł za każdym razem, produkuje SPAKOWANY, wersjonowany artefakt
## z manifestem (nazwa/wersja/architektura/zależności/suma kontrolna),
## który potem można instalować wielokrotnie bez ponownego budowania --
## odpowiednik .deb/.rpm/.pkg.tar.zst, ale swój.
##
## Przepis budowania: `recipe.janet` (konwencja analogiczna do build.janet
## z ekosystemu `own`, ale z dodatkowym kontraktem: musi zostawić GOTOWE
## pliki do zainstalowania w katalogu wskazanym przez ZPM_PACKAGE_STAGE_DIR,
## z układem względnym do "/", np. usr/local/bin/narzedzie).
##
## Indeks repozytorium: pojedynczy JSON (`ZpkRepoIndex`) analogiczny do
## Packages.gz z APT -- lista manifestów wszystkich dostępnych pakietów.

const ManifestFileName* = "manifest.json"

proc manifestToJson(m: ZpkManifest): JsonNode =
  result = newJObject()
  result["name"] = %m.name
  result["version"] = %m.version
  result["arch"] = %m.arch
  result["depends_on"] = %m.dependsOn
  result["sha256"] = %m.sha256
  result["description"] = %m.description
  result["build_recipe"] = %m.buildRecipe
  result["built_at"] = %m.builtAt
  var filesArr = newJArray()
  for f in m.files:
    var fj = newJObject()
    fj["path"] = %f.path
    fj["sha256"] = %f.sha256
    filesArr.add fj
  result["files"] = filesArr

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
  )

proc packageFileName*(m: ZpkManifest): string =
  &"{m.name}-{m.version}-{m.arch}.zpk"

proc loadManifestFile*(path: string): ZpkManifest =
  ## Wczytuje manifest zapisany OBOK archiwum .zpk (`<pakiet>.zpk.json`,
  ## patrz `buildZpk`) -- używane przez `zpm pack`, żeby po zbudowaniu
  ## dopisać dokładnie ten sam manifest do lokalnego indeksu, bez
  ## powtórnego parsowania ad-hoc w orchestrator.nim.
  manifestFromJson(parseJson(readFile(path)))

proc sha256sumOf(path: string): string =
  let sha = execProcess("sha256sum", args = @[path], options = {poUsePath})
  if sha.len == 0: return ""
  sha.split(' ')[0].strip()

# ---------------------------------------------------------------------------
# Budowanie i pakowanie: recipe.janet -> staging dir -> archiwum .zpk
# ---------------------------------------------------------------------------

proc runRecipe(recipeDir, recipeFile, lang, stageDir: string,
                extraEnv: openArray[(string, string)]): int =
  let interp = case lang.toLowerAscii
    of "", "janet": "janet"
    else: lang
  if findExe(interp).len == 0:
    stderr.writeLine(&"[zpm:pack] ✘ Brak interpretera '{interp}' w PATH.")
    return 127
  for (k, v) in extraEnv:
    putEnv(k, v)
  log(&"[zpm:pack] $ (cwd={recipeDir}) {interp} {recipeFile}")
  let p = startProcess(interp, workingDir = recipeDir, args = @[recipeDir / recipeFile],
                        options = {poUsePath, poParentStreams})
  result = p.waitForExit()
  p.close()

proc buildZpk*(recipeDir: string, name, version, arch: string,
               dependsOn: seq[string], cfg: ZpmConfig,
               recipeFile = "recipe.janet", lang = "janet"): tuple[ok: bool, path: string] =
  ## Uruchamia `recipe.janet` w `recipeDir` z ZPM_PACKAGE_STAGE_DIR
  ## wskazującym na świeży katalog roboczy -- recipe ma tam zostawić
  ## dokładnie te pliki, które mają wylądować w systemie (względem "/").
  ## Po udanym uruchomieniu tar.zst-uje staging dir + manifest.json do
  ## `cfg.nativePackageOutDir/<name>-<version>-<arch>.zpk`.
  let stageDir = getTempDir() / &"zpm-pack-{name}-{$epochTime().int}"
  createDir(stageDir)
  defer: removeDir(stageDir)

  let code = runRecipe(recipeDir, recipeFile, lang, stageDir,
                        [("ZPM_PACKAGE_STAGE_DIR", stageDir), ("ZPM_PACKAGE_NAME", name),
                         ("ZPM_PACKAGE_VERSION", version), ("ZPM_PACKAGE_ARCH", arch)])
  if code != 0:
    stderr.writeLine(&"[zpm:pack] ✘ recipe '{recipeFile}' nie powiodło się (kod {code}).")
    return (false, "")

  var manifest = ZpkManifest(
    name: name, version: version, arch: arch, dependsOn: dependsOn,
    description: "", buildRecipe: recipeFile, builtAt: nowIso8601()
  )
  # Lista plików + sha256 KAŻDEGO z nich, POLICZONA PRZED dopisaniem
  # manifest.json do stagingu (żeby manifest nie próbował hashować samego
  # siebie) -- to jest to, czego brakowało do realnego `zpm remove` dla
  # .zpk: bez tej listy nie ma jak wiedzieć, co dokładnie skasować.
  for path in walkDirRec(stageDir):
    let rel = path.relativePath(stageDir)
    manifest.files.add ZpkFileEntry(path: rel, sha256: sha256sumOf(path))
  writeFile(stageDir / ManifestFileName, manifestToJson(manifest).pretty())

  createDir(cfg.nativePackageOutDir)
  let outPath = cfg.nativePackageOutDir / packageFileName(manifest)
  # tar (nie własny format archiwum) -- ten sam narzędziowy fundament co
  # reszta zpm (sha256sum, git): mniej kodu do utrzymania niż własny
  # (de)serializer archiwów, a `tar` jest wszędzie tam, gdzie jest `sh`.
  let tarCode = execCmd(&"tar --numeric-owner --owner=0 --group=0 -C \"{stageDir}\" -acf \"{outPath}\" .")
  if tarCode != 0:
    stderr.writeLine(&"[zpm:pack] ✘ Pakowanie do {outPath} nie powiodło się (kod {tarCode}).")
    return (false, "")

  manifest.sha256 = sha256sumOf(outPath)
  # Manifest z sumą samego .zpk ląduje OBOK archiwum (jawnie, do wglądu /
  # do indeksu), niezależnie od kopii spakowanej w środku archiwum.
  writeFile(outPath & ".json", manifestToJson(manifest).pretty())

  log(&"[zpm:pack] ✔ {outPath} (sha256={manifest.sha256})")
  (true, outPath)

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

proc saveRepoIndex*(path: string, index: ZpkRepoIndex) =
  createDir(parentDir(path))
  var root = newJObject()
  root["schema_version"] = %index.schemaVersion
  var pkgs = newJArray()
  for m in index.packages: pkgs.add manifestToJson(m)
  root["packages"] = pkgs
  writeFile(path, root.pretty())

proc addToIndex*(cfg: ZpmConfig, manifest: ZpkManifest) =
  ## Dopisuje/aktualizuje pakiet w LOKALNYM indeksie (`nativeRepoCacheDir/
  ## index.json`) -- to jest to, co `zpm pack` robi automatycznie po
  ## zbudowaniu, i co dałoby się potem opublikować (skopiować katalog
  ## z .zpk + index.json na serwer HTTP) jako `nativeRepoIndexUrl`.
  let indexPath = cfg.nativeRepoCacheDir / "index.json"
  var index = loadRepoIndex(indexPath)
  var replaced = false
  for i, m in index.packages:
    if m.name == manifest.name and m.version == manifest.version and m.arch == manifest.arch:
      index.packages[i] = manifest
      replaced = true
      break
  if not replaced: index.packages.add manifest
  saveRepoIndex(indexPath, index)

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
  ## wewnątrz archiwum jest już względna wobec korzenia systemu (patrz
  ## `ZPM_PACKAGE_STAGE_DIR` w `buildZpk`). Po sukcesie zapisuje
  ## `ZpkInstallReceipt` (lista plików z manifestu) -- BEZ TEGO `zpm
  ## remove` dla tego backendu nie ma jak wiedzieć, co dokładnie skasować.
  if not fileExists(zpkPath):
    stderr.writeLine(&"[zpm:native] ✘ Brak pliku {zpkPath}.")
    return 1
  let root = if rootPath.len > 0: rootPath else: "/"
  createDir(root)
  let code = execCmd(&"tar -C \"{root}\" -xf \"{zpkPath}\"")
  if code != 0:
    stderr.writeLine(&"[zpm:native] ✘ Rozpakowanie {zpkPath} do {root} nie powiodło się (kod {code}).")
    return code
  # `manifest.json` sam trafia do stagingu/archiwum (patrz buildZpk) --
  # nie chcemy go liczyć jako "plik pakietu" do ewentualnego usunięcia
  # razem z resztą (to metadane, nie zawartość pakietu).
  var files: seq[ZpkFileEntry] = @[]
  for f in manifest.files:
    if f.path != ManifestFileName: files.add f
  saveNativeReceipt(cfg, ZpkInstallReceipt(
    name: manifest.name, version: manifest.version, rootPath: root,
    files: files, installedAt: nowIso8601()
  ))
  log(&"[zpm:native] ✔ Zainstalowano {zpkPath.extractFilename} (root={root}, {files.len} plików).")
  0

proc installNative*(cfg: ZpmConfig, name, rootPath: string): int =
  let (found, manifest) = findManifest(cfg, name)
  if not found:
    log(&"[zpm:native] Pakiet '{name}' nie występuje w lokalnym indeksie. Spróbuj `zpm update` / `zpm refresh` najpierw.")
    return 1
  let cachedPath = cfg.nativeRepoCacheDir / packageFileName(manifest)
  if not fileExists(cachedPath):
    if cfg.offlineMode:
      log(&"[zpm:native] ✘ [offline] Brak {cachedPath} w cache'u, a sieć jest wyłączona.")
      return 1
    # URL pakietu = katalog indeksu + nazwa pliku (konwencja jak przy APT: Packages + pool/).
    let base = cfg.nativeRepoIndexUrl.rsplit('/', maxsplit = 1)[0]
    let url = base & "/" & packageFileName(manifest)
    log(&"[zpm:native] Pobieram {url} ...")
    createDir(cfg.nativeRepoCacheDir)
    let (dlOk, dlErr) = safeDownloadFile(url, cachedPath, cfg, "zpm:native")
    if not dlOk:
      stderr.writeLine(&"[zpm:native] ✘ Pobieranie nie powiodło się: {dlErr}")
      return 1
    if manifest.sha256.len > 0:
      let got = sha256sumOf(cachedPath)
      if got != manifest.sha256:
        stderr.writeLine(&"[zpm:native] ✘ Suma sha256 nie zgadza się dla {name} (oczekiwano {manifest.sha256}, otrzymano {got}) -- usuwam.")
        removeFile(cachedPath)
        return 1
  installZpk(cachedPath, rootPath, cfg, manifest)

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
