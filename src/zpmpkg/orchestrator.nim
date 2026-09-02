import std/[strformat, strutils, threadpool, os, algorithm, times, json, tables, sets]
import db_connector/db_sqlite
import ./types
import ./config
import ./database
import ./ownrepo
import ./deps
import ./zpk
import ./lockfile
import ./filelock
import ./state
import ./trustedkeys
import ./logging
import ./crossdistro
import ./backends/[common, apt, dnf, pacman, zypper, flatpak, snap, cargo, pip, npm, brew]

{.experimental: "parallel".}

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
  ## v0.3: dwa nowe segmenty (variant po drugiej "->", opis po ":") -- oba
  ## opcjonalne i mogą występować razem: "kernel -> own -> testing : jądro".
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
      # 3 lub więcej "->" -- pierwsze dwa to nazwa/backend, RESZTA (zjednoczona
      # z powrotem przez "->", na wypadek gdyby ktoś dał sam wariant z
      # dosłownym "->" w środku, co się nie zdarza w praktyce, ale nie chcemy
      # cichego obcinania) to wariant.
      let variant = parts[2..^1].join("->").strip()
      return PackageSpec(name: parts[0].strip(), backend: parts[1].strip().toLowerAscii,
                          variant: variant, description: description)
  if '@' in s and not s.startsWith("@"):
    let parts = s.rsplit('@', maxsplit = 1)
    return PackageSpec(name: parts[0].strip(), backend: parts[1].strip().toLowerAscii,
                        variant: "", description: description)
  PackageSpec(name: s, backend: "", variant: "", description: description)

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
  of bkZenitNat: searchNative(cfg, query)

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
  of bkZenitNat: loadRepoIndex(cfg.nativeRepoCacheDir / "index.json").packages.len > 0

proc installViaBackend(kind: BackendKind, name: string, cfg: ZpmConfig, variant: string = ""): int =
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
  of bkOwn:
    # Instalacja `own` jest ŚWIADOMA zależności (depends_on) -- jeśli `name`
    # potrzebuje innych narzędzi z own-repository.json, zostaną zainstalowane
    # najpierw (patrz deps.nim + installManyOwn w ownrepo.nim).
    # v0.3: `variant` to branch (np. "testing") -- patrz PackageSpec.variant.
    var branchFor = initTable[string, string]()
    if variant.len > 0: branchFor[name] = variant
    if installManyOwn(loadOwnRepo(cfg), cfg, @[name], cfg.ownToolsInstallDir, "/", false, branchFor): 0 else: 1
  of bkZenitNat: installNative(cfg, name, "/")

proc installViaBackendHost(kind: BackendKind, name: string, cfg: ZpmConfig, variant: string): int =
  ## v0.3: dla backendów hosta (apt/dnf/pacman/...) z NIEPUSTYM `variant`
  ## (np. "debian.testing") deleguje do crossdistro.nim -- BEZPIECZNA
  ## instalacja z innej dystrybucji, izolowana kontenerem, nigdy nie
  ## dotykająca natywnej bazy pakietów hosta (patrz komentarz w
  ## crossdistro.nim -- to jest odpowiedź na "żeby systemu nie wyjebało
  ## w powietrze").
  if variant.len == 0:
    return installViaBackend(kind, name, cfg)
  let (ok, err) = crossDistroInstall(cfg, $kind, variant, name, "/")
  if not ok:
    stderr.writeLine(&"[zpm:crossdistro] ✘ {err}")
    return 1
  0

proc removeViaBackend(kind: BackendKind, name: string, cfg: ZpmConfig): int =
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
    removeOwn(loadOwnRepo(cfg), name, cfg, cfg.ownToolsInstallDir, "/")
  of bkZenitNat:
    removeNative(cfg, name, "/")

proc updateViaBackend(kind: BackendKind, cfg: ZpmConfig): int =
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
  of bkOwn:
    # `zpm update`/`upgrade` odświeża też custom/own-repository.json --
    # to jest ten "tymczasowy" sposób z zadania. Docelowo lepiej używać
    # dedykowanego `zpm refresh` / `zpm own refresh`, które robi TYLKO to,
    # bez ruszania apt/dnf/pacman/itd.
    if refreshOwnRepository(cfg): 0 else: 1
  of bkZenitNat:
    if refreshNativeIndex(cfg): 0 else: 1

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
  of bkZenitNat: 0

