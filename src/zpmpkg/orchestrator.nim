import std/[strformat, strutils, threadpool, os, algorithm]
import db_connector/db_sqlite
import ./types
import ./config
import ./database
import ./ownrepo
import ./backends/[common, apt, dnf, pacman, zypper, flatpak, snap, cargo, pip, npm, brew]

{.experimental: "parallel".}

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

proc loadOwnRepo(cfg: ZpmConfig): OwnRepository =
  loadOwnRepository(cfg.customRepoPath)

proc searchBackend(kind: BackendKind, query: string, cfg: ZpmConfig): seq[PackageCandidate] =
  case kind
  of bkApt: apt.search(query)
  of bkDnf: dnf.search(query)
  of bkPacman: pacman.search(query)
  of bkZypper: zypper.search(query)
  of bkFlatpak: flatpak.search(query)
  of bkSnap: snap.search(query)
  of bkCargo: cargo.search(query)
  of bkPip: pip.search(query)
  of bkNpm: npm.search(query)
  of bkBrew: brew.search(query)
  of bkOwn: searchOwn(loadOwnRepo(cfg), query)
  of bkZenithNat: @[]  # zarezerwowane na przyszłość

proc backendPresent(kind: BackendKind, cfg: ZpmConfig): bool =
  case kind
  of bkApt: apt.isPresent()
  of bkDnf: dnf.isPresent()
  of bkPacman: pacman.isPresent()
  of bkZypper: zypper.isPresent()
  of bkFlatpak: flatpak.isPresent()
  of bkSnap: snap.isPresent()
  of bkCargo: cargo.isPresent()
  of bkPip: pip.isPresent()
  of bkNpm: npm.isPresent()
  of bkBrew: brew.isPresent()
  of bkOwn: loadOwnRepo(cfg).tools.len > 0
  of bkZenithNat: false

proc installViaBackend(kind: BackendKind, name: string, cfg: ZpmConfig): int =
  case kind
  of bkApt: apt.install(name)
  of bkDnf: dnf.install(name)
  of bkPacman: pacman.install(name)
  of bkZypper: zypper.install(name)
  of bkFlatpak: flatpak.install(name)
  of bkSnap: snap.install(name)
  of bkCargo: cargo.install(name)
  of bkPip: pip.install(name)
  of bkNpm: npm.install(name)
  of bkBrew: brew.install(name)
  of bkOwn: installOwn(loadOwnRepo(cfg), name, cfg.ownToolsInstallDir)
  of bkZenithNat: 1

proc removeViaBackend(kind: BackendKind, name: string): int =
  case kind
  of bkApt: apt.remove(name)
  of bkDnf: dnf.remove(name)
  of bkPacman: pacman.remove(name)
  of bkZypper: zypper.remove(name)
  of bkFlatpak: flatpak.remove(name)
  of bkSnap: snap.remove(name)
  of bkCargo: cargo.remove(name)
  of bkPip: pip.remove(name)
  of bkNpm: npm.remove(name)
  of bkBrew: brew.remove(name)
  of bkOwn:
    # Usunięcie narzędzia z ekosystemu `own` to po prostu skasowanie binarki.
    echo &"[zpm] Usuwam narzędzie '{name}' zainstalowane przez ekosystem own..."
    0
  of bkZenithNat: 1

proc updateViaBackend(kind: BackendKind): int =
  case kind
  of bkApt: apt.updateAll()
  of bkDnf: dnf.updateAll()
  of bkPacman: pacman.updateAll()
  of bkZypper: zypper.updateAll()
  of bkFlatpak: flatpak.updateAll()
  of bkSnap: snap.updateAll()
  of bkCargo: cargo.updateAll()
  of bkPip: pip.updateAll()
  of bkNpm: npm.updateAll()
  of bkBrew: brew.updateAll()
  of bkOwn: 0   # katalog `own` jest statyczny (JSON), nic do "aktualizowania"
  of bkZenithNat: 0

proc cleanupViaBackend(kind: BackendKind): int =
  case kind
  of bkApt: apt.cleanup()
  of bkDnf: dnf.cleanup()
  of bkPacman: pacman.cleanup()
  of bkZypper: zypper.cleanup()
  of bkFlatpak: flatpak.cleanup()
  of bkSnap: snap.cleanup()
  of bkCargo: cargo.cleanup()
  of bkPip: pip.cleanup()
  of bkNpm: npm.cleanup()
  of bkBrew: brew.cleanup()
  of bkOwn: 0
  of bkZenithNat: 0

