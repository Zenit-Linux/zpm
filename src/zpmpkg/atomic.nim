import std/[os, osproc, strformat, strutils, json, times]
import ./types
import ./config

type
  AtomicContainer* = object
    name*: string
    path*: string             ## katalog kontenera w atomicStorePath
    createdAt*: string
    packages*: seq[string]
    baseImage*: string

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
    "baseImage": c.baseImage
  }
  writeFile(metaPath(cfg, c.name), pretty(j))

proc loadMeta(cfg: ZpmConfig, name: string): AtomicContainer =
  let j = parseJson(readFile(metaPath(cfg, name)))
  result = AtomicContainer(
    name: name,
    path: containerDir(cfg, name),
    createdAt: j["createdAt"].getStr(),
    packages: @[],
    baseImage: j["baseImage"].getStr()
  )
  for p in j["packages"]:
    result.packages.add(p.getStr())

proc atomicCreate*(cfg: ZpmConfig, name, baseImage: string) =
  if containerExists(cfg, name):
    echo &"[zpm:atomic] Kontener '{name}' już istnieje."
    return
  createDir(cfg.atomicStorePath)
  let dir = containerDir(cfg, name)
  createDir(dir)
  createDir(dir / "rootfs")
  createDir(dir / "upper")   # warstwa overlayfs do zapisu
  createDir(dir / "work")    # katalog roboczy overlayfs

  echo &"[zpm:atomic] Tworzę atomowy kontener '{name}' (baza: {baseImage})..."
  # Prototyp: jeśli dostępny jest podman/buildah, użyj go do pobrania bazy.
  if findExe("podman").len > 0:
    let code = execCmd(&"podman create --name zpm-{name} {baseImage} sleep infinity")
    if code != 0:
      echo "[zpm:atomic] Ostrzeżenie: podman nie utworzył kontenera bazowego (kontynuuję jako pusty rootfs)."
  else:
    echo "[zpm:atomic] Uwaga: podman nie znaleziony — tworzę pusty szkielet rootfs (tryb offline/prototyp)."

  let c = AtomicContainer(name: name, path: dir, createdAt: $now(), packages: @[], baseImage: baseImage)
  saveMeta(cfg, c)
  echo &"[zpm:atomic] ✔ Kontener '{name}' gotowy w {dir}"

proc atomicInstall*(cfg: ZpmConfig, name, pkg: string) =
  if not containerExists(cfg, name):
    echo &"[zpm:atomic] Kontener '{name}' nie istnieje — użyj najpierw `zpm atomic create {name}`."
    return
  var c = loadMeta(cfg, name)
  echo &"[zpm:atomic] Instaluję '{pkg}' w izolacji wewnątrz kontenera '{name}'..."

  if findExe("podman").len > 0:
    discard execCmd(&"podman start zpm-{name}")
    let code = execCmd(&"podman exec zpm-{name} sh -c 'apt install -y {pkg} || dnf install -y {pkg} || pacman -S --noconfirm {pkg}'")
    if code != 0:
      echo "[zpm:atomic] ✘ Instalacja w kontenerze nie powiodła się."
      return
  else:
    echo "[zpm:atomic] (prototyp offline) Symuluję instalację — brak podmana w środowisku."

  c.packages.add(pkg)
  saveMeta(cfg, c)
  echo &"[zpm:atomic] ✔ '{pkg}' dodany do kontenera '{name}'."

proc atomicList*(cfg: ZpmConfig) =
  if not dirExists(cfg.atomicStorePath):
    echo "[zpm:atomic] Brak utworzonych kontenerów atomowych."
    return
  echo "[zpm:atomic] Kontenery atomowe:"
  for kind, path in walkDir(cfg.atomicStorePath):
    if kind == pcDir:
      let name = path.extractFilename()
      try:
        let c = loadMeta(cfg, name)
        echo &"  - {c.name}  (baza: {c.baseImage}, pakiety: {c.packages.len}, utworzono: {c.createdAt})"
      except CatchableError:
        echo &"  - {name}  (brak metadanych — kontener uszkodzony?)"

proc atomicEnter*(cfg: ZpmConfig, name: string) =
  if not containerExists(cfg, name):
    echo &"[zpm:atomic] Kontener '{name}' nie istnieje."
    return
  if findExe("podman").len > 0:
    discard execCmd(&"podman start zpm-{name}")
    discard execCmd(&"podman exec -it zpm-{name} /bin/bash")
  else:
    echo "[zpm:atomic] Brak podmana — nie mogę wejść interaktywnie w tym środowisku prototypowym."

proc atomicDestroy*(cfg: ZpmConfig, name: string) =
  if not containerExists(cfg, name):
    echo &"[zpm:atomic] Kontener '{name}' nie istnieje."
    return
  if findExe("podman").len > 0:
    discard execCmd(&"podman rm -f zpm-{name}")
  removeDir(containerDir(cfg, name))
  echo &"[zpm:atomic] ✔ Kontener '{name}' zniszczony."

proc runAtomicCli*(cfg: ZpmConfig, args: seq[string]) =
  ## Router poleceń dla trybu atomowego: zpm atomic <subkomenda> ...
  if args.len == 0:
    echo "[zpm:atomic] Użycie: zpm atomic <create|install|enter|list|destroy> [argumenty]"
    return

  case args[0]
  of "create":
    if args.len < 2:
      echo "[zpm:atomic] Użycie: zpm atomic create <nazwa> [--base=obraz]"
      return
    var base = "docker.io/library/debian:stable"
    for a in args[2..^1]:
      if a.startsWith("--base="):
        base = a.split("=", maxsplit = 1)[1]
    atomicCreate(cfg, args[1], base)
  of "install":
    if args.len < 3:
      echo "[zpm:atomic] Użycie: zpm atomic install <kontener> <pakiet>"
      return
    atomicInstall(cfg, args[1], args[2])
  of "enter":
    if args.len < 2:
      echo "[zpm:atomic] Użycie: zpm atomic enter <kontener>"
      return
    atomicEnter(cfg, args[1])
  of "list":
    atomicList(cfg)
  of "destroy":
    if args.len < 2:
      echo "[zpm:atomic] Użycie: zpm atomic destroy <kontener>"
      return
    atomicDestroy(cfg, args[1])
  else:
    echo &"[zpm:atomic] Nieznana subkomenda: {args[0]}"