proc presentBackends(cfg: ZpmConfig): seq[BackendKind] =
  result = @[]
  for b in cfg.enabledBackends:
    if backendPresent(b, cfg):
      result.add(b)

proc dedupCandidates(candidates: seq[PackageCandidate]): seq[PackageCandidate] =
  ## v0.2 -- zamyka lukę "Deduplikacja wyników wyszukiwania między
  ## backendami hosta (apt/dnf/... mogą zwrócić ten sam pakiet)". Klucz:
  ## (nazwa znormalizowana małymi literami, wersja) -- ten sam pakiet w tej
  ## samej wersji zwrócony przez kilka backendów (np. flatpak i apt mają
  ## oba "firefox") zostaje ZŁOŻONY w jeden wpis: pierwsze trafienie
  ## (najwyższy priorytet wg `cfg.preferredOrder`, bo `result` jest już
  ## posortowany PRZED wywołaniem tej funkcji) zostaje "głównym"
  ## kandydatem, a pozostałe źródła lądują w jego `alsoIn`, żeby
  ## użytkownik widział "dostępne też w: dnf, flatpak" zamiast trzech
  ## nieodróżnialnych wierszy.
  result = @[]
  var seen = initTable[string, int]()  # klucz -> indeks w result
  for c in candidates:
    let key = c.name.toLowerAscii & "@" & c.version
    if key in seen:
      let idx = seen[key]
      if c.backend notin result[idx].alsoIn and c.backend != result[idx].backend:
        result[idx].alsoIn.add c.backend
    else:
      seen[key] = result.len
      result.add c

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
  result = dedupCandidates(result)

proc promptChoice*(candidates: seq[PackageCandidate]): int =
  ## Wyświetla ponumerowaną listę kandydatów i zwraca wybrany indeks
  ## (-1 jeśli użytkownik anulował).
  echo ""
  echo "Znaleziono ", candidates.len, " pasujące(-ych) pakiety(-ów):"
  echo ""
  for i, c in candidates:
    let ver = if c.version.len > 0: " (" & c.version & ")" else: ""
    echo &"  [{i+1}] {c.name}{ver}  —  źródło: {c.backend}"
    if c.alsoIn.len > 0:
      echo &"        (dostępne też przez: {c.alsoIn.join(\", \")})"
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

  log(&"[zpm] Instaluję {chosen.name} przez {chosen.backend}" &
    (if spec.variant.len > 0: &" (wariant: {spec.variant})" else: "") & "...")
  let code =
    if chosen.backend == bkOwn: installViaBackend(chosen.backend, chosen.name, cfg, spec.variant)
    else: installViaBackendHost(chosen.backend, chosen.name, cfg, spec.variant)
  withLock(cfg.dbPath, cfg.lockTimeoutSec):
    if code == 0:
      db.recordInstall(chosen.name, chosen.backend, chosen.version, "user", pkgQuery)
      echo &"[zpm] ✔ Zainstalowano {chosen.name} — zapisano w bazie zpm."
    else:
      db.recordFailed(chosen.name, chosen.backend, "user", pkgQuery)
      echo &"[zpm] ✘ Instalacja nie powiodła się (kod {code}) — oznaczono w bazie jako 'failed' (patrz `zpm doctor`)."

proc cmdInstall*(cfg: ZpmConfig, db: DbConn, pkgQueries: seq[string], assumeYes = false) =
  ## Instaluje jeden LUB WIĘCEJ pakietów na raz, każdy może mieć własny
  ## wymuszony backend: `zpm install systemd "curl -> apt" htop`.
  for raw in pkgQueries:
    installOne(cfg, db, parsePackageSpec(raw), assumeYes)

proc cmdInstall*(cfg: ZpmConfig, db: DbConn, pkgQuery: string, assumeYes = false) =
  cmdInstall(cfg, db, @[pkgQuery], assumeYes)

