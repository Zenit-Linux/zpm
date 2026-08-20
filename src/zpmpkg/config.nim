import std/[os, strutils]
import ./hcl
import ./types

const DefaultConfigPath* = "/etc/zpm/config.hcl"

proc backendFromStr(s: string): BackendKind =
  case s.toLowerAscii()
  of "apt": bkApt
  of "dnf": bkDnf
  of "pacman": bkPacman
  of "zypper": bkZypper
  of "flatpak": bkFlatpak
  of "snap": bkSnap
  of "cargo": bkCargo
  of "pip": bkPip
  of "npm": bkNpm
  of "zenith": bkZenithNat
  else: bkApt  # bezpieczny fallback, walidowany wyżej

proc defaultConfig*(): ZpmConfig =
  ZpmConfig(
    dbPath: "/var/lib/zpm/zpm.db",
    enabledBackends: @[bkApt, bkDnf, bkPacman, bkZypper, bkFlatpak, bkSnap, bkCargo, bkPip, bkNpm],
    parallelUpdates: true,
    confirmBeforeInstall: true,
    preferredOrder: @[bkFlatpak, bkApt, bkDnf, bkPacman, bkZypper, bkSnap, bkCargo, bkPip, bkNpm],
    atomicStorePath: "/var/lib/zpm/atomic",
    buildingCacheDir: "/var/cache/zpm/building"
  )

proc loadConfig*(path: string = DefaultConfigPath): ZpmConfig =
  ## Wczytuje konfigurację z pliku HCL. Jeśli plik nie istnieje,
  ## zwraca bezpieczne wartości domyślne (przydatne w prototypie / CI).
  result = defaultConfig()
  if not fileExists(path):
    return result

  let source = readFile(path)
  let root = parseHcl(source)

  let core = root.findBlock("core")
  if core != nil:
    result.dbPath = core.getStr("db_path", result.dbPath)
    result.parallelUpdates = core.getBool("parallel_updates", result.parallelUpdates)
    result.confirmBeforeInstall = core.getBool("confirm_before_install", result.confirmBeforeInstall)

  let backends = root.findBlock("backends")
  if backends != nil:
    let enabledRaw = backends.getList("enabled")
    if enabledRaw.len > 0:
      result.enabledBackends = @[]
      for b in enabledRaw:
        result.enabledBackends.add(backendFromStr(b))
    let prefRaw = backends.getList("preferred_order")
    if prefRaw.len > 0:
      result.preferredOrder = @[]
      for b in prefRaw:
        result.preferredOrder.add(backendFromStr(b))

  let atomic = root.findBlock("atomic")
  if atomic != nil:
    result.atomicStorePath = atomic.getStr("store_path", result.atomicStorePath)

  let building = root.findBlock("building")
  if building != nil:
    result.buildingCacheDir = building.getStr("cache_dir", result.buildingCacheDir)
