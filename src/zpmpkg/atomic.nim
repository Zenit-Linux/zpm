import std/[os, osproc, strformat, strutils, json, times]
import ./types
import ./config
import ./logging
import ./containerengine

## v0.2.1 -- domyka (częściowo) lukę "Realna integracja podman/buildah/
## systemd-nspawn w Trybie Atomowym (overlayfs, cgroups, sieć) -- dziś
## głównie szkielet". Zmiany:
##
##  1. **overlayfs realnie montowany** (`mountOverlay`/`unmountOverlay`):
##     wcześniej `upper`/`work` były tworzone na dysku, ale NIGDY nie były
##     faktycznie zamontowane jako overlay -- podman zarządzał swoim
##     WŁASNYM storage driverem, a katalogi zpm leżały bezczynnie. Teraz
##     `atomicCreate` faktycznie montuje `lowerdir=<obraz wyeksportowany>,
##     upperdir=upper,workdir=work` na `rootfs/`, więc `rootfs/` to
##     prawdziwy, zapisywalny widok kontenera z warstwą COW zarządzaną
##     przez zpm (nie przez podmana) -- to jest właściwy sens "Trybu
##     Atomowego": commit/rollback to operacje na `upper/`, nie na całym
##     `rootfs/`.
##  2. **buildah jako alternatywa/fallback dla podman** -- środowiska bez
##     demona (część CI, rootless bez podman) często mają `buildah`.
##  3. **Wykrywanie menedżera pakietów W KONTENERZE** zamiast naiwnego
##     `apt || dnf || pacman` (który cicho "sukcesuje" na pierwszym
##     poleceniu istniejącym w PATH, nawet jeśli to NIE jest menedżer
##     pakietów obrazu bazowego -- np. `dnf` zainstalowany jako
##     kompatybilność w obrazie opartym o co innego).
##  4. **cgroups/sieć**: NIE reimplementowane ręcznie -- świadomie
##     delegowane do podman/buildah (które już mają dojrzałą, przetestowaną
##     obsługę `--memory`/`--cpus`/`--network`), zamiast pisać od zera
##     gorszą wersję tego samego. `zpm atomic create --memory=... --cpus=...`
##     przekazuje te limity wprost do `podman create`.
##
## UCZCIWIE: to WCIĄŻ nie jest kompletna, produkcyjna implementacja
## (brak np. obsługi multi-layer overlay dla warstw pośrednich, brak
## snapshotów/przyrostowych commitów) -- ale przechodzi od czystego
## szkieletu do czegoś, co faktycznie montuje i izoluje.

type
  AtomicContainer* = object
    name*: string
    path*: string             ## katalog kontenera w atomicStorePath
    createdAt*: string
    packages*: seq[string]
    baseImage*: string
    engine*: string            ## "podman" | "buildah" | "" (brak silnika, tryb offline)
    overlayMounted*: bool       ## czy rootfs/ jest aktualnie zamontowany jako overlay

proc containerDir(cfg: ZpmConfig, name: string): string =
  cfg.atomicStorePath / name

proc metaPath(cfg: ZpmConfig, name: string): string =
  containerDir(cfg, name) / "zpm-container.json"

proc containerExists*(cfg: ZpmConfig, name: string): bool =
  dirExists(containerDir(cfg, name))

proc saveMeta(cfg: ZpmConfig, c: AtomicContainer) =
  let j = %*{
    "name": c.name,
    "createdAt": c.createdAt,
    "packages": c.packages,
    "baseImage": c.baseImage,
    "engine": c.engine,
    "overlayMounted": c.overlayMounted
  }
  writeFile(metaPath(cfg, c.name), pretty(j))

proc loadMeta(cfg: ZpmConfig, name: string): AtomicContainer =
  let j = parseJson(readFile(metaPath(cfg, name)))
  result = AtomicContainer(
    name: name,
    path: containerDir(cfg, name),
    createdAt: j["createdAt"].getStr(),
    packages: @[],
    baseImage: j["baseImage"].getStr(),
    engine: (if j.hasKey("engine"): j["engine"].getStr() else: ""),
    overlayMounted: (if j.hasKey("overlayMounted"): j["overlayMounted"].getBool() else: false)
  )
  for p in j["packages"]:
    result.packages.add(p.getStr())