proc removeOne(cfg: ZpmConfig, db: DbConn, name: string, force: bool) =
  let installed = db.listInstalled()
  var found = false
  for p in installed:
    if p.name == name:
      found = true
      if p.backend == bkOwn and not force:
        # Reverse-dependency check: nie pozwól ukręcić gałęzi, na której
        # inne (śledzone) narzędzie własnego ekosystemu wciąż stoi.
        let repo = loadOwnRepo(cfg)
        let dependents = directDependents(repo, name)
        var blockers: seq[string] = @[]
        for dep in dependents:
          for other in installed:
            if other.name == dep and other.backend == bkOwn and other.status != "failed":
              blockers.add dep
        if blockers.len > 0:
          let blockersStr = blockers.join(", ")
          echo &"[zpm] ✘ Nie usuwam '{name}' -- wymagane przez: {blockersStr} (patrz depends_on w own-repository.json)."
          echo "[zpm]   Usuń najpierw te narzędzia, albo użyj `zpm remove --force` żeby wymusić."
          continue
      echo &"[zpm] Usuwam {p.name} przez {p.backend}..."
      let code = removeViaBackend(p.backend, p.name, cfg)
      withLock(cfg.dbPath, cfg.lockTimeoutSec):
        if code == 0:
          db.recordRemoval(p.name, p.backend)
          echo &"[zpm] ✔ Usunięto {p.name}."
        else:
          echo &"[zpm] ✘ Usuwanie nie powiodło się (kod {code})."
  if not found:
    echo &"[zpm] Pakiet '{name}' nie jest śledzony przez zpm."

proc cmdRemove*(cfg: ZpmConfig, db: DbConn, names: seq[string], force = false) =
  for n in names:
    removeOne(cfg, db, parsePackageSpec(n).name, force)

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
      futures.add(spawn updateViaBackend(b, cfg))
    for f in futures: discard ^f
  else:
    for b in present:
      discard updateViaBackend(b, cfg)

  echo "[zpm] Sprzątam śmieci (autoremove/clean) dla każdego backendu..."
  for b in present:
    discard cleanupViaBackend(b)

  echo "[zpm] ✔ Wszystkie rejestry zaktualizowane."

proc cmdSync*(cfg: ZpmConfig) =
  ## Alias `update` używany przez `zlb` po zakończeniu instalacji modułu
  ## (zlbpkg/zpm.nim -> zpmSync) -- w trybie hosta to po prostu update.
  cmdUpdate(cfg)

proc cmdRefresh*(cfg: ZpmConfig) =
  ## `zpm refresh` / `zpm own refresh` -- odświeża WYŁĄCZNIE
  ## custom/own-repository.json (bez dotykania apt/dnf/pacman/itd.,
  ## w przeciwieństwie do pełnego `zpm update`).
  if not refreshOwnRepository(cfg):
    quit(1)

proc cmdLock*(cfg: ZpmConfig, names: seq[string]) =
  ## `zpm lock [--update] [nazwa...]` -- (ponownie) pinuje dokładny stan
  ## świata w zpm.lock: dla narzędzi `git` dokładny commit rozwiązany z
  ## `ref` w own-repository.json (NIE z aktualnego zpm.lock -- to właśnie
  ## `zpm lock` świadomie PRZESUWA pin), dla `binary` sumę sha256. Puste
  ## `names` = zablokuj wszystkie narzędzia z own-repository.json.
  let repo = loadOwnRepo(cfg)
  let flock =
    try:
      acquireLock(cfg.lockPath, cfg.lockTimeoutSec)
    except LockTimeoutError as e:
      stderr.writeLine(e.msg)
      quit(1)
  defer: release(flock)
  var lock = loadLock(cfg.lockPath)
  var targets = names
  if targets.len == 0:
    for t in repo.tools: targets.add t.name

  for name in targets:
    let tool = repo.findTool(name)
    if tool.name.len == 0:
      echo &"[zpm:lock] Pomijam '{name}' -- nie występuje w custom/own-repository.json."
      continue
    case tool.kind
    of otkGit:
      let (ok, commit) = resolveAndLockGitRef(tool, cfg)
      if not ok:
        echo &"[zpm:lock] ✘ Nie udało się zablokować '{name}'."
        continue
      lock.upsertEntry(LockEntry(
        name: tool.name, kind: otkGit, resolvedRef: commit, sha256: "",
        sourceUrl: tool.repo, lockedAt: nowIso8601()
      ))
      echo &"[zpm:lock] ✔ {tool.name} -> {commit} ({tool.repo})"
    of otkBinary:
      var sha = tool.sha256
      if sha.len == 0 and tool.bin.len > 0:
        let tmpDir = getTempDir() / "zpm-lock-tmp"
        let (dlOk, path, _) = downloadOwnTool(tool, tmpDir, cfg)
        if dlOk:
          sha = sha256sumOf(path)
          removeFile(path)
      lock.upsertEntry(LockEntry(
        name: tool.name, kind: otkBinary, resolvedRef: "", sha256: sha,
        sourceUrl: tool.bin, lockedAt: nowIso8601()
      ))
      echo &"[zpm:lock] ✔ {tool.name} -> sha256={sha}"

  if lock.sourceDateEpoch == 0:
    lock.sourceDateEpoch = getTime().toUnix()
  saveLock(cfg.lockPath, lock)
  echo &"[zpm:lock] Zapisano {cfg.lockPath} ({lock.entries.len} wpisów)."