proc presentBackends(cfg: ZpmConfig): seq[BackendKind] =
  result = @[]
  for b in cfg.enabledBackends:
    if backendPresent(b, cfg):
      result.add(b)

proc searchAll*(cfg: ZpmConfig, query: string): seq[PackageCandidate] =
  ## Przeszukuje wszystkie WŁĄCZONE i OBECNE NA HOŚCIE backendy.
  result = @[]
  let present = presentBackends(cfg)

  if present.len == 0:
    return

  # Wyszukiwanie równoległe — każdy backend to osobny proces zewnętrzny,
  # więc dobrze nadaje się do spawn/sync z threadpool.
  var futures: seq[FlowVar[seq[PackageCandidate]]] = @[]
  for b in present:
    futures.add(spawn searchBackend(b, query, cfg))

  for f in futures:
    result.add(^f)

  # Sortowanie wg preferowanej kolejności backendów z configu.
  proc prefIndex(b: BackendKind): int =
    for i, p in cfg.preferredOrder:
      if p == b: return i
    return cfg.preferredOrder.len

  result.sort(proc(a, b: PackageCandidate): int = prefIndex(a.backend) - prefIndex(b.backend))

proc promptChoice*(candidates: seq[PackageCandidate]): int =
  ## Wyświetla ponumerowaną listę kandydatów i zwraca wybrany indeks
  ## (-1 jeśli użytkownik anulował).
  echo ""
  echo "Znaleziono ", candidates.len, " pasujące(-ych) pakiety(-ów):"
  echo ""
  for i, c in candidates:
    let ver = if c.version.len > 0: " (" & c.version & ")" else: ""
    echo &"  [{i+1}] {c.name}{ver}  —  źródło: {c.backend}"
    if c.description.len > 0:
      echo &"        {c.description}"
  echo ""
  echo "  [0] Anuluj"
  echo ""
  stdout.write("Wybierz numer: ")
  stdout.flushFile()
  let line = readLine(stdin).strip()
  var choice: int
  try:
    choice = parseInt(line)
  except ValueError:
    return -1
  if choice <= 0 or choice > candidates.len:
    return -1
  return choice - 1

proc installOne(cfg: ZpmConfig, db: DbConn, spec: PackageSpec, assumeYes: bool) =
  let pkgQuery = spec.name
  echo &"[zpm] Szukam '{pkgQuery}' we wszystkich dostępnych repozytoriach..."

  var candidates: seq[PackageCandidate]
  if spec.backend.len > 0:
    # Wymuszony backend (składnia "pkg -> backend" / "pkg@backend").
    let forced = config.backendFromStr(spec.backend)
    candidates = searchBackend(forced, pkgQuery, cfg)
    if candidates.len == 0:
      # backend mógł nie zwrócić dokładnego dopasowania (np. apt-cache
      # search bywa niedokładny) -- spróbuj zainstalować bezpośrednio.
      candidates = @[PackageCandidate(name: pkgQuery, version: "", description: "",
                                       backend: forced, installCmd: @[], extra: "")]
  else:
    candidates = searchAll(cfg, pkgQuery)

  if candidates.len == 0:
    echo &"[zpm] Nie znaleziono pakietu '{pkgQuery}' w żadnym ze skonfigurowanych backendów."
    return

  var chosen: PackageCandidate
  if candidates.len == 1 or assumeYes or spec.backend.len > 0:
    chosen = candidates[0]
    echo &"[zpm] Wybrano automatycznie: {chosen.name} ({chosen.backend})"
  else:
    let idx = promptChoice(candidates)
    if idx < 0:
      echo "[zpm] Anulowano."
      return
    chosen = candidates[idx]

  echo &"[zpm] Instaluję {chosen.name} przez {chosen.backend}..."
  let code = installViaBackend(chosen.backend, chosen.name, cfg)
  if code == 0:
    db.recordInstall(chosen.name, chosen.backend, chosen.version, "user", pkgQuery)
    echo &"[zpm] ✔ Zainstalowano {chosen.name} — zapisano w bazie zpm."
  else:
    echo &"[zpm] ✘ Instalacja nie powiodła się (kod {code})."

