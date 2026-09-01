import std/[os, osproc, posix, strformat, strutils, tables, times]
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
  ## Rozbija wpis pakietu na nazwę + opcjonalny wymuszony backend +
  ## opcjonalny wariant (branch/dystrybucja) + opcjonalny opis.
  ## Obsługiwane składnie (patrz modules/*/package.list w zlb):
  ##   systemd                          -> backend/variant puste (auto)
  ##   systemd -> apt                   -> backend="apt"
  ##   systemd@apt                      -> to samo, wygodne z linii poleceń
  ##   kernel -> own -> testing         -> backend="own", variant="testing"
  ##   git -> apt -> debian.testing     -> backend="apt", variant="debian.testing"
  ##   kernel -> own : opis pakietu     -> description="opis pakietu"
  ##
  ## NAPRAWIONE: wcześniej ta funkcja rozumiała TYLKO "nazwa -> backend"
  ## (dwa segmenty) -- każdy trzeci segment (wariant) i opis po ":" trafiały
  ## w całości do pola `backend`, więc wpis wysyłany przez zlbpkg/zpm.nim
  ## (`entryArg`, format "nazwa -> backend -> wariant : opis", DOKŁADNIE
  ## to, co produkują package.list-y w zlb dla pakietów `own`) kończył się
  ## jako np. backend = "own : Zenit Package Manager -- wbudowany,
  ## domyślny" -- string, który żaden `case` niżej oczywiście nie rozpozna
  ## ("Nieznany backend budowania: own : ..."). Teraz zachowanie jest
  ## IDENTYCZNE z `parsePackageSpec` w orchestrator.nim (ten sam wire
  ## format, dwie niezależne implementacje -- muszą się zgadzać).
  var s = raw.strip()

  var description = ""
  let colonIdx = s.find(':')
  if colonIdx >= 0:
    description = s[colonIdx+1 ..< s.len].strip()
    s = s[0 ..< colonIdx].strip()

  if "->" in s:
    let parts = s.split("->")
    case parts.len
    of 2:
      return PackageSpec(name: parts[0].strip(), backend: parts[1].strip().toLowerAscii,
                          variant: "", description: description)
    else:
      # 3 lub więcej "->" -- pierwsze dwa to nazwa/backend, RESZTA
      # (zjednoczona z powrotem przez "->") to wariant.
      let variant = parts[2..^1].join("->").strip()
      return PackageSpec(name: parts[0].strip(), backend: parts[1].strip().toLowerAscii,
                          variant: variant, description: description)
  if '@' in s and not s.startsWith("@"):
    let parts = s.rsplit('@', maxsplit = 1)
    return PackageSpec(name: parts[0].strip(), backend: parts[1].strip().toLowerAscii,
                        variant: "", description: description)
  PackageSpec(name: s, backend: "", variant: "", description: description)

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

proc loadOwnRepositoryAutoRefresh(cfg: ZpmConfig): OwnRepository =
  ## `loadOwnRepository` sama w sobie jest CZYSTO lokalna -- pusty/
  ## brakujący `custom/own-repository.json` (dokładnie stan świeżej
  ## maszyny, na której nikt jeszcze nie odpalił `zpm refresh`) po cichu
  ## daje pustą listę narzędzi, więc PIERWSZY build na czystej maszynie
  ## zawsze wywalał się na "nieznane narzędzie 'X'", mimo że narzędzie
  ## FAKTYCZNIE istnieje w oficjalnym repo (patrz DefaultOwnRepoUrl w
  ## ownrepo.nim: https://raw.githubusercontent.com/Zenit-Linux/
  ## own-repository/main/repo/own-repository.json). Zamiast wymagać
  ## ręcznego kroku pośredniego, PRÓBUJEMY automatycznego odświeżenia
  ## dokładnie w tej sytuacji (pusta/brakująca lokalna kopia) -- jeśli się
  ## nie uda (offline, brak sieci), po prostu zostajemy z pustym repo tak
  ## jak dotychczas i wołający dostaje zwykły błąd "nieznane narzędzie".
  result = loadOwnRepository(cfg.customRepoPath)
  if result.tools.len == 0:
    log("[zpm --building] custom/own-repository.json puste/brak lokalnie -- " &
      "próbuję automatycznego 'zpm refresh' z domyślnego repo...")
    if refreshOwnRepository(cfg):
      result = loadOwnRepository(cfg.customRepoPath)