proc cmdInit*(cfg: ZpmConfig, trustKeysPath: string) =
  ## Bootstrapuje bazę zpm oraz (opcjonalnie) zaufany zestaw kluczy repo
  ## wskazany przez --trust-keys <ścieżka> (patrz zlbpkg/keys.nim w zlb,
  ## który generuje ten sam format co keys/default.hcl).
  ##
  ## v0.2: --trust-keys REALNIE parsuje plik i PERSYSTUJE znormalizowany
  ## zestaw fingerprintów (albo importuje materiał klucza przez gpg, jeśli
  ## plik zawiera blok PGP) pod `cfg.trustedKeysStatePath` -- od teraz
  ## `verifyGitSignature` (ownrepo.nim) wymaga, żeby podpisujący klucz był
  ## na tej liście, nie tylko "znany lokalnemu gpg". Wcześniej ta flaga
  ## TYLKO drukowała komunikat i nie była spięta z niczym.
  createDir(parentDir(cfg.dbPath))
  let db = openDb(cfg.dbPath)
  db.closeDb()
  echo &"[zpm] Baza zainicjowana: {cfg.dbPath}"

  if trustKeysPath.len > 0:
    if fileExists(trustKeysPath):
      let (ok, count) = importTrustKeysFile(cfg, trustKeysPath)
      if ok:
        echo &"[zpm] ✔ Zaimportowano {count} zaufany(ch) klucz(y/e) z {trustKeysPath} -> {cfg.trustedKeysStatePath}"
        echo "     Od teraz podpisy GPG w ekosystemie 'own' MUSZĄ pochodzić z tej listy (security.verify_signatures)."
      else:
        echo &"[zpm] ✘ {trustKeysPath} nie zawierał żadnego rozpoznanego fingerprintu/klucza -- nic nie zaimportowano."
    else:
      echo &"[zpm] Ostrzeżenie: --trust-keys wskazuje na nieistniejący plik: {trustKeysPath}"

  let repo = loadOwnRepo(cfg)
  echo &"[zpm] Ekosystem 'own': {repo.tools.len} narzędzi dostępnych z {cfg.customRepoPath}"

