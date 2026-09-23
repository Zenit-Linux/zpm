import std/[os, osproc, posix, strformat, strutils, tables, times]
import ./types
import ./config
import ./ownrepo
import ./trustedkeys
import ./logging
import ./containerengine
import ./crossdistro

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

proc ensureChrootResolvConf(rootPath: string) =
  ## NAPRAWIONE: świeżo wyeksportowany obraz dystrybucji
  ## (installNativeDistroPackage) ma WŁASNY /etc/resolv.conf zapieczony w
  ## obrazie (pusty/placeholder -- prawdziwe wskazanie na resolver
  ## kontenery dostają DYNAMICZNIE od silnika w runtime, czego statyczny
  ## `podman export` w ogóle nie przenosi). `chroot`, w odróżnieniu od
  ## kontenera, NIE dostaje żadnej sieciowej konfiguracji automatycznie --
  ## dzieli stos sieciowy hosta 1:1, ale DNS w środku chroota nadal patrzy
  ## na WŁASNY /etc/resolv.conf chroota. Bez tego każde polecenie
  ## potrzebujące DNS (apt-get update, cargo install, pip install...)
  ## wewnątrz chroota kończy się "Temporary failure resolving ...", co
  ## potem wygląda jak "pakiet nie istnieje" dla KAŻDEGO pakietu na apt/
  ## dnf/pacman/zypper na raz (to jeden wspólny root cause, nie osobny
  ## błąd per pakiet).
  ##
  ## Kopiujemy (nie bind-mountujemy -- nic nie zostaje do odmontowania,
  ## nawet jeśli build zostanie przerwany w trakcie) resolv.conf hosta do
  ## chroota przed KAŻDYM runInChroot -- tanie, idempotentne.
  ## `copyFile` podąża za symlinkiem (typowe na hostach z systemd-resolved,
  ## gdzie /etc/resolv.conf to symlink do /run/systemd/resolve/...) i
  ## kopiuje REALNĄ treść, nie tworzy zwisającego symlinka w chroocie.
  try:
    createDir(rootPath / "etc")
    if fileExists("/etc/resolv.conf"):
      copyFile("/etc/resolv.conf", rootPath / "etc" / "resolv.conf")
  except CatchableError as e:
    log(&"[zpm --building] ostrzeżenie: nie udało się skopiować /etc/resolv.conf do chroota: {e.msg}")

proc mountBind(src, dst: string, recursive: bool = false): bool =
  try:
    createDir(dst)
  except CatchableError:
    return false
  let flag = if recursive: "--rbind" else: "--bind"
  execCmd(&"mount {flag} {quoteShell(src)} {quoteShell(dst)}") == 0

proc unmountQuiet(path: string, recursive: bool = false) =
  let flag = if recursive: "--recursive " else: ""
  discard execCmd(&"umount {flag}{quoteShell(path)} >/dev/null 2>&1")

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
  ##
  ## v0.4: TERAZ używane też przez apt/dnf/pacman/zypper (patrz
  ## installNativeDistroPackage) -- po jednorazowym bootstrapie rootPath
  ## z obrazu bazowej dystrybucji, rootPath ma WŁASNY, działający
  ## menedżer pakietów w środku, więc każdy kolejny pakiet z tego samego
  ## backendu leci przez dokładnie tę samą ścieżkę co flatpak/cargo/itd.
  if not dirExists(rootPath):
    log(&"[zpm --building] ✘ katalog docelowy '{rootPath}' nie istnieje -- nie mogę chrootować")
    return 1
  if findExe("chroot").len == 0:
    log("[zpm --building] ✘ brak polecenia 'chroot' w PATH -- wymagane dla tego backendu w trybie budowania")
    return 1
  ensureChrootResolvConf(rootPath)
  # NAPRAWIONE: goły `chroot` (w odróżnieniu od kontenera) nie ma w
  # środku ŻADNYCH wirtualnych systemów plików (/proc, /sys, /dev) --
  # bez nich menedżery pakietów (a zwłaszcza postinst-skrypt systemd)
  # wywalają się na wiele różnych, mylących sposobów, które są w
  # rzeczywistości JEDNYM brakującym montowaniem: "⚠️ /proc/ is not
  # mounted", "E: Can not write log (Is /dev/pts mounted?)", "Cannot
  # open '/etc/machine-id'... Function not implemented". Montujemy
  # /proc, /sys, /dev (rekurencyjnie -- --rbind na /dev automatycznie
  # przenosi też /dev/pts, /dev/shm itd., bez potrzeby osobnego
  # `mount -t devpts`) tuż przed chrootem, i ZAWSZE odmontowujemy w
  # `defer`, więc odpali się nawet jeśli komenda w środku padnie.
  let procDst = rootPath / "proc"
  let sysDst = rootPath / "sys"
  let devDst = rootPath / "dev"
  let procOk = mountBind("/proc", procDst)
  let sysOk = mountBind("/sys", sysDst)
  let devOk = mountBind("/dev", devDst, recursive = true)
  defer:
    if devOk: unmountQuiet(devDst, recursive = true)
    if sysOk: unmountQuiet(sysDst)
    if procOk: unmountQuiet(procDst)
  runPrivileged(&"chroot {quoteShell(rootPath)} /bin/sh -c {quoteShell(cmd)}")

