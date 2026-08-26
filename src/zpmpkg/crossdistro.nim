import std/[os, osproc, strformat, strutils, tables]
import ./types
import ./logging
import ./containerengine
import ./stagingsafety

## v0.3 -- realizuje `pakiet -> backend -> dystrybucja[.suita]` z
## package.list (np. `git -> apt -> debian.testing`), czyli "zpm ma
## pobierać pakiety z różnych dystrybucji, żeby systemu nie wyjebało w
## powietrze" (dosłowny cytat z wymagań).
##
## DLACZEGO NIE po prostu dopisać repo Debiana do /etc/apt/sources.list
## hosta i zainstalować stamtąd: to jest DOKŁADNIE scenariusz "system
## wyleci w powietrze" -- mieszanie metadanych repo różnych dystrybucji
## (różne wersje libc, różne ABI, różne polityki wersjonowania pakietów)
## w JEDNEJ bazie APT/RPM hosta prowadzi do nierozwiązywalnych konfliktów
## zależności i, w najgorszym razie, do nadpisania systemowych bibliotek
## niekompatybilnymi wersjami.
##
## Zamiast tego: pakiet jest instalowany W IZOLOWANYM, EFEMERYCZNYM
## kontenerze OPARTYM O OBRAZ DOCELOWEJ DYSTRYBUCJI (więc jego menedżer
## pakietów widzi WYŁĄCZNIE własne, spójne repo tej dystrybucji -- zero
## mieszania metadanych). Do instalacji używany jest overlayfs (patrz
## containerengine.nim) -- warstwa "upper" to DOKŁADNIE zbiór plików
## nowo utworzonych/zmienionych przez tę jedną instalację. Ta warstwa
## jest następnie scalana do `rootPath` przez `safeMergeStaging`
## (stagingsafety.nim) -- TEN SAM mechanizm ochrony przed symlink-atakami
## i rollbackiem, którego już używa ekosystem `own`.
##
## UCZCIWIE: to NIE rozwiązuje transitywnych zależności MIĘDZY
## dystrybucjami (np. "ten .deb z Debiana linkuje się z libc, którego nie
## ma na hoście Arch Linux") -- to fundamentalnie trudny problem, który
## żaden menedżer pakietów nie rozwiązuje w pełni ogólnie. To, co ten
## mechanizm gwarantuje, to że host'a NIGDY nie da się uszkodzić przez
## sam AKT instalacji (repo hosta i repo dystrybucji docelowej nigdy się
## nie stykają) -- odpowiedzialność za sensowność WYNIKU (czy binarka z
## Debiana faktycznie coś zrobi na hoście Arch) zostaje po stronie
## operatora, dokładnie jak przy ręcznym kopiowaniu binarek między
## dystrybucjami.

const knownDistroImages = {
  "debian": "docker.io/library/debian",
  "ubuntu": "docker.io/library/ubuntu",
  "fedora": "docker.io/library/fedora",
  "arch": "docker.io/library/archlinux",
  "opensuse": "docker.io/opensuse/leap",
  "alpine": "docker.io/library/alpine",
}.toTable

const knownDistroBackend = {
  "debian": "apt", "ubuntu": "apt",
  "fedora": "dnf",
  "arch": "pacman",
  "opensuse": "zypper",
  "alpine": "apk",
}.toTable

proc splitDistroVariant*(variant: string): tuple[distro, suite: string] =
  ## "debian" -> ("debian", ""); "debian.testing" -> ("debian", "testing")
  let idx = variant.find('.')
  if idx < 0: return (variant.toLowerAscii, "")
  (variant[0 ..< idx].toLowerAscii, variant[idx+1 .. ^1])