proc cmdList*(db: DbConn, cfg: ZpmConfig, showAll: bool = false) =
  ## v0.2.1: `--all` domyka CZĘŚĆ luki "own (git) i native (.zpk) mają
  ## osobne mechanizmy pokwitowań i osobne blokady; SQLite pokrywa tylko
  ## poziom 'zainstalowane przez zpm'" -- daje JEDEN widok łączący bazę
  ## SQLite (poziom "co zpm wie, że zainstalowało") z surowymi
  ## pokwitowaniami `own`/`native` (poziom "co faktycznie leży na
  ## dysku wg ostatniego zapisu pokwitowania"), oznaczając WYRAŹNIE wpisy
  ## obecne TYLKO w pokwitowaniach, a NIE w bazie SQLite (i odwrotnie) --
  ## to jest dokładnie ten rozjazd, który wcześniej dało się zobaczyć
  ## tylko fragmentarycznie przez `zpm doctor`. To NADAL nie jest jeden
  ## fizyczny rejestr (dwa niezależne mechanizmy przechowywania nie
  ## znikają) -- ale jest jeden PUNKT ODCZYTU dla obu.
  let installed = db.listInstalled(includeFailed = true)
  if not showAll:
    if installed.len == 0:
      log("[zpm] Baza zpm jest pusta — żaden pakiet nie został jeszcze zainstalowany przez zpm.")
      return
    if cfg.jsonOutput:
      var arr = newJArray()
      for p in installed:
        var j = newJObject()
        j["name"] = %p.name
        j["version"] = %p.version
        j["backend"] = %($p.backend)
        j["requested_by"] = %p.requestedBy
        j["installed_at"] = %($p.installedAt)
        j["status"] = %p.status
        arr.add j
      logAlways(arr.pretty())
      return
    log(&"[zpm] Pakiety śledzone przez zpm ({installed.len}):")
    for p in installed:
      let ver = if p.version.len > 0: " " & p.version else: ""
      let flag = if p.status == "failed": "  [!! FAILED, patrz `zpm doctor`]" else: ""
      log(&"  - {p.name}{ver}  [{p.backend}]  (żądane przez: {p.requestedBy}){flag}")
    return

  # ---- --all: widok ujednolicony (SQLite + pokwitowania own + native) ----
  var dbNames = initHashSet[string]()
  for p in installed: dbNames.incl(p.name & "@" & $p.backend)

  let ownReceipts = allOwnReceipts(cfg)
  let nativeReceipts = allNativeReceipts(cfg)

  if cfg.jsonOutput:
    var arr = newJArray()
    for p in installed:
      var j = newJObject()
      j["name"] = %p.name
      j["version"] = %p.version
      j["backend"] = %($p.backend)
      j["source"] = %"sqlite"
      j["requested_by"] = %p.requestedBy
      j["installed_at"] = %($p.installedAt)
      j["status"] = %p.status
      arr.add j
    for r in ownReceipts:
      var j = newJObject()
      j["name"] = %r.name
      j["version"] = %r.resolvedRef
      j["backend"] = %"own"
      j["source"] = %"own-receipt"
      j["in_sqlite"] = %(("own" & r.name) & "@bkOwn" in dbNames or (r.name & "@bkOwn") in dbNames)
      j["root_path"] = %r.rootPath
      j["installed_at"] = %r.installedAt
      arr.add j
    for r in nativeReceipts:
      var j = newJObject()
      j["name"] = %r.name
      j["version"] = %r.version
      j["backend"] = %"zenit-native"
      j["source"] = %"native-receipt"
      j["in_sqlite"] = %((r.name & "@bkZenitNat") in dbNames)
      j["root_path"] = %r.rootPath
      j["files_count"] = %r.files.len
      j["installed_at"] = %r.installedAt
      arr.add j
    logAlways(arr.pretty())
    return

  log(&"[zpm] Widok ujednolicony (--all): {installed.len} w bazie SQLite, {ownReceipts.len} pokwitowań 'own', " &
    &"{nativeReceipts.len} pokwitowań 'native'.")
  log("")
  log("== Baza SQLite (\"zpm wie, że zainstalowało\") ==")
  for p in installed:
    let ver = if p.version.len > 0: " " & p.version else: ""
    let flag = if p.status == "failed": "  [!! FAILED]" else: ""
    log(&"  - {p.name}{ver}  [{p.backend}]{flag}")

  log("")
  log("== Pokwitowania 'own' (\"co leży na dysku wg ostatniego zapisu\") ==")
  for r in ownReceipts:
    let inDb = (r.name & "@bkOwn") in dbNames
    let flag = if inDb: "" else: "  [!! BRAK w bazie SQLite -- rozjazd, patrz `zpm doctor`]"
    log(&"  - {r.name}  ref={r.resolvedRef}  root={r.rootPath}{flag}")

  log("")
  log("== Pokwitowania 'native' (.zpk) ==")
  for r in nativeReceipts:
    let inDb = (r.name & "@bkZenitNat") in dbNames
    let flag = if inDb: "" else: "  [!! BRAK w bazie SQLite -- rozjazd, patrz `zpm doctor`]"
    log(&"  - {r.name} {r.version}  root={r.rootPath}  plików={r.files.len}{flag}")