proc hasWorkingPkgMgr(rootPath, backend: string): bool =
  ## Czy `rootPath` ma już WŁASNY, działający menedżer pakietów danego
  ## backendu w środku (czyli czy bootstrap z obrazu bazowego już się
  ## odbył w tym przebiegu) -- sprawdzamy istnienie realnej bazy/binarki
  ## menedżera, nie samego katalogu (pusty szkielet z runBuildingInit nie
  ## ma żadnej z tych ścieżek).
  case backend
  of "apt": fileExists(rootPath / "usr" / "bin" / "dpkg")
  of "dnf": fileExists(rootPath / "usr" / "bin" / "rpm")
  of "pacman": fileExists(rootPath / "usr" / "bin" / "pacman")
  of "zypper": fileExists(rootPath / "usr" / "bin" / "rpm")
  else: false

proc installNativeDistroPackage(cfg: ZpmConfig, backend, pkg, rootPath: string): int =
  ## NAPRAWIONE (v0.4): poprzednio ta gałąź wołała bezpośrednio
  ## `apt install -y --root=<rootPath> <pkg>` (analogicznie
  ## `dnf ... --installroot=<rootPath>`, `pacman ... --root <rootPath>`,
  ## `zypper --root <rootPath> ...`). Dla apt to było BEZWZGLĘDNIE zepsute
  ## -- prawdziwy apt/apt-get W OGÓLE NIE MA flagi --root
  ## (`E: Command line option --root=... is not understood`), a nawet z
  ## poprawną flagą (`apt-get -o Dir=...`) apt/apt-get i tak wymaga JUŻ
  ## zainicjowanego katalogu docelowego (plik stanu dpkg, sources.list,
  ## itd.) -- nie da się nim "zbootstrapować" całkiem pustego katalogu, do
  ## czego służą dedykowane narzędzia jak debootstrap/pacstrap. dnf/pacman/
  ## zypper mają wprawdzie realne flagi --installroot/--root, ale też
  ## generalnie zakładają choć częściowo zainicjowany target.
  ##
  ## Zamiast integrować osobno debootstrap/pacstrap/dnf --installroot dla
  ## każdego z czterech menedżerów, reużywamy JUŻ ISTNIEJĄCY w tym repo
  ## mechanizm izolowanej instalacji przez obraz kontenera -- ten sam,
  ## którego używa `zpm atomic` i jawny cross-distro
  ## (`pakiet -> apt -> debian.testing`, patrz crossdistro.nim):
  ##
  ##   1. Jeśli `rootPath` NIE MA JESZCZE własnego, działającego menedżera
  ##      pakietów danego backendu w środku (`hasWorkingPkgMgr` == false)
  ##      -- wyeksportuj CAŁY obraz domyślnej dystrybucji dla tego
  ##      backendu (apt->ubuntu, dnf->fedora, pacman->arch,
  ##      zypper->opensuse; nadpisywalne przez native.distro_images w
  ##      config.hcl -- patrz `nativeImageFor`) WPROST do `rootPath`. To
  ##      jest odpowiednik jednorazowego debootstrap/pacstrap: po tym
  ##      kroku `rootPath` ma kompletny, samodzielny system plików Z
  ##      WŁASNYM apt/dpkg (czy dnf/pacman/zypper) w środku.
  ##   2. Jeśli zażądany pakiet to nie literalnie "base" (czyli operator
  ##      chciał czegoś więcej niż sam bazowy system) -- doinstaluj go
  ##      normalnie przez `chroot rootPath <menedżer> install <pkg>`
  ##      (`runInChroot`, który rootPath ma już własny, działający
  ##      menedżer pakietów po kroku 1).
  ##   3. Jeśli `rootPath` JUŻ MA działający menedżer pakietów (baza była
  ##      już zbudowana wcześniej w TYM SAMYM przebiegu, np. dla
  ##      linux-firmware/systemd/... zaraz po "base") -- pomijamy krok 1 i
  ##      od razu robimy `chroot rootPath <menedżer> install <pkg>`.
  if not hasWorkingPkgMgr(rootPath, backend):
    let engine = detectContainerEngine()
    if engine.len == 0:
      log(&"[zpm --building] ✘ {pkg}@{backend}: bootstrap pustego '{rootPath}' wymaga 'podman' albo 'buildah' w PATH")
      return 1
    let image = nativeImageFor(cfg, backend)
    if image.len == 0:
      log(&"[zpm --building] ✘ {pkg}@{backend}: brak domyślnego obrazu bazowego dla backendu '{backend}' -- " &
        "dodaj mapowanie w native.distro_images w config.hcl")
      return 1
    log(&"[zpm --building] -> bootstrap '{rootPath}' z obrazu {image} (silnik: {engine}) [backend: {backend}]...")
    if not exportImageToLower(engine, image, rootPath):
      log(&"[zpm --building] ✘ {pkg}@{backend}: nie udało się pobrać/eksportować obrazu bazowego '{image}' do {rootPath}")
      return 1
    log(&"[zpm --building] ✔ bootstrap '{rootPath}' zakończony (obraz: {image})")
    if pkg == "base":
      return 0
  let installCmd = installCmdFor(backend, pkg)
  if installCmd.len == 0:
    log(&"[zpm --building] ✘ {pkg}@{backend}: brak zdefiniowanej komendy instalacji dla backendu '{backend}'")
    return 1
  runInChroot(rootPath, installCmd)

