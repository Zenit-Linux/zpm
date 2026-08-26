import std/[os, strutils, strformat, tables]
import ./hcl
import ./types

const DefaultConfigPath* = "/etc/zpm/config.hcl"

proc backendFromStr*(s: string): BackendKind =
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
  of "brew": bkBrew
  of "own": bkOwn
  of "zenit": bkZenitNat
  else: bkApt  # bezpieczny fallback, walidowany wyżej

proc defaultConfig*(): ZpmConfig =
  ZpmConfig(
    dbPath: "/var/lib/zpm/zpm.db",
    enabledBackends: @[bkApt, bkDnf, bkPacman, bkZypper, bkFlatpak, bkSnap, bkCargo, bkPip, bkNpm, bkBrew, bkOwn],
    parallelUpdates: true,
    confirmBeforeInstall: true,
    preferredOrder: @[bkOwn, bkFlatpak, bkApt, bkDnf, bkPacman, bkZypper, bkSnap, bkBrew, bkCargo, bkPip, bkNpm],
    atomicStorePath: "/var/lib/zpm/atomic",
    buildingCacheDir: "/var/cache/zpm/building",
    customRepoPath: "/etc/zpm/custom/own-repository.json",
    ownRepoUrl: "https://raw.githubusercontent.com/Zenit-Linux/own-repository/main/repo/own-repository.json",
    ownToolsInstallDir: "/usr/local/bin",
    ownGitCacheDir: "/var/cache/zpm/own-src",
    defaultBuildingBackend: "apt",

    lockPath: "/etc/zpm/zpm.lock",
    sourceDateEpoch: 0,

    offlineMode: false,
    vendorSources: false,

    verifySignatures: true,
    requirePinnedRef: true,
    sandboxEnabled: true,
    sandboxCmd: "bwrap",
    sandboxRequired: true,
    buildTimeoutSec: 3600,
    buildMemoryLimit: "",
    buildCpuQuota: "",
    strictResourceLimits: false,

    trustedHosts: @[],
    pinnedCertSha256: @[],
    maxDownloadMb: 0,
    httpCacheDir: "/var/cache/zpm/http",

    rollbackOnFailure: true,

    trustedKeysStatePath: "/var/lib/zpm/trusted-keys.list",

    buildIsolation: "bwrap",
    buildIsolationImage: "docker.io/library/debian:stable",

    crossDistroImages: initTable[string, string](),

    lockTimeoutSec: 120,

    ownStateDir: "/var/lib/zpm/own-installed",
    nativeStateDir: "/var/lib/zpm/native-installed",

    jsonOutput: false,
    verbosity: 0,

    targetArch: "",

    ccacheDir: "/var/cache/zpm/ccache",

    nativeRepoIndexUrl: "https://raw.githubusercontent.com/Zenit-Linux/zenit-repo/main/index.json",
    nativeRepoCacheDir: "/var/cache/zpm/native-repo",
    nativePackageOutDir: "/var/cache/zpm/packages"
  )