proc runningAsRoot(): bool =
  when defined(posix): getuid() == 0
  else: false

proc runPrivileged(cmd: string): int =
  ## Woła `cmd`, poprzedzając je `sudo` TYLKO jeśli (a) proces NIE działa
  ## już jako root ORAZ (b) `sudo` w ogóle jest dostępne w PATH.
  ##
  ## NAPRAWIONE: wcześniej każda komenda menedżera pakietów (apt/dnf/
  ## pacman/zypper) była bezwarunkowo poprzedzana `sudo `. `zlb build
  ## rootfs` (i CI budujące obrazy w kontenerach) niemal zawsze działa
  ## JUŻ jako root -- w takich obrazach `sudo` bywa świadomie w ogóle
  ## niezainstalowane (niepotrzebne, gdy i tak jest się rootem), co dawało
  ## "sh: 1: sudo: not found" i przerywało KAŻDĄ instalację przez te
  ## backendy, mimo że proces miał już pełne prawa do wykonania komendy
  ## bezpośrednio.
  let prefix = if runningAsRoot() or findExe("sudo").len == 0: "" else: "sudo "
  execCmd(prefix & cmd)

proc runInChroot(rootPath, cmd: string): int =
  ## Uruchamia `cmd` WEWNĄTRZ `rootPath` przez `chroot` -- używane dla
  ## menedżerów, które (w przeciwieństwie do apt/dnf/pacman/zypper) NIE
  ## mają natywnej flagi "zainstaluj do INNEGO systemu plików"
  ## (--root/--installroot): flatpak/snap/cargo/pip/npm same w sobie
  ## zawsze instalują "tu, gdzie są uruchomione". Zakłada, że `rootPath`
  ## ma już zainstalowany interpreter/binarkę danego menedżera (np. przez
  ## wcześniejszy pakiet z backendu `apt` w TEJ SAMEJ liście modułu) --
  ## jeśli nie, `chroot`/powłoka i tak zwrócą czytelny błąd "not found"
  ## zamiast mylącego "Nieznany backend budowania".
  if not dirExists(rootPath):
    log(&"[zpm --building] ✘ katalog docelowy '{rootPath}' nie istnieje -- nie mogę chrootować")
    return 1
  if findExe("chroot").len == 0:
    log("[zpm --building] ✘ brak polecenia 'chroot' w PATH -- wymagane dla tego backendu w trybie budowania")
    return 1
  runPrivileged(&"chroot {quoteShell(rootPath)} /bin/sh -c {quoteShell(cmd)}")

