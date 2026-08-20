import std/[strformat, strutils, threadpool, os, algorithm]
import std/db_sqlite
import ./types
import ./config
import ./database
import ./backends/[common, apt, dnf, pacman, zypper, flatpak, snap, cargo, pip, npm]

{.experimental: "parallel".}

proc searchBackend(kind: BackendKind, query: string): seq[PackageCandidate] =
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
  of bkZenithNat: @[]  # zarezerwowane na przyszłość

proc backendPresent(kind: BackendKind): bool =
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
  of bkZenithNat: false

proc installViaBackend(kind: BackendKind, name: string): int =
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
  of bkZenithNat: 0

proc searchAll*(cfg: ZpmConfig, query: string): seq[PackageCandidate] =
  ## Przeszukuje wszystkie WŁĄCZONE i OBECNE NA HOŚCIE backendy.
  result = @[]
  var present: seq[BackendKind] = @[]
  for b in cfg.enabledBackends:
    if backendPresent(b):
      present.add(b)

  if present.len == 0:
    return

  # Wyszukiwanie równoległe — każdy backend to osobny proces zewnętrzny,
  # więc dobrze nadaje się do spawn/sync z threadpool.
  var futures: seq[FlowVar[seq[PackageCandidate]]] = @[]
  for b in present:
    futures.add(spawn searchBackend(b, query))

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

proc cmdInstall*(cfg: ZpmConfig, db: DbConn, pkgQuery: string, assumeYes = false) =
  echo &"[zpm] Szukam '{pkgQuery}' we wszystkich dostępnych repozytoriach..."
  let candidates = searchAll(cfg, pkgQuery)
  if candidates.len == 0:
    echo &"[zpm] Nie znaleziono pakietu '{pkgQuery}' w żadnym ze skonfigurowanych backendów."
    return

  var chosen: PackageCandidate
  if candidates.len == 1 or assumeYes:
    chosen = candidates[0]
    echo &"[zpm] Wybrano automatycznie: {chosen.name} ({chosen.backend})"
  else:
    let idx = promptChoice(candidates)
    if idx < 0:
      echo "[zpm] Anulowano."
      return
    chosen = candidates[idx]

  echo &"[zpm] Instaluję {chosen.name} przez {chosen.backend}..."
  let code = installViaBackend(chosen.backend, chosen.name)
  if code == 0:
    db.recordInstall(chosen.name, chosen.backend, chosen.version, "user", pkgQuery)
    echo &"[zpm] ✔ Zainstalowano {chosen.name} — zapisano w bazie zpm."
  else:
    echo &"[zpm] ✘ Instalacja nie powiodła się (kod {code})."

proc cmdRemove*(cfg: ZpmConfig, db: DbConn, name: string) =
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

proc cmdUpdate*(cfg: ZpmConfig) =
  var present: seq[BackendKind] = @[]
  for b in cfg.enabledBackends:
    if backendPresent(b): present.add(b)

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

proc cmdList*(db: DbConn) =
  let installed = db.listInstalled()
  if installed.len == 0:
    echo "[zpm] Baza zpm jest pusta — żaden pakiet nie został jeszcze zainstalowany przez zpm."
    return
  echo &"[zpm] Pakiety śledzone przez zpm ({installed.len}):"
  for p in installed:
    let ver = if p.version.len > 0: " " & p.version else: ""
    echo &"  - {p.name}{ver}  [{p.backend}]  (żądane przez: {p.requestedBy})"