proc backendIsInstalled*(b: BackendKind, name: string): tuple[known: bool, installed: bool] =
  ## v0.2 -- zamyka lukę "`zpm doctor` weryfikuje tylko backend `own` --
  ## dla apt/dnf/pacman/... nie sprawdza faktycznego stanu (np. `dpkg -s`)".
  ## `known=false` oznacza "ten backend nie ma jeszcze isInstalled albo nie
  ## dotyczy sprawdzania po nazwie" (np. `own`/`native` mają WŁASNE ścieżki
  ## weryfikacji w cmdDoctor -- pokwitowania, nie zapytania do menedżera).
  case b
  of bkApt: (true, apt.isInstalled(name))
  of bkDnf: (true, dnf.isInstalled(name))
  of bkPacman: (true, pacman.isInstalled(name))
  of bkZypper: (true, zypper.isInstalled(name))
  of bkFlatpak: (true, flatpak.isInstalled(name))
  of bkSnap: (true, snap.isInstalled(name))
  of bkBrew: (true, brew.isInstalled(name))
  of bkCargo: (true, cargo.isInstalled(name))
  of bkNpm: (true, npm.isInstalled(name))
  of bkPip: (true, pip.isInstalled(name))
  of bkOwn, bkZenitNat: (false, false)

proc cmdDoctor*(cfg: ZpmConfig, db: DbConn, fix: bool = false) =
  ## `zpm doctor` -- wykrywa rozjazd między tym, co zpm MYŚLI że jest
  ## zainstalowane (baza SQLite + pokwitowania `own`/`native`), a tym, co
  ## faktycznie widać na dysku/w konfiguracji.
  ##
  ## v0.2:
  ##  - dla backendów hosta (apt/dnf/pacman/zypper/flatpak/snap/brew/
  ##    cargo/npm/pip) TERAZ faktycznie odpytuje menedżer (`dpkg-query`,
  ##    `rpm -q`, `pacman -Qi`, ...), zamiast po prostu pomijać sprawdzenie
  ##    -- zamyka lukę "`zpm doctor` weryfikuje tylko backend `own`".
  ##  - `--fix` -- gdy podane, dla problemów które da się bezpiecznie
  ##    naprawić automatycznie (osierocone pokwitowania/wpisy lock),
  ##    NAPRAWIA je od razu zamiast tylko sugerować komendę. Problemy
  ##    wymagające decyzji człowieka (status 'failed', pakiet zniknął z
  ##    systemu mimo wpisu w bazie) NADAL tylko sugerują komendę -- `doctor
  ##    --fix` nie instaluje ani nie usuwa niczego bez wyraźnej, osobnej
  ##    decyzji operatora, żeby nie robić niespodzianek na systemie
  ##    produkcyjnym.
  var problems = 0
  var fixed = 0

  echo "[zpm doctor] Sprawdzam bazę zpm vs stan faktyczny..."
  for p in db.listInstalled(includeFailed = true):
    if p.status == "failed":
      echo &"  ✘ {p.name} [{p.backend}] ma status 'failed' w bazie -- ostatnia instalacja się nie powiodła."
      echo &"      napraw: zpm remove {p.name} ; zpm install {p.name}"
      inc problems
      continue
    case p.backend
    of bkOwn:
      if not isOwnInstalled(cfg, p.name, "/"):
        echo &"  ✘ {p.name} [own] jest w bazie zpm, ale brak pokwitowania instalacji ({cfg.ownStateDir}) -- rozjazd."
        echo &"      napraw: zpm own install {p.name} --force"
        inc problems
    of bkZenitNat:
      let (found, _) = loadNativeReceipt(cfg, p.name, "/")
      if not found:
        echo &"  ✘ {p.name} [zenit-native] jest w bazie zpm, ale brak pokwitowania instalacji ({cfg.nativeStateDir}) -- rozjazd."
        echo &"      napraw: zpm install {p.name} -> zenit"
        inc problems
    else:
      let (known, installed) = backendIsInstalled(p.backend, p.name)
      if known and not installed:
        echo &"  ✘ {p.name} [{p.backend}] jest w bazie zpm, ale menedżer '{p.backend}' twierdzi, że NIE jest " &
          "zainstalowany (usunięty poza zpm?) -- rozjazd."
        echo &"      napraw: zpm install {p.name} -> {p.backend}   (albo zpm remove {p.name}, jeśli to zamierzone)"
        inc problems

  echo "[zpm doctor] Sprawdzam pokwitowania 'own' bez odpowiadającego wpisu w own-repository.json (osierocone)..."
  let repo = loadOwnRepo(cfg)
  for r in allOwnReceipts(cfg):
    if repo.findTool(r.name).name.len == 0:
      if fix:
        removeOwnReceipt(cfg, r.name, r.rootPath)
        echo &"  ↺ [--fix] Usunięto osierocone pokwitowanie '{r.name}' (root={r.rootPath})."
        inc fixed
      else:
        echo &"  ⚠ Pokwitowanie '{r.name}' (root={r.rootPath}) nie ma odpowiednika w own-repository.json " &
          "-- narzędzie usunięte ze źródła, ale nadal 'zainstalowane' wg zpm."
        echo "      napraw: zpm doctor --fix   (usunie samo pokwitowanie, NIE pliki narzędzia na dysku)"
        inc problems

  echo "[zpm doctor] Sprawdzam wpisy zpm.lock bez odpowiadającego narzędzia..."
  var lockFile = loadLock(cfg.lockPath)
  var lockChanged = false
  var keptEntries: seq[LockEntry] = @[]
  for e in lockFile.entries:
    if repo.findTool(e.name).name.len == 0:
      if fix:
        echo &"  ↺ [--fix] Usunięto osierocony wpis zpm.lock '{e.name}'."
        lockChanged = true
        inc fixed
      else:
        echo &"  ⚠ zpm.lock ma zablokowany wpis '{e.name}', którego nie ma już w own-repository.json (osierocony)."
        echo "      napraw: zpm doctor --fix"
        inc problems
        keptEntries.add e
    else:
      keptEntries.add e
  if fix and lockChanged:
    lockFile.entries = keptEntries
    saveLock(cfg.lockPath, lockFile)

  echo "[zpm doctor] Sprawdzam wymogi bezpieczeństwa (security { })..."
  if cfg.sandboxEnabled and findExe(cfg.sandboxCmd).len == 0:
    echo &"  ✘ security.sandbox_enabled=true, ale '{cfg.sandboxCmd}' nie jest w PATH."
    inc problems
  if cfg.verifySignatures and findExe("gpg").len == 0:
    echo "  ✘ security.verify_signatures=true, ale 'gpg' nie jest w PATH (git verify-commit/tag tego wymaga)."
    inc problems
  if cfg.verifySignatures and not trustedKeysConfigured(cfg):
    echo "  ⚠ security.verify_signatures=true, ale nie skonfigurowano listy zaufanych kluczy " &
      "(`zpm init --trust-keys=<plik>`) -- każdy klucz zaufany przez system gpg jest akceptowany, " &
      "nie tylko wskazane przez operatora."
    inc problems
  if findExe("git").len == 0:
    echo "  ✘ 'git' nie jest w PATH -- cały ekosystem `own` typu 'git' jest niedostępny."
    inc problems
  if (cfg.buildMemoryLimit.len > 0 or cfg.buildCpuQuota.len > 0) and
      findExe("systemd-run").len == 0 and not cgroupsV2Delegated():
    echo &"  ⚠ security.build_memory_limit/build_cpu_quota ustawione, ale ani 'systemd-run', ani zapisywalna " &
      &"cgroup v2 nie są dostępne -- limity NIE są egzekwowane" &
      (if cfg.strictResourceLimits: " (strict_resource_limits=true zablokuje faktyczne buildy do czasu naprawy)." else: " (best effort).")
    inc problems

  if fix and fixed > 0:
    echo &"[zpm doctor] ✔ Naprawiono automatycznie: {fixed}."
  if problems == 0:
    echo "[zpm doctor] ✔ Nic podejrzanego nie znaleziono."
  else:
    echo &"[zpm doctor] Znaleziono {problems} problem(ów) -- patrz sugestie napraw powyżej."
    quit(1)