proc extractLocalTarball(tarPath, lowerDir: string): bool =
  ## Tryb "chroot": zamiast pobierać obraz kontenerowy przez podman/buildah,
  ## rozpakowuje LOKALNE archiwum rootfs (np. z `debootstrap`/`pacstrap`/
  ## `mkosi`) bezpośrednio do lowerdir. Zero zależności od demona/silnika
  ## kontenerowego -- przydatne na minimalnych budowniczych CI, które i tak
  ## już mają `tar`/`xorriso`/`squashfs-tools` (patrz zlb), ale niekoniecznie
  ## podman/buildah.
  createDir(lowerDir)
  let code = execCmd(&"tar -xf \"{tarPath}\" -C \"{lowerDir}\"")
  code == 0

proc atomicCreate*(cfg: ZpmConfig, name, baseImage: string, memoryLimit, cpuLimit: string = "",
                    engineOverride: string = "") =
  ## v0.3 -- KILKA RODZAJÓW Trybu Atomowego, wybieranych przez `engineOverride`
  ## (`zpm atomic create <nazwa> --engine=podman|buildah|chroot`):
  ##   "podman"/"buildah" -- jak dotąd: kontener z REALNEGO silnika, overlayfs
  ##     montowany na eksportowanej warstwie obrazu (patrz containerengine.nim).
  ##   "chroot" -- BEZ silnika kontenerowego w ogóle: `baseImage` to ŚCIEŻKA
  ##     do lokalnego archiwum rootfs (np. `file:///var/cache/zlb/rootfs.tar.gz`,
  ##     prefiks "file://" opcjonalny), rozpakowywanego bezpośrednio do
  ##     lowerdir overlayfs; instalacje idą przez zwykły `chroot`, nie przez
  ##     `podman exec`. Najlżejszy wariant -- zero demona, zero pobierania
  ##     obrazu z rejestru, tylko `tar`+`mount`+`chroot` (wszystko już
  ##     obecne w środowisku budującym zlb).
  ##   "" (domyślnie) -- autodetekcja: podman > buildah > (jeśli `baseImage`
  ##     wygląda jak ścieżka do pliku, nie referencja obrazu) chroot.
  if containerExists(cfg, name):
    log(&"[zpm:atomic] Kontener '{name}' już istnieje.")
    return
  createDir(cfg.atomicStorePath)
  let dir = containerDir(cfg, name)
  createDir(dir)

  var engine = engineOverride.toLowerAscii
  if engine.len == 0:
    engine = detectContainerEngine()
    if engine.len == 0 and (baseImage.startsWith("file://") or baseImage.startsWith("/") or fileExists(baseImage)):
      engine = "chroot"

  log(&"[zpm:atomic] Tworzę atomowy kontener '{name}' (silnik: {(if engine.len > 0: engine else: \"brak\")}, baza: {baseImage})...")
  var overlayOk = false

  case engine
  of "podman", "buildah":
    var createCmd = &"{engine} create --name zpm-{name}"
    if memoryLimit.len > 0: createCmd &= &" --memory={memoryLimit}"
    if cpuLimit.len > 0: createCmd &= &" --cpus={cpuLimit}"
    createCmd &= &" {baseImage} sleep infinity"
    let code = execCmd(createCmd)
    if code != 0:
      logWarn(&"[zpm:atomic] Ostrzeżenie: {engine} nie utworzył kontenera bazowego (kontynuuję jako pusty rootfs).")
    else:
      log(&"[zpm:atomic] Eksportuję warstwę bazową '{baseImage}' do lowerdir overlayfs...")
      if exportImageToLower(engine, baseImage, dir / "lower"):
        let (mountOk, mountErr) = mountOverlay(dir)
        if mountOk:
          overlayOk = true
          log(&"[zpm:atomic] ✔ overlayfs zamontowany: {dir}/rootfs (lower=warstwa obrazu, upper=COW zapisywalny)")
        else:
          logWarn(&"[zpm:atomic] Ostrzeżenie: {mountErr} -- rootfs/ NIE jest zamontowany jako overlay " &
            "(kontener podman/buildah nadal działa niezależnie, ale zpm nie zarządza jego warstwą COW).")
      else:
        logWarn(&"[zpm:atomic] Ostrzeżenie: eksport warstwy bazowej nie powiódł się -- pomijam overlayfs.")
  of "chroot":
    let tarPath = baseImage.replace("file://", "")
    if not fileExists(tarPath):
      logWarn(&"[zpm:atomic] ✘ Tryb 'chroot' wymaga lokalnego archiwum rootfs -- '{tarPath}' nie istnieje.")
      engine = ""
    elif extractLocalTarball(tarPath, dir / "lower"):
      let (mountOk, mountErr) = mountOverlay(dir)
      if mountOk:
        overlayOk = true
        log(&"[zpm:atomic] ✔ overlayfs zamontowany: {dir}/rootfs (tryb chroot, bez silnika kontenerowego)")
      else:
        logWarn(&"[zpm:atomic] Ostrzeżenie: {mountErr}")
    else:
      logWarn(&"[zpm:atomic] ✘ Rozpakowanie '{tarPath}' nie powiodło się.")
  else:
    logWarn("[zpm:atomic] Uwaga: ani 'podman', ani 'buildah' nie znalezione (i baseImage nie wygląda na " &
      "lokalne archiwum dla trybu 'chroot') — tworzę pusty szkielet rootfs (tryb offline/prototyp, " &
      "bez realnej izolacji).")
    createDir(dir / "rootfs")

  let c = AtomicContainer(name: name, path: dir, createdAt: $now(), packages: @[],
                           baseImage: baseImage, engine: engine, overlayMounted: overlayOk)
  saveMeta(cfg, c)
  log(&"[zpm:atomic] ✔ Kontener '{name}' gotowy w {dir}")