proc loadConfig*(path: string = DefaultConfigPath): ZpmConfig =
  ## Wczytuje konfigurację z pliku HCL. Jeśli plik nie istnieje,
  ## zwraca bezpieczne wartości domyślne (przydatne w prototypie / CI).
  result = defaultConfig()
  if not fileExists(path):
    return result

  let source = readFile(path)
  let root =
    try:
      parseHcl(source)
    except HclParseError as e:
      stderr.writeLine(&"[zpm:config] ✘ Błąd w {path}: {e.msg}")
      quit(1)

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
    result.defaultBuildingBackend = building.getStr("default_backend", result.defaultBuildingBackend)

  # ---- custom { } -- własny ekosystem Zenit -----------------------------
  let custom = root.findBlock("custom")
  if custom != nil:
    result.customRepoPath = custom.getStr("repository_path", result.customRepoPath)
    result.ownRepoUrl = custom.getStr("remote_url", result.ownRepoUrl)
    let mirrorsRaw = custom.getList("mirrors")
    if mirrorsRaw.len > 0:
      result.ownRepoMirrors = mirrorsRaw
    result.ownToolsInstallDir = custom.getStr("install_dir", result.ownToolsInstallDir)
    result.ownGitCacheDir = custom.getStr("git_cache_dir", result.ownGitCacheDir)
    result.vendorSources = custom.getBool("vendor_sources", result.vendorSources)

  # ---- reproducible { } -- zpm.lock, SOURCE_DATE_EPOCH -------------------
  let reproducible = root.findBlock("reproducible")
  if reproducible != nil:
    result.lockPath = reproducible.getStr("lock_path", result.lockPath)
    result.sourceDateEpoch = reproducible.getInt("source_date_epoch", 0).int64

  # ---- security { } -- podpisy, wymuszony pinning, piaskownica ----------
  let security = root.findBlock("security")
  if security != nil:
    result.verifySignatures = security.getBool("verify_signatures", result.verifySignatures)
    result.requirePinnedRef = security.getBool("require_pinned_ref", result.requirePinnedRef)
    result.sandboxEnabled = security.getBool("sandbox_enabled", result.sandboxEnabled)
    result.sandboxCmd = security.getStr("sandbox_cmd", result.sandboxCmd)
    result.sandboxRequired = security.getBool("sandbox_required", result.sandboxRequired)
    result.buildTimeoutSec = security.getInt("build_timeout_sec", result.buildTimeoutSec)
    result.buildMemoryLimit = security.getStr("build_memory_limit", result.buildMemoryLimit)
    result.buildCpuQuota = security.getStr("build_cpu_quota", result.buildCpuQuota)
    result.lockTimeoutSec = security.getInt("lock_timeout_sec", result.lockTimeoutSec)
    result.strictResourceLimits = security.getBool("strict_resource_limits", result.strictResourceLimits)
    let trustedHostsRaw = security.getList("trusted_hosts")
    if trustedHostsRaw.len > 0:
      result.trustedHosts = trustedHostsRaw
    let pinRaw = security.getList("pin_sha256")
    if pinRaw.len > 0:
      result.pinnedCertSha256 = pinRaw
    result.maxDownloadMb = security.getInt("max_download_mb", result.maxDownloadMb)
    result.rollbackOnFailure = security.getBool("rollback_on_failure", result.rollbackOnFailure)
    result.buildIsolation = security.getStr("build_isolation", result.buildIsolation)
    result.buildIsolationImage = security.getStr("build_isolation_image", result.buildIsolationImage)

  # ---- state { } -- pokwitowania instalacji (idempotencja, `zpm remove`) --
  let state = root.findBlock("state")
  if state != nil:
    result.ownStateDir = state.getStr("own_dir", result.ownStateDir)
    result.nativeStateDir = state.getStr("native_dir", result.nativeStateDir)
    result.trustedKeysStatePath = state.getStr("trusted_keys_path", result.trustedKeysStatePath)

  # ---- cache { } -- v0.2: cache HTTP (ETag/If-Modified-Since) -------------
  let cacheBlk = root.findBlock("cache")
  if cacheBlk != nil:
    result.httpCacheDir = cacheBlk.getStr("http_cache_dir", result.httpCacheDir)

  # ---- ccache { } -- cache budowania (ccache/sccache) ---------------------
  let ccache = root.findBlock("ccache")
  if ccache != nil:
    result.ccacheDir = ccache.getStr("dir", result.ccacheDir)

  # ---- native { } -- natywny format pakietów (.zpk / bkZenitNat) ----------
  let native = root.findBlock("native")
  if native != nil:
    result.nativeRepoIndexUrl = native.getStr("repo_index_url", result.nativeRepoIndexUrl)
    result.nativeRepoCacheDir = native.getStr("repo_cache_dir", result.nativeRepoCacheDir)
    result.nativePackageOutDir = native.getStr("package_out_dir", result.nativePackageOutDir)
    let distroImages = native.findBlock("distro_images")
    if distroImages != nil:
      for k, v in distroImages.attrs:
        if v.kind == hvString:
          result.crossDistroImages[k] = v.strVal
