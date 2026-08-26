import std/[os, osproc, strformat, strutils, times]
import ./types
import ./config
import ./ownrepo
import ./trustedkeys
import ./logging

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
  ## budujemy obraz. Wspiera także `own` (ekosystem Zenit, bez curl) i
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
    # Ekosystem Zenit -- narzędzia typu `binary` lądują wprost w
    # <root>/usr/local/bin (bez jednego wywołania curl); narzędzia typu
    # `git` są klonowane + budowane (build.<lang>) i instalowane
    # (install.<lang>) z ZPM_INSTALL_ROOT=<root>, więc trafiają do
    # gotowego obrazu, nigdy do hosta, na którym budujemy. Instalacja
    # jest ŚWIADOMA `depends_on` (patrz deps.nim) -- dokładnie to, czego
    # potrzebuje builder (zlb) do własnego pipeline'u stage0/1/2: on
    # decyduje KIEDY woła zpm dla którego etapu, a zpm w obrębie
    # POJEDYNCZEGO wywołania gwarantuje poprawną kolejność zależności.
    let repo = loadOwnRepository(cfg.customRepoPath)
    let destDir = rootPath / "usr" / "local" / "bin"
    result = if installManyOwn(repo, cfg, @[pkg], destDir, rootPath): 0 else: 1
  else:
    log(&"[zpm --building] Nieznany backend budowania: {backend}")
    result = 1

proc runBuilding*(cfg: ZpmConfig, rootPath, backend: string, rawPackages: seq[string]) =
  if rootPath.len == 0:
    log("[zpm --building] Wymagana flaga --root=<ścieżka> wskazująca katalog docelowy obrazu.")
    quit(1)

  if not dirExists(rootPath):
    log(&"[zpm --building] Tworzę katalog docelowy: {rootPath}")
    createDir(rootPath)

  let effectiveBackend = if backend.len > 0: backend else: cfg.defaultBuildingBackend
  let specs = toSpecs(rawPackages)

  let logPath = ensureBuildLog(cfg)
  let target = BuildTarget(rootPath: rootPath, packages: specs, backend: effectiveBackend, logPath: logPath)

  log(&"[zpm --building] Cel budowania: {rootPath}  (backend domyślny: {effectiveBackend})")
  log(&"[zpm --building] Log: {logPath}")
  logLine(logPath, &"START build root={rootPath} backend={effectiveBackend} packages={rawPackages}")

  var failed: seq[string] = @[]
  for spec in target.packages:
    let pkgBackend = if spec.backend.len > 0: spec.backend else: effectiveBackend
    log(&"[zpm --building] -> instaluję {spec.name} (backend: {pkgBackend}) do {rootPath}")
    let code = installIntoRootWithBackend(rootPath, pkgBackend, spec.name, cfg)
    logLine(logPath, &"install {spec.name}@{pkgBackend} -> exit={code}")
    if code != 0:
      failed.add(spec.name & "@" & pkgBackend)

  if failed.len == 0:
    log(&"[zpm --building] ✔ Zbudowano rootfs/obraz z {target.packages.len} pakietami.")
  else:
    let failedStr = failed.join(", ")
    log(&"[zpm --building] ✘ Nie udało się zainstalować: {failedStr}")
    quit(1)