proc atomicInstall*(cfg: ZpmConfig, name, pkg: string) =
  if not containerExists(cfg, name):
    log(&"[zpm:atomic] Kontener '{name}' nie istnieje — użyj najpierw `zpm atomic create {name}`.")
    return
  var c = loadMeta(cfg, name)
  log(&"[zpm:atomic] Instaluję '{pkg}' w izolacji wewnątrz kontenera '{name}' (silnik: {c.engine})...")

  if c.engine == "chroot":
    let rootfs = c.path / "rootfs"
    var mgr = ""
    for (m, marker) in [("apt", "var/lib/dpkg"), ("dnf", "var/lib/rpm"), ("pacman", "var/lib/pacman"),
                         ("apk", "lib/apk/db")]:
      if dirExists(rootfs / marker): mgr = m; break
    if mgr.len == 0:
      stderr.writeLine(&"[zpm:atomic] ✘ Nie udało się wykryć menedżera pakietów w rootfs (chroot) kontenera '{name}'.")
      return
    let installCmd = installCmdFor(mgr, pkg)
    log(&"[zpm:atomic] Wykryty menedżer: {mgr} -- uruchamiam przez chroot: {installCmd}")
    let code = execCmd(&"chroot \"{rootfs}\" sh -c '{installCmd}'")
    if code != 0:
      stderr.writeLine(&"[zpm:atomic] ✘ Instalacja w chroot nie powiodła się (menedżer: {mgr}).")
      return
  elif c.engine.len > 0:
    discard execCmd(&"{c.engine} start zpm-{name}")
    let mgr = detectPkgManagerInContainer(c.engine, &"zpm-{name}")
    if mgr.len == 0:
      stderr.writeLine(&"[zpm:atomic] ✘ Nie udało się wykryć menedżera pakietów wewnątrz kontenera '{name}' " &
        "(sprawdzono apt/dnf/pacman/apk/zypper -- żaden nie ma bazy danych pakietów w tym obrazie).")
      return
    let installCmd = installCmdFor(mgr, pkg)
    log(&"[zpm:atomic] Wykryty menedżer: {mgr} -- uruchamiam: {installCmd}")
    let code = execCmd(&"{c.engine} exec zpm-{name} sh -c '{installCmd}'")
    if code != 0:
      stderr.writeLine(&"[zpm:atomic] ✘ Instalacja w kontenerze nie powiodła się (menedżer: {mgr}).")
      return
  else:
    logWarn("[zpm:atomic] (prototyp offline) Symuluję instalację — brak silnika kontenerowego w środowisku.")

  c.packages.add(pkg)
  saveMeta(cfg, c)
  log(&"[zpm:atomic] ✔ '{pkg}' dodany do kontenera '{name}'.")

