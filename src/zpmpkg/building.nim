import std/[os, osproc, strformat, strutils, times]
import ./types
import ./config
import ./ownrepo

type
  BuildTarget* = object
    rootPath*: string          ## katalog docelowy (przyszły / obrazu)
    packages*: seq[PackageSpec] ## pakiety do zainstalowania (nazwa + opcjonalny backend)
    backend*: string           ## domyślny backend, gdy pakiet go nie wymusza
    logPath*: string

proc parsePackageSpec*(raw: string): PackageSpec =
  ## Rozbija wpis pakietu na nazwę + opcjonalny wymuszony backend.
  ## Obsługiwane składnie (patrz modules/*/package.list w zlb):
  ##   systemd            -> PackageSpec(name: "systemd", backend: "")
  ##   systemd -> apt      -> PackageSpec(name: "systemd", backend: "apt")
  ##   systemd@apt          -> to samo, wygodne z linii poleceń
  var s = raw.strip()
  if "->" in s:
    let parts = s.split("->", maxsplit = 1)
    return PackageSpec(name: parts[0].strip(), backend: parts[1].strip().toLowerAscii)
  if '@' in s and not s.startsWith("@"):
    let parts = s.rsplit('@', maxsplit = 1)
    return PackageSpec(name: parts[0].strip(), backend: parts[1].strip().toLowerAscii)
  PackageSpec(name: s, backend: "")

proc toSpecs(raw: seq[string]): seq[PackageSpec] =
  result = @[]
  for r in raw: result.add parsePackageSpec(r)

proc ensureBuildLog(cfg: ZpmConfig): string =
  createDir(cfg.buildingCacheDir)
  let stamp = now().format("yyyyMMdd-HHmmss")
  result = cfg.buildingCacheDir / &"build-{stamp}.log"

proc logLine(path, msg: string) =
  let f = open(path, fmAppend)
  defer: f.close()
  f.writeLine(&"[{$now()}] {msg}")

proc installIntoRootWithBackend(rootPath, backend, pkg: string, cfg: ZpmConfig): int =
  ## Deleguje instalację "per-pakiet" do menedżera bazowego, ale z flagą
  ## roota/sysroota, tak żeby nic nie trafiło na system, na którym
  ## budujemy obraz. Wspiera także `own` (ekosystem Zenith, bez curl) i
  ## `brew` (Linuxbrew z prefiksem w roocie obrazu).
  case backend
  of "apt":
    result = execCmd(&"sudo apt install -y --root={rootPath} {pkg}")
  of "dnf":
    result = execCmd(&"sudo dnf install -y --installroot={rootPath} {pkg}")
  of "pacman":
    result = execCmd(&"sudo pacman -S --noconfirm --root {rootPath} {pkg}")
  of "zypper":
    result = execCmd(&"sudo zypper --root {rootPath} install -y {pkg}")
  of "brew":
    # Linuxbrew do sysroota obrazu: instalujemy do własnego prefiksu
    # osadzonego pod rootPath/opt/homebrew, żeby nie dotykać hosta.
    let brewPrefix = rootPath / "opt" / "homebrew"
    createDir(brewPrefix)
    result = execCmd(&"HOMEBREW_PREFIX={brewPrefix} brew install --appdir={brewPrefix} {pkg}")
  of "own":
    # Ekosystem Zenith -- pobiera binarkę wprost z own-repository.json i
    # ląduje w <root>/usr/local/bin, więc to samo narzędzie (np.
    # `installer`) trafia do gotowego obrazu bez jednego wywołania curl.
    let repo = loadOwnRepository(cfg.customRepoPath)
    let destDir = rootPath / "usr" / "local" / "bin"
    result = installOwn(repo, pkg, destDir)
  else:
    echo &"[zpm --building] Nieznany backend budowania: {backend}"
    result = 1