proc distroImageFor*(cfg: ZpmConfig, distro, suite: string): string =
  ## `native.distro_images` w config.hcl może nadpisać/dodać mapowania
  ## (np. dystrybucje niebędące w `knownDistroImages`) -- patrz config.nim.
  if distro in cfg.crossDistroImages:
    let tmpl = cfg.crossDistroImages[distro]
    return if suite.len > 0: tmpl.replace("{suite}", suite) else: tmpl.replace(":{suite}", "")
  if distro notin knownDistroImages:
    return ""
  let base = knownDistroImages[distro]
  if suite.len > 0: &"{base}:{suite}" else: &"{base}:latest"

proc crossDistroInstall*(cfg: ZpmConfig, requestedBackend, variant, pkg, rootPath: string): tuple[ok: bool, err: string] =
  let (distro, suite) = splitDistroVariant(variant)
  if distro.len == 0:
    return (false, "pusta nazwa dystrybucji w wariancie cross-distro")

  let image = distroImageFor(cfg, distro, suite)
  if image.len == 0:
    return (false, &"nieznana dystrybucja '{distro}' -- dodaj mapowanie w native.distro_images " &
      "w config.hcl albo użyj jednej ze znanych: debian, ubuntu, fedora, arch, opensuse, alpine")

  let expectedBackend = knownDistroBackend.getOrDefault(distro, requestedBackend)
  if requestedBackend.len > 0 and requestedBackend != expectedBackend:
    logWarn(&"[zpm:crossdistro] Uwaga: żądano backendu '{requestedBackend}', ale '{distro}' natywnie używa " &
      &"'{expectedBackend}' -- używam '{expectedBackend}' (backend jest własnością DYSTRYBUCJI, nie wyboru operatora).")

  let engine = detectContainerEngine()
  if engine.len == 0:
    return (false, "instalacja cross-distro wymaga 'podman' albo 'buildah' w PATH (bezpieczna izolacja -- " &
      "patrz komentarz w crossdistro.nim o tym, dlaczego NIE mieszamy repo bezpośrednio na hoście)")

  let workDir = getTempDir() / &"zpm-xdistro-{distro}-{suite}-{pkg}-{getCurrentProcessId()}"
  createDir(workDir)
  defer:
    unmountOverlay(workDir)
    removeDir(workDir)

  log(&"[zpm:crossdistro] Instaluję '{pkg}' z {distro}{(if suite.len > 0: \".\" & suite else: \"\")} " &
    &"(obraz: {image}, silnik: {engine}) w izolowanym kontenerze...")

  if not exportImageToLower(engine, image, workDir / "lower"):
    return (false, &"nie udało się pobrać/eksportować obrazu bazowego '{image}'")

  let (mountOk, mountErr) = mountOverlay(workDir)
  if not mountOk:
    return (false, mountErr)

  let installCmd = installCmdFor(expectedBackend, pkg)
  if installCmd.len == 0:
    return (false, &"brak zdefiniowanej komendy instalacji dla backendu '{expectedBackend}'")

  # Instalacja bezpośrednio w zamontowanym rootfs przez chroot -- bez
  # tworzenia dodatkowego, osobnego kontenera na TĘ operację (mamy już
  # zamontowany, zapisywalny overlay w workDir/rootfs).
  let code = execCmd(&"chroot \"{workDir / \"rootfs\"}\" sh -c '{installCmd}'")
  if code != 0:
    return (false, &"instalacja '{pkg}' w chroot ({distro}{(if suite.len > 0: \".\" & suite else: \"\")}) nie powiodła się")

  # Warstwa "upper" to DOKŁADNIE diff tej jednej instalacji -- scalamy ją
  # (bezpiecznie, z ochroną przed symlinkami i rollbackiem) do rootPath.
  let mergeResult = safeMergeStaging(workDir / "upper", rootPath)
  if not mergeResult.ok:
    return (false, &"merge wyniku instalacji '{pkg}' do {rootPath} nie powiódł się: {mergeResult.error}")

  log(&"[zpm:crossdistro] ✔ '{pkg}' z {distro}{(if suite.len > 0: \".\" & suite else: \"\")} scalony do {rootPath} " &
    &"({mergeResult.createdPaths.len} nowych plików/katalogów).")
  (true, "")