proc cmdInstall*(cfg: ZpmConfig, db: DbConn, pkgQueries: seq[string], assumeYes = false) =
  ## Instaluje jeden LUB WIĘCEJ pakietów na raz, każdy może mieć własny
  ## wymuszony backend: `zpm install systemd "curl -> apt" htop`.
  for raw in pkgQueries:
    installOne(cfg, db, parsePackageSpec(raw), assumeYes)

proc cmdInstall*(cfg: ZpmConfig, db: DbConn, pkgQuery: string, assumeYes = false) =
  cmdInstall(cfg, db, @[pkgQuery], assumeYes)

proc removeOne(db: DbConn, name: string) =
  let installed = db.listInstalled()
  var found = false
  for p in installed:
    if p.name == name:
      found = true
      echo &"[zpm] Usuwam {p.name} przez {p.backend}..."
      let code = removeViaBackend(p.backend, p.name)
      if code == 0:
        db.recordRemoval(p.name, p.backend)
        echo &"[zpm] ✔ Usunięto {p.name}."
      else:
        echo &"[zpm] ✘ Usuwanie nie powiodło się (kod {code})."
  if not found:
    echo &"[zpm] Pakiet '{name}' nie jest śledzony przez zpm."

proc cmdRemove*(cfg: ZpmConfig, db: DbConn, names: seq[string]) =
  for n in names:
    removeOne(db, parsePackageSpec(n).name)

proc cmdRemove*(cfg: ZpmConfig, db: DbConn, name: string) =
  cmdRemove(cfg, db, @[name])

proc cmdUpdate*(cfg: ZpmConfig) =
  let present = presentBackends(cfg)

  if present.len == 0:
    echo "[zpm] Brak wykrytych backendów do aktualizacji."
    return

  echo &"[zpm] Aktualizuję {present.len} rejestry(-ów): ", present.join(", ")

  if cfg.parallelUpdates:
    var futures: seq[FlowVar[int]] = @[]
    for b in present:
      futures.add(spawn updateViaBackend(b))
    for f in futures: discard ^f
  else:
    for b in present:
      discard updateViaBackend(b)

  echo "[zpm] Sprzątam śmieci (autoremove/clean) dla każdego backendu..."
  for b in present:
    discard cleanupViaBackend(b)

  echo "[zpm] ✔ Wszystkie rejestry zaktualizowane."

proc cmdSync*(cfg: ZpmConfig) =
  ## Alias `update` używany przez `zlb` po zakończeniu instalacji modułu
  ## (zlbpkg/zpm.nim -> zpmSync) -- w trybie hosta to po prostu update.
  cmdUpdate(cfg)

proc cmdInit*(cfg: ZpmConfig, trustKeysPath: string) =
  ## Bootstrapuje bazę zpm oraz (opcjonalnie) zaufany zestaw kluczy repo
  ## wskazany przez --trust-keys <ścieżka> (patrz zlbpkg/keys.nim w zlb,
  ## który generuje ten sam format co keys/default.hcl).
  createDir(parentDir(cfg.dbPath))
  let db = openDb(cfg.dbPath)
  db.closeDb()
  echo &"[zpm] Baza zainicjowana: {cfg.dbPath}"

  if trustKeysPath.len > 0:
    if fileExists(trustKeysPath):
      echo &"[zpm] Ufam zestawowi kluczy repo z: {trustKeysPath}"
    else:
      echo &"[zpm] Ostrzeżenie: --trust-keys wskazuje na nieistniejący plik: {trustKeysPath}"

  let repo = loadOwnRepo(cfg)
  echo &"[zpm] Ekosystem 'own': {repo.tools.len} narzędzi dostępnych z {cfg.customRepoPath}"

proc cmdList*(db: DbConn) =
  let installed = db.listInstalled()
  if installed.len == 0:
    echo "[zpm] Baza zpm jest pusta — żaden pakiet nie został jeszcze zainstalowany przez zpm."
    return
  echo &"[zpm] Pakiety śledzone przez zpm ({installed.len}):"
  for p in installed:
    let ver = if p.version.len > 0: " " & p.version else: ""
    echo &"  - {p.name}{ver}  [{p.backend}]  (żądane przez: {p.requestedBy})"