proc removeCmdFor(backend, pkg: string): string =
  case backend
  of "apt": &"apt-get remove -y {pkg}"
  of "dnf": &"dnf remove -y {pkg}"
  of "pacman": &"pacman -R --noconfirm {pkg}"
  of "zypper": &"zypper --non-interactive remove {pkg}"
  else: ""

proc installIntoRootWithBackend(rootPath: string, spec: PackageSpec, cfg: ZpmConfig): int =
  ## Deleguje instalację "per-pakiet" do menedżera bazowego, ale z flagą
  ## roota/sysroota, tak żeby nic nie trafiło na system, na którym
  ## budujemy obraz.
  let pkg = spec.name
  case spec.backend
  of "apt", "dnf", "pacman", "zypper":
    result = installNativeDistroPackage(cfg, spec.backend, pkg, rootPath)
  of "brew":
    # Linuxbrew do sysroota obrazu: instalujemy do własnego prefiksu
    # osadzonego pod rootPath/opt/homebrew, żeby nie dotykać hosta.
    let brewPrefix = rootPath / "opt" / "homebrew"
    createDir(brewPrefix)
    result = execCmd(&"HOMEBREW_PREFIX={brewPrefix} brew install --appdir={brewPrefix} {pkg}")
  of "flatpak":
    # NAPRAWIONE: `flatpak install -y flathub {pkg}` zakładało, że remote
    # "flathub" już istnieje w świeżo zbootstrapowanym rootfs -- nigdy nie
    # jest dodawany, więc zawsze kończyło się "No remote refs found for
    # 'flathub'". `--if-not-exists` czyni to idempotentnym (bezpieczne przy
    # kolejnych pakietach flatpak w tym samym module).
    result = runInChroot(rootPath,
      "flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo && " &
      &"flatpak install -y flathub {pkg}")
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
    #
    # v0.6: TO SAMO dla WERSJI (nie branch) -- `zlb` koduje opcjonalny
    # `version = "..."` z package.list wprost w nazwie pakietu jako
    # "nazwa@wersja" (patrz PackageEntry.version w zlb i entryArg tamże),
    # dokładnie w tej samej składni co `zpm own install <nazwa>@<wersja>`
    # z linii poleceń -- `splitOwnNameVersion` (ownrepo.nim) obsługuje OBIE
    # ścieżki identycznie. Podanie wersji na sztywno w package.list
    # całkowicie omija zapytanie "jaka jest najnowsza wersja" do
    # api.github.com (patrz resolveVersionPlaceholder) -- bez sieci, bez
    # zużywania limitu, przewidywalne buildy.
    let (realPkg, requestedVer) = splitOwnNameVersion(pkg)
    var branchFor = initTable[string, string]()
    if spec.variant.len > 0: branchFor[realPkg] = spec.variant
    var versionFor = initTable[string, string]()
    if requestedVer.len > 0: versionFor[realPkg] = requestedVer
    result = if installManyOwn(repo, cfg, @[realPkg], destDir, rootPath, false, branchFor, versionFor): 0 else: 1
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
    of "apt", "dnf", "pacman", "zypper":
      # v0.4: tak samo jak przy instalacji -- rootPath ma już WŁASNY
      # menedżer pakietów w środku (skoro coś w ogóle było zainstalowane
      # przez installNativeDistroPackage), więc usuwanie leci przez
      # dokładnie ten sam `runInChroot`, zamiast nieistniejącej flagi
      # `--root` na menedżerze hosta.
      let cmd = removeCmdFor(pkgBackend, spec.name)
      if cmd.len > 0: discard runInChroot(rootPath, cmd)
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