proc installIntoRootWithBackend(rootPath: string, spec: PackageSpec, cfg: ZpmConfig): int =
  ## Deleguje instalację "per-pakiet" do menedżera bazowego, ale z flagą
  ## roota/sysroota, tak żeby nic nie trafiło na system, na którym
  ## budujemy obraz.
  let pkg = spec.name
  case spec.backend
  of "apt":
    result = runPrivileged(&"apt install -y --root={rootPath} {pkg}")
  of "dnf":
    result = runPrivileged(&"dnf install -y --installroot={rootPath} {pkg}")
  of "pacman":
    result = runPrivileged(&"pacman -S --noconfirm --root {rootPath} {pkg}")
  of "zypper":
    result = runPrivileged(&"zypper --root {rootPath} install -y {pkg}")
  of "brew":
    # Linuxbrew do sysroota obrazu: instalujemy do własnego prefiksu
    # osadzonego pod rootPath/opt/homebrew, żeby nie dotykać hosta.
    let brewPrefix = rootPath / "opt" / "homebrew"
    createDir(brewPrefix)
    result = execCmd(&"HOMEBREW_PREFIX={brewPrefix} brew install --appdir={brewPrefix} {pkg}")
  of "flatpak":
    result = runInChroot(rootPath, &"flatpak install -y flathub {pkg}")
  of "snap":
    result = runInChroot(rootPath, &"snap install {pkg}")
  of "cargo":
    result = runInChroot(rootPath, &"cargo install {pkg}")
  of "pip":
    result = runInChroot(rootPath, &"pip install {pkg}")
  of "npm":
    result = runInChroot(rootPath, &"npm install -g {pkg}")
  of "own":
    # Ekosystem Zenit -- narzędzia typu `binary` lądują wprost w
    # <root>/usr/local/bin (bez jednego wywołania curl); narzędzia typu
    # `git` są klonowane + budowane (build.<lang>) i instalowane
    # (install.<lang>) z ZPM_INSTALL_ROOT=<root>, więc trafiają do
    # gotowego obrazu, nigdy do hosta, na którym budujemy. Instalacja
    # jest ŚWIADOMA `depends_on` (patrz deps.nim) -- dokładnie to, czego
    # potrzebuje builder (zlb) do własnego pipeline'u stage0/1/2.
    let repo = loadOwnRepositoryAutoRefresh(cfg)
    let destDir = rootPath / "usr" / "local" / "bin"
    # NAPRAWIONE: `spec.variant` (branch, np. "own -> stable") był
    # dotychczas po cichu odrzucany -- `kernel -> own -> stable` instalowało
    # zawsze branch DOMYŚLNY zamiast tego, co jawnie zażyczono w
    # package.list. orchestrator.nim robi to poprawnie (patrz `branchFor`
    # tamże) -- tu naprawiamy dokładnie to samo dla trybu budowania.
    var branchFor = initTable[string, string]()
    if spec.variant.len > 0: branchFor[pkg] = spec.variant
    result = if installManyOwn(repo, cfg, @[pkg], destDir, rootPath, false, branchFor): 0 else: 1
  else:
    log(&"[zpm --building] Nieznany backend budowania: {spec.backend}")
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
    let effectiveSpec = PackageSpec(name: spec.name, backend: pkgBackend,
                                     variant: spec.variant, description: spec.description)
    let variantSuffix = if spec.variant.len > 0: &" [wariant: {spec.variant}]" else: ""
    log(&"[zpm --building] -> instaluję {spec.name} (backend: {pkgBackend}){variantSuffix} do {rootPath}")
    let code = installIntoRootWithBackend(rootPath, effectiveSpec, cfg)
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
  let repo = loadOwnRepositoryAutoRefresh(cfg)
  log(&"[zpm --root {rootPath}] ekosystem 'own': {repo.tools.len} narzędzi dostępnych")

proc runBuildingRemove*(cfg: ZpmConfig, rootPath, backend: string, rawPackages: seq[string]) =
  if rawPackages.len == 0: return
  let effectiveBackend = if backend.len > 0: backend else: cfg.defaultBuildingBackend
  for raw in rawPackages:
    let spec = parsePackageSpec(raw)
    let pkgBackend = if spec.backend.len > 0: spec.backend else: effectiveBackend
    log(&"[zpm --root {rootPath}] usuwam {spec.name} (backend: {pkgBackend})")
    case pkgBackend
    of "apt": discard runPrivileged(&"apt remove -y --root={rootPath} {spec.name}")
    of "dnf": discard runPrivileged(&"dnf remove -y --installroot={rootPath} {spec.name}")
    of "pacman": discard runPrivileged(&"pacman -R --noconfirm --root {rootPath} {spec.name}")
    of "zypper": discard runPrivileged(&"zypper --root {rootPath} remove -y {spec.name}")
    of "flatpak": discard runInChroot(rootPath, &"flatpak uninstall -y {spec.name}")
    of "snap": discard runInChroot(rootPath, &"snap remove {spec.name}")
    of "cargo": discard runInChroot(rootPath, &"cargo uninstall {spec.name}")
    of "pip": discard runInChroot(rootPath, &"pip uninstall -y {spec.name}")
    of "npm": discard runInChroot(rootPath, &"npm uninstall -g {spec.name}")
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
  let repo = loadOwnRepositoryAutoRefresh(cfg)
  let destDir = rootPath / "usr" / "local" / "bin"
  if not installStageOwn(repo, cfg, stage, destDir, rootPath):
    quit(1)