proc runBuilding*(cfg: ZpmConfig, rootPath, backend: string, rawPackages: seq[string]) =
  if rootPath.len == 0:
    echo "[zpm --building] Wymagana flaga --root=<ścieżka> wskazująca katalog docelowy obrazu."
    quit(1)

  if not dirExists(rootPath):
    echo &"[zpm --building] Tworzę katalog docelowy: {rootPath}"
    createDir(rootPath)

  let effectiveBackend = if backend.len > 0: backend else: cfg.defaultBuildingBackend
  let specs = toSpecs(rawPackages)

  let logPath = ensureBuildLog(cfg)
  let target = BuildTarget(rootPath: rootPath, packages: specs, backend: effectiveBackend, logPath: logPath)

  echo &"[zpm --building] Cel budowania: {rootPath}  (backend domyślny: {effectiveBackend})"
  echo &"[zpm --building] Log: {logPath}"
  logLine(logPath, &"START build root={rootPath} backend={effectiveBackend} packages={rawPackages}")

  var failed: seq[string] = @[]
  for spec in target.packages:
    let pkgBackend = if spec.backend.len > 0: spec.backend else: effectiveBackend
    echo &"[zpm --building] -> instaluję {spec.name} (backend: {pkgBackend}) do {rootPath}"
    let code = installIntoRootWithBackend(rootPath, pkgBackend, spec.name, cfg)
    logLine(logPath, &"install {spec.name}@{pkgBackend} -> exit={code}")
    if code != 0:
      failed.add(spec.name & "@" & pkgBackend)

  if failed.len == 0:
    echo &"[zpm --building] ✔ Zbudowano rootfs/obraz z {target.packages.len} pakietami."
  else:
    let failedStr = failed.join(", ")
    echo &"[zpm --building] ✘ Nie udało się zainstalować: {failedStr}"
    quit(1)

proc runBuildingInit*(cfg: ZpmConfig, rootPath, trustKeysPath: string) =
  ## `zpm --root <ścieżka> init --trust-keys <plik>` -- wołane przez
  ## `zlb` na starcie każdego modułu; w trybie budowania nie ma bazy
  ## SQLite do zainicjowania (host jej nie widzi), więc po prostu
  ## przygotowujemy katalogi i logujemy zaufany zestaw kluczy repo.
  createDir(rootPath)
  createDir(cfg.buildingCacheDir)
  echo &"[zpm --root {rootPath}] init"
  if trustKeysPath.len > 0:
    if fileExists(trustKeysPath):
      echo &"[zpm --root {rootPath}] ufam zestawowi kluczy repo: {trustKeysPath}"
    else:
      echo &"[zpm --root {rootPath}] ostrzeżenie: brak pliku kluczy {trustKeysPath}"
  let repo = loadOwnRepository(cfg.customRepoPath)
  echo &"[zpm --root {rootPath}] ekosystem 'own': {repo.tools.len} narzędzi dostępnych"

proc runBuildingRemove*(cfg: ZpmConfig, rootPath, backend: string, rawPackages: seq[string]) =
  if rawPackages.len == 0: return
  let effectiveBackend = if backend.len > 0: backend else: cfg.defaultBuildingBackend
  for raw in rawPackages:
    let spec = parsePackageSpec(raw)
    let pkgBackend = if spec.backend.len > 0: spec.backend else: effectiveBackend
    echo &"[zpm --root {rootPath}] usuwam {spec.name} (backend: {pkgBackend})"
    case pkgBackend
    of "apt": discard execCmd(&"sudo apt remove -y --root={rootPath} {spec.name}")
    of "dnf": discard execCmd(&"sudo dnf remove -y --installroot={rootPath} {spec.name}")
    of "pacman": discard execCmd(&"sudo pacman -R --noconfirm --root {rootPath} {spec.name}")
    of "zypper": discard execCmd(&"sudo zypper --root {rootPath} remove -y {spec.name}")
    of "own": removeFile(rootPath / "usr" / "local" / "bin" / spec.name)
    else: echo &"[zpm --root {rootPath}] nieznany backend do usuwania: {pkgBackend}"

proc runBuildingSync*(cfg: ZpmConfig, rootPath: string) =
  echo &"[zpm --root {rootPath}] sync (odświeżenie metadanych repo w obrazie)"