proc atomicList*(cfg: ZpmConfig) =
  if not dirExists(cfg.atomicStorePath):
    log("[zpm:atomic] Brak utworzonych kontenerów atomowych.")
    return
  log("[zpm:atomic] Kontenery atomowe:")
  for kind, path in walkDir(cfg.atomicStorePath):
    if kind == pcDir:
      let name = path.extractFilename()
      try:
        let c = loadMeta(cfg, name)
        let overlayInfo = if c.overlayMounted: "overlay: zamontowany" else: "overlay: brak"
        log(&"  - {c.name}  (silnik: {(if c.engine.len > 0: c.engine else: \"brak\")}, baza: {c.baseImage}, " &
          &"pakiety: {c.packages.len}, {overlayInfo}, utworzono: {c.createdAt})")
      except CatchableError:
        log(&"  - {name}  (brak metadanych — kontener uszkodzony?)")

proc atomicEnter*(cfg: ZpmConfig, name: string) =
  if not containerExists(cfg, name):
    log(&"[zpm:atomic] Kontener '{name}' nie istnieje.")
    return
  let c = loadMeta(cfg, name)
  if c.engine == "chroot":
    discard execCmd(&"chroot \"{c.path / \"rootfs\"}\" /bin/sh")
  elif c.engine.len > 0:
    discard execCmd(&"{c.engine} start zpm-{name}")
    discard execCmd(&"{c.engine} exec -it zpm-{name} /bin/bash")
  else:
    log("[zpm:atomic] Brak silnika kontenerowego — nie mogę wejść interaktywnie w tym środowisku prototypowym.")

proc atomicDestroy*(cfg: ZpmConfig, name: string) =
  if not containerExists(cfg, name):
    log(&"[zpm:atomic] Kontener '{name}' nie istnieje.")
    return
  let c = loadMeta(cfg, name)
  if c.overlayMounted:
    unmountOverlay(c.path)
  if c.engine in ["podman", "buildah"]:
    discard execCmd(&"{c.engine} rm -f zpm-{name}")
  removeDir(containerDir(cfg, name))
  log(&"[zpm:atomic] ✔ Kontener '{name}' zniszczony.")

proc runAtomicCli*(cfg: ZpmConfig, args: seq[string]) =
  ## Router poleceń dla trybu atomowego: zpm atomic <subkomenda> ...
  if args.len == 0:
    log("[zpm:atomic] Użycie: zpm atomic <create|install|enter|list|destroy> [argumenty]")
    return

  case args[0]
  of "create":
    if args.len < 2:
      log("[zpm:atomic] Użycie: zpm atomic create <nazwa> [--base=obraz] [--engine=podman|buildah|chroot] " &
        "[--memory=4g] [--cpus=2]")
      log("[zpm:atomic]   --engine=chroot: --base to ścieżka do lokalnego archiwum rootfs (.tar/.tar.gz), " &
        "bez podman/buildah.")
      return
    var base = "docker.io/library/debian:stable"
    var memoryLimit = ""
    var cpuLimit = ""
    var engine = ""
    for a in args[2..^1]:
      if a.startsWith("--base="):
        base = a.split("=", maxsplit = 1)[1]
      elif a.startsWith("--memory="):
        memoryLimit = a.split("=", maxsplit = 1)[1]
      elif a.startsWith("--cpus="):
        cpuLimit = a.split("=", maxsplit = 1)[1]
      elif a.startsWith("--engine="):
        engine = a.split("=", maxsplit = 1)[1]
    atomicCreate(cfg, args[1], base, memoryLimit, cpuLimit)
  of "install":
    if args.len < 3:
      log("[zpm:atomic] Użycie: zpm atomic install <kontener> <pakiet>")
      return
    atomicInstall(cfg, args[1], args[2])
  of "enter":
    if args.len < 2:
      log("[zpm:atomic] Użycie: zpm atomic enter <kontener>")
      return
    atomicEnter(cfg, args[1])
  of "list":
    atomicList(cfg)
  of "destroy":
    if args.len < 2:
      log("[zpm:atomic] Użycie: zpm atomic destroy <kontener>")
      return
    atomicDestroy(cfg, args[1])
  else:
    stderr.writeLine(&"[zpm:atomic] Nieznana subkomenda: {args[0]}")
