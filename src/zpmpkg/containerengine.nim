import std/[os, osproc, strformat, strutils]

## v0.3 -- wspólne prymitywy silnika kontenerów, wyodrębnione z atomic.nim
## (który zostaje "właścicielem" komend `zpm atomic ...`), żeby dokładnie
## te same, przetestowane w Trybie Atomowym mechanizmy (overlayfs,
## wykrywanie podman/buildah, wykrywanie menedżera pakietów W KONTENERZE)
## mogło reużyć `crossdistro.nim` -- czyli bezpieczna instalacja pakietu
## z INNEJ dystrybucji niż hostowa (patrz `git -> apt -> debian.testing`
## w package.list), bez dotykania natywnej bazy pakietów hosta.

proc detectContainerEngine*(): string =
  ## Preferuje podman (najbardziej rozpowszechniony rootless engine w
  ## Zenit), buildah jako fallback (środowiska bez demona/CI minimalne).
  if findExe("podman").len > 0: "podman"
  elif findExe("buildah").len > 0: "buildah"
  else: ""

proc exportImageToLower*(engine, baseImage, lowerDir: string): bool =
  ## Eksportuje warstwę bazową obrazu (rootfs) do `lowerDir`, żeby overlayfs
  ## miał z czego czytać jako read-only spód. `podman export` wymaga
  ## najpierw utworzenia (nieuruchomionego) kontenera; `buildah` ma do
  ## tego wygodne `buildah from` + `buildah mount`.
  createDir(lowerDir)
  case engine
  of "podman":
    let tmpName = &"zpm-export-{getCurrentProcessId()}"
    if execCmd(&"podman create --name {tmpName} {baseImage} true") != 0:
      return false
    defer: discard execCmd(&"podman rm -f {tmpName}")
    let code = execCmd(&"podman export {tmpName} | tar -x -C \"{lowerDir}\"")
    code == 0
  of "buildah":
    let (mountPoint, code) = execCmdEx(&"buildah from --quiet {baseImage} | xargs buildah mount")
    if code != 0: return false
    let src = mountPoint.strip()
    if src.len == 0: return false
    execCmd(&"cp -a \"{src}/.\" \"{lowerDir}/\"") == 0
  else:
    false

proc mountOverlay*(dir: string): tuple[ok: bool, err: string] =
  ## Montuje `dir/rootfs` jako overlayfs z `dir/lower` (read-only, obraz
  ## bazowy) + `dir/upper` (zapisywalna warstwa COW) + `dir/work`
  ## (wymagany katalog roboczy overlayfs). Wymaga uprawnień do mount(8)
  ## dla overlayfs -- na wielu dystrybucjach to root albo user namespaces
  ## (`unshare -Um mount ...`) w trybie rootless; próbujemy zwykłego
  ## `mount` najpierw, potem `unshare --mount --map-root-user`.
  let lower = dir / "lower"
  let upper = dir / "upper"
  let work = dir / "work"
  let rootfs = dir / "rootfs"
  createDir(lower); createDir(upper); createDir(work); createDir(rootfs)

  let opts = &"lowerdir={lower},upperdir={upper},workdir={work}"
  var (outp1, code) = execCmdEx(&"mount -t overlay overlay -o \"{opts}\" \"{rootfs}\"")
  discard outp1
  if code == 0:
    return (true, "")

  # Fallback rootless: user namespace z mapowaniem root wewnątrz.
  var outp2: string
  (outp2, code) = execCmdEx(&"unshare --mount --map-root-user mount -t overlay overlay -o \"{opts}\" \"{rootfs}\"")
  discard outp2
  if code == 0:
    return (true, "")

  (false, "mount(8) overlayfs nie powiódł się (ani zwykły, ani przez 'unshare --mount --map-root-user') -- " &
    "prawdopodobnie brak uprawnień/user namespaces na tym hoście")

proc unmountOverlay*(dir: string) =
  let rootfs = dir / "rootfs"
  discard execCmdEx(&"umount \"{rootfs}\" 2>/dev/null")
  discard execCmdEx(&"unshare --mount --map-root-user umount \"{rootfs}\" 2>/dev/null")

proc detectPkgManagerInContainer*(engine, containerName: string): string =
  ## Zamiast naiwnego "apt install || dnf install || pacman -S" (które
  ## cicho "udaje się" na pierwszym poleceniu obecnym w PATH, nawet jeśli
  ## to nie jest właściwy menedżer obrazu), sprawdza po kolei, który
  ## menedżer REALNIE ma dane o zainstalowanych pakietach w tym obrazie
  ## (istnienie bazy danych pakietów, nie tylko binarki -- obrazy
  ## multi-lib czasem mają dodatkowe binarki menedżerów bez ich baz).
  let checks = [
    ("apt", "test -d /var/lib/dpkg"),
    ("dnf", "test -d /var/lib/rpm && command -v dnf"),
    ("pacman", "test -d /var/lib/pacman"),
    ("apk", "test -d /lib/apk/db"),
    ("zypper", "test -d /var/lib/rpm && command -v zypper"),
  ]
  for (mgr, probe) in checks:
    let (_, code) = execCmdEx(&"{engine} exec {containerName} sh -c '{probe}' 2>/dev/null")
    if code == 0:
      return mgr
  ""

proc installCmdFor*(mgr, pkg: string): string =
  case mgr
  of "apt": &"apt-get update -qq && apt-get install -y {pkg}"
  of "dnf": &"dnf install -y {pkg}"
  of "pacman": &"pacman -Sy --noconfirm {pkg}"
  of "apk": &"apk add --no-cache {pkg}"
  of "zypper": &"zypper --non-interactive install {pkg}"
  else: ""

proc containerSandboxWrap*(image, workDir: string, extraWritable: openArray[string],
                            allowNetwork: bool, cmd: seq[string]): tuple[ok: bool, cmd: seq[string], err: string] =
  ## v0.3 -- alternatywa dla `bwrap` (patrz `security.build_isolation =
  ## "container"` w zpm): zamiast dzielić jądro/przestrzenie nazw hosta
  ## (jak robi bwrap), uruchamia `cmd` WEWNĄTRZ efemerycznego kontenera
  ## podman/buildah opartego o CAŁKIEM INNY obraz bazowy niż host. Mocniejsza
  ## izolacja (osobny rootfs, nie tylko namespaces) kosztem czasu startu
  ## kontenera i wymogu posiadania podman/buildah + obrazu.
  ##
  ## `workDir` jest bind-mountowany pod TĄ SAMĄ ścieżką wewnątrz kontenera
  ## (jak w bwrap), więc skrypty budujące, które liczą na znajomość swojej
  ## ścieżki, działają identycznie w obu trybach izolacji.
  let engine = detectContainerEngine()
  if engine.len == 0:
    return (false, cmd, "security.build_isolation=\"container\", ale ani 'podman', ani 'buildah' nie są w PATH")

  var runCmd = @[engine, "run", "--rm"]
  if not allowNetwork:
    runCmd.add "--network=none"
  runCmd.add "-v"; runCmd.add &"{workDir}:{workDir}"
  for w in extraWritable:
    if w.len > 0:
      createDir(w)
      runCmd.add "-v"; runCmd.add &"{w}:{w}"
  runCmd.add "-w"; runCmd.add workDir
  runCmd.add image
  (true, runCmd & cmd, "")
