import std/[os, osproc, strformat, strutils, times]
import ./types
import ./config

type
  BuildTarget* = object
    rootPath*: string          ## katalog docelowy (przyszły / obrazu)
    packages*: seq[string]     ## lista pakietów do zainstalowania
    backend*: string           ## który menedżer bazowy budować (apt/dnf/pacman/...)
    logPath*: string

proc ensureBuildLog(cfg: ZpmConfig): string =
  createDir(cfg.buildingCacheDir)
  let stamp = now().format("yyyyMMdd-HHmmss")
  result = cfg.buildingCacheDir / &"build-{stamp}.log"

proc logLine(path, msg: string) =
  let f = open(path, fmAppend)
  defer: f.close()
  f.writeLine(&"[{$now()}] {msg}")

proc installIntoRoot(target: BuildTarget, pkg: string): int =
  ## Deleguje instalację "per-pakiet" do menedżera bazowego, ale z flagą
  ## roota/sysroota, tak żeby nic nie trafiło na system, na którym
  ## budujemy obraz.
  case target.backend
  of "apt":
    result = execCmd(&"sudo apt install -y --root={target.rootPath} {pkg}")
  of "dnf":
    result = execCmd(&"sudo dnf install -y --installroot={target.rootPath} {pkg}")
  of "pacman":
    result = execCmd(&"sudo pacman -S --noconfirm --root {target.rootPath} {pkg}")
  of "zypper":
    result = execCmd(&"sudo zypper --root {target.rootPath} install -y {pkg}")
  else:
    echo &"[zpm --building] Nieznany backend budowania: {target.backend}"
    result = 1

proc runBuilding*(cfg: ZpmConfig, rootPath, backend: string, packages: seq[string]) =
  if rootPath.len == 0:
    echo "[zpm --building] Wymagana flaga --root=<ścieżka> wskazująca katalog docelowy obrazu."
    quit(1)

  if not dirExists(rootPath):
    echo &"[zpm --building] Tworzę katalog docelowy: {rootPath}"
    createDir(rootPath)

  let logPath = ensureBuildLog(cfg)
  let target = BuildTarget(rootPath: rootPath, packages: packages, backend: backend, logPath: logPath)

  echo &"[zpm --building] Cel budowania: {rootPath}  (backend bazowy: {backend})"
  echo &"[zpm --building] Log: {logPath}"
  logLine(logPath, &"START build root={rootPath} backend={backend} packages={packages}")

  var failed: seq[string] = @[]
  for pkg in packages:
    echo &"[zpm --building] -> instaluję {pkg} do {rootPath}"
    let code = installIntoRoot(target, pkg)
    logLine(logPath, &"install {pkg} -> exit={code}")
    if code != 0:
      failed.add(pkg)

  if failed.len == 0:
    echo &"[zpm --building] ✔ Zbudowano rootfs/obraz z {packages.len} pakietami."
  else:
    let failedStr = failed.join(", ")
    echo &"[zpm --building] ✘ Nie udało się zainstalować: {failedStr}"
    quit(1)