proc runBuildingInit*(cfg: ZpmConfig, rootPath, trustKeysPath: string) =
  ## `zpm --root <ścieżka> init --trust-keys <plik>` -- wołane przez
  ## `zlb` na starcie każdego modułu; w trybie budowania nie ma bazy
  ## SQLite do zainicjowania (host jej nie widzi), więc przygotowujemy
  ## katalogi i (v0.2) REALNIE persystujemy zaufany zestaw kluczy repo
  ## PER-OBRAZ (pod `<rootPath>/etc/zpm/trusted-keys.list`), zamiast tylko
  ## drukować komunikat -- `verifyGitSignature` wewnątrz TEGO builda
  ## (kolejne wywołania `zpm --root <rootPath> own install ...`) odczyta
  ## tę samą listę i odrzuci podpisy spoza niej.
  createDir(rootPath)
  createDir(cfg.buildingCacheDir)
  log(&"[zpm --root {rootPath}] init")
  if trustKeysPath.len > 0:
    if fileExists(trustKeysPath):
      let (ok, count) = importTrustKeysFile(cfg, trustKeysPath, rootPath)
      if ok:
        log(&"[zpm --root {rootPath}] ✔ zaimportowano {count} zaufany(ch) klucz(y/e) z {trustKeysPath}")
      else:
        log(&"[zpm --root {rootPath}] ✘ {trustKeysPath} nie zawierał rozpoznanego fingerprintu/klucza")
    else:
      log(&"[zpm --root {rootPath}] ostrzeżenie: brak pliku kluczy {trustKeysPath}")
  let repo = loadOwnRepository(cfg.customRepoPath)
  log(&"[zpm --root {rootPath}] ekosystem 'own': {repo.tools.len} narzędzi dostępnych")
proc runBuildingRemove*(cfg: ZpmConfig, rootPath, backend: string, rawPackages: seq[string]) =
  if rawPackages.len == 0: return
  let effectiveBackend = if backend.len > 0: backend else: cfg.defaultBuildingBackend
  for raw in rawPackages:
    let spec = parsePackageSpec(raw)
    let pkgBackend = if spec.backend.len > 0: spec.backend else: effectiveBackend
    log(&"[zpm --root {rootPath}] usuwam {spec.name} (backend: {pkgBackend})")
    case pkgBackend
    of "apt": discard execCmd(&"sudo apt remove -y --root={rootPath} {spec.name}")
    of "dnf": discard execCmd(&"sudo dnf remove -y --installroot={rootPath} {spec.name}")
    of "pacman": discard execCmd(&"sudo pacman -R --noconfirm --root {rootPath} {spec.name}")
    of "zypper": discard execCmd(&"sudo zypper --root {rootPath} remove -y {spec.name}")
    of "own":
      let repo = loadOwnRepository(cfg.customRepoPath)
      discard removeOwn(repo, spec.name, cfg, rootPath / "usr" / "local" / "bin", rootPath)
    else: log(&"[zpm --root {rootPath}] nieznany backend do usuwania: {pkgBackend}")
proc runBuildingSync*(cfg: ZpmConfig, rootPath: string) =
  log(&"[zpm --root {rootPath}] sync (odświeżenie metadanych repo w obrazie)")
proc runBuildingStage*(cfg: ZpmConfig, rootPath, stage: string) =
  ## `zpm --root=<rootfs> stage <etykieta>` -- instaluje (buduje + instaluje)
  ## WSZYSTKIE narzędzia `own` oznaczone daną etykietą `stage` wprost do
  ## rootfs-a obrazu, z zależnościami. To jest główny hak dla buildera
  ## (np. zlb) do realizacji WŁASNEGO pipeline'u bootstrapu (stage0 -->
  ## stage1 --> stage2): to builder decyduje, ile razy i w jakiej
  ## kolejności odpalić tę komendę -- np. `--root=/mnt/rootfs stage
  ## stage1`, a potem (już wewnątrz `chroot /mnt/rootfs`, świeżym
  ## toolchainem) `--root=/ stage stage2`. zpm w obrębie JEDNEGO
  ## wywołania gwarantuje tylko poprawną kolejność `depends_on` --
  ## resztę orkiestracji (w tym to, skąd wziąć pierwszy `zpm`, żeby
  ## w ogóle móc to wywołać) świadomie zostawiamy builderowi.
  if rootPath.len == 0:
    log("[zpm --building] Wymagana flaga --root=<ścieżka>.")
    quit(1)
  createDir(rootPath)
  let repo = loadOwnRepository(cfg.customRepoPath)
  let destDir = rootPath / "usr" / "local" / "bin"
  if not installStageOwn(repo, cfg, stage, destDir, rootPath):
    quit(1)
