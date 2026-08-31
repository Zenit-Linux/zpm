import std/[os, parseopt, strutils, strformat]
import ./zpmpkg/types
import ./zpmpkg/config
import ./zpmpkg/database
import ./zpmpkg/ownrepo
import ./zpmpkg/logging

when defined(atomic):
  import ./zpmpkg/atomic
else:
  import ./zpmpkg/orchestrator
  import ./zpmpkg/building
  import ./zpmpkg/zpk

const ZpmVersion = "0.2.0"

proc printBanner() =
  when defined(atomic):
    echo &"zpm {ZpmVersion} — Zenit Package Manager [TRYB ATOMOWY / STRAŻNIK KONTENERÓW]"
  else:
    echo &"zpm {ZpmVersion} — Zenit Package Manager [TRYB STANDARDOWY]"

proc printHelp() =
  printBanner()
  echo ""
  when defined(atomic):
    echo "Użycie:"
    echo "  zpm atomic create  <nazwa> [--base=obraz]   Tworzy nowy kontener atomowy"
    echo "  zpm atomic install <nazwa> <pakiet>         Instaluje pakiet w izolacji"
    echo "  zpm atomic enter   <nazwa>                  Wchodzi interaktywnie do kontenera"
    echo "  zpm atomic list                             Listuje kontenery atomowe"
    echo "  zpm atomic destroy <nazwa>                  Usuwa kontener atomowy"
    echo ""
    echo "Konfiguracja: /etc/zpm/config.hcl (sekcja `atomic { store_path = ... }`)"
  else:
    echo "Użycie:"
    echo "  zpm install <pakiet...> [-y]     Szuka i instaluje 1+ pakietów ze wszystkich backendów"
    echo "                                   (\"pakiet -> backend\" / \"pakiet@backend\" wymusza backend)"
    echo "  zpm remove  <pakiet...> [--force] Usuwa 1+ pakiet(ów) śledzonych przez zpm (--force pomija"
    echo "                                   reverse-dependency check dla ekosystemu own)"
    echo "  zpm update | upgrade             Aktualizuje wszystkie rejestry (równolegle), w tym"
    echo "                                   odświeża own-repository.json + indeks natywny, i sprząta"
    echo "  zpm sync                         Alias `update` (zgodny z wywołaniami zlb)"
    echo "  zpm refresh                      Odświeża TYLKO custom/own-repository.json"
    echo "                                   (pobiera z custom.remote_url, waliduje, podmienia)"
    echo "  zpm list [--json]                Listuje pakiety zainstalowane przez zpm (w tym 'failed')"
    echo "  zpm doctor [--fix]                Diagnostyka: baza/pokwitowania vs stan faktyczny (TERAZ też"
    echo "                                   realnie odpytuje apt/dnf/pacman/zypper/flatpak/snap/brew/"
    echo "                                   cargo/npm/pip), wymogi bezpieczeństwa (bwrap/gpg/git w PATH)."
    echo "                                   --fix naprawia automatycznie to, co bezpieczne (osierocone"
    echo "                                   pokwitowania/wpisy locka) -- NIE instaluje/usuwa pakietów."
    echo "  zpm own list [--json]            Listuje narzędzia z custom/own-repository.json"
    echo "  zpm own info    <nazwa> [--json] Szczegóły narzędzia (typ, repo/bin, skrypty, zależności)"
    echo "  zpm own refresh                  Alias `zpm refresh`"
    echo "  zpm own build   <nazwa>          (tylko typ 'git') buduje ze źródeł (z zależnościami)"
    echo "                                   bez instalacji"
    echo "  zpm own install <nazwa...> [--force]"
    echo "                                   Instaluje narzędzie(a) own (binary lub git, z zależnościami;"
    echo "                                   idempotentnie -- pomija już zainstalowane, chyba że --force)"
    echo "  zpm own remove  <nazwa...> [--force]"
    echo "                                   Usuwa narzędzie own (blokuje, gdy inne go potrzebują, chyba"
    echo "                                   że --force)"
    echo "  zpm own build-stage   <etykieta> Buduje WSZYSTKIE narzędzia z danym `stage` (bootstrap)"
    echo "  zpm own install-stage <etykieta> Instaluje WSZYSTKIE narzędzia z danym `stage`"
    echo "  zpm own verify-reproducible <n>  Buduje 'n' dwukrotnie i porównuje wynik (fixed-point)"
    echo "  zpm lock [nazwa...]              (Ponownie) pinuje zpm.lock: dokładne commity/sha256"
    echo "                                   (puste = wszystkie narzędzia own-repository.json)"
    echo "  zpm verify <plik.zpk> [--pubkey=P]"
    echo "                                   Sprawdza integralność (sha256 zawartości, per-plik i"
    echo "                                   zagregowaną) i, jeśli podano --pubkey, autentyczność"
    echo "                                   (podpis) archiwum .zpk -- manifest wewnątrz archiwum"
    echo "  zpm install <plik.zpk>            (v0.4) instaluje BEZPOŚREDNIO z lokalnego pliku .zpk,"
    echo "                                   z pełną weryfikacją integralności/podpisu przed instalacją"
    echo "  zpm init                          Inicjalizuje bazę hosta (patrz --trust-keys)"
    echo ""
    echo "  Tryb budowania obrazów (rootfs dla zlb, nigdy nie dotyka hosta):"
    echo "  zpm --root=<ścieżka> [--backend=apt|dnf|pacman|zypper|brew|own] init [--trust-keys=<plik>]"
    echo "  zpm --root=<ścieżka> [--backend=...] install <pkg...>"
    echo "  zpm --root=<ścieżka> [--backend=...] remove  <pkg...>"
    echo "  zpm --root=<ścieżka> sync"
    echo "  zpm --root=<ścieżka> stage <etykieta>   (buduje+instaluje WSZYSTKO z danym `stage` --"
    echo "                                            główny hak dla buildera do pipeline'u bootstrapu)"
    echo "  zpm --building --root=<ścieżka> --backend=<apt|dnf|pacman|zypper> install <pkg...>"
    echo "                                   (forma zgodności wstecznej dla powyższego)"
    echo ""
    echo "Flagi globalne:"
    echo "  -y, --yes           nie pytaj, wybierz automatycznie najlepszego kandydata"
    echo "  -c, --config=ŚCIEŻKA użyj innego pliku konfiguracyjnego niż /etc/zpm/config.hcl"
    echo "      --user-db        użyj lokalnej bazy w $HOME/.local/share/zpm/zpm.db zamiast /var/lib/zpm"
    echo "      --trust-keys=P   (z `init`) REALNIE importuje i persystuje zestaw zaufanych kluczy GPG z"
    echo "                       pliku P (fingerprinty albo blok PGP) -- odtąd verify_signatures wymaga,"
    echo "                       żeby podpis pochodził z tej listy, nie tylko z lokalnego keyringu gpg"
    echo "      --offline        nie dotykaj sieci -- tylko lokalny cache/bundle/zpm.lock"
    echo "                       (przy braku cache'u/bundla `own`/`native` po prostu się nie uda)"
    echo "      --target-arch=A  architektura DOCELOWA (cross-compilation), np. aarch64"
    echo "                       przekazywana skryptom jako ZPM_TARGET_ARCH (patrz README)"
    echo "      --pubkey=P       (z `verify`) klucz publiczny PEM do weryfikacji podpisu pakietu .zpk"
    echo "      --json           strukturalne wyjście JSON (own list/info, list) zamiast tekstu"
    echo "      --verbose        więcej szczegółów diagnostycznych"
    echo "  -q, --quiet          tylko błędy/wynik końcowy"
    echo "  -f, --force          pomiń idempotencję / reverse-dependency check (own install/remove, remove)"
    echo "      --fix            (z `doctor`) napraw automatycznie to, co bezpieczne"
    echo "  -a, --all            (z `list`) widok ujednolicony: SQLite + pokwitowania own + native, z"
    echo "                       oznaczeniem rozjazdów między nimi"
    echo "  -h, --help           pokaż tę pomoc"
    echo "  -v, --version        pokaż wersję"
    echo ""
    echo "Konfiguracja: /etc/zpm/config.hcl"

proc userDbPath(): string =
  getHomeDir() / ".local" / "share" / "zpm" / "zpm.db"

when defined(atomic):
  # ============================================================
  # TRYB ATOMOWY — main()
  # ============================================================
  proc main() =
    var configPath = DefaultConfigPath
    var positional: seq[string] = @[]

    var p = initOptParser(commandLineParams())
    for kind, key, val in p.getopt():
      case kind
      of cmdArgument:
        positional.add(key)
      of cmdLongOption, cmdShortOption:
        case key
        of "help", "h": printHelp(); return
        of "version", "v": echo ZpmVersion; return
        of "config", "c": configPath = val
        else:
          # Nierozpoznana flaga globalnie — przekaż ją dalej jako argument
          # subkomendy (np. `zpm atomic create x --base=...`).
          if val.len > 0:
            positional.add("--" & key & "=" & val)
          else:
            positional.add((if key.len == 1: "-" else: "--") & key)
      of cmdEnd: discard

    let cfg = loadConfig(configPath)

    if positional.len == 0:
      printHelp()
      return
    if positional[0] == "atomic":
      runAtomicCli(cfg, positional[1..^1])
    else:
      echo "[zpm:atomic] W tej binarce dostępna jest tylko rodzina komend `zpm atomic ...`."
      printHelp()

  main()

else:
  # ============================================================
  # TRYB STANDARDOWY — main()
  # ============================================================
  proc main() =
    var configPath = DefaultConfigPath
    var useUserDb = false
    var buildingMode = false
    var buildRoot = ""
    var buildBackend = ""
    var assumeYes = false
    var trustKeys = ""
    var offline = false
    var targetArch = ""
    var jsonOut = false
    var verbose = false
    var quiet = false
    var force = false
    var doctorFix = false
    var listAll = false
    var pubKeyOpt = ""
    var positional: seq[string] = @[]

    var p = initOptParser(commandLineParams())
    for kind, key, val in p.getopt():
      case kind
      of cmdArgument:
        positional.add(key)
      of cmdLongOption, cmdShortOption:
        case key
        of "help", "h": printHelp(); return
        of "version", "v": echo ZpmVersion; return
        of "yes", "y": assumeYes = true
        of "config", "c": configPath = val
        of "user-db": useUserDb = true
        of "building": buildingMode = true
        of "root": buildRoot = val
        of "backend": buildBackend = val
        of "trust-keys": trustKeys = val
        of "offline": offline = true
        of "target-arch": targetArch = val
        of "json": jsonOut = true
        of "verbose": verbose = true
        of "quiet", "q": quiet = true
        of "force", "f": force = true
        of "fix": doctorFix = true
        of "all", "a": listAll = true
        of "pubkey": pubKeyOpt = val
        else: discard
      of cmdEnd: discard

    var cfg = loadConfig(configPath)
    if offline: cfg.offlineMode = true
    if targetArch.len > 0: cfg.targetArch = targetArch
    if jsonOut: cfg.jsonOutput = true
    if verbose: cfg.verbosity = 1
    if quiet: cfg.verbosity = -1
    setLogVerbosity(cfg)

    # `--root` implicitly puts zpm into building mode, matching the
    # ergonomic `zlb` uses: `zpm --root <rootfs> <cmd> ...` -- never
    # touches the host database, mirrors `--building --root=...`.
    if buildRoot.len > 0:
      buildingMode = true

    if buildingMode:
      if positional.len == 0:
        echo "[zpm --building] Użycie: zpm --root=<ścieżka> [--backend=...] <init|install|remove|sync> [pkg...]"
        quit(1)
      case positional[0]
      of "init":
        runBuildingInit(cfg, buildRoot, trustKeys)
      of "install":
        if positional.len < 2:
          echo "[zpm --building] Użycie: zpm --root=<ścieżka> install <pkg...>"
          quit(1)
        runBuilding(cfg, buildRoot, buildBackend, positional[1..^1])
      of "remove", "uninstall":
        runBuildingRemove(cfg, buildRoot, buildBackend, positional[1..^1])
      of "sync":
        runBuildingSync(cfg, buildRoot)
      of "stage":
        if positional.len < 2:
          echo "[zpm --building] Użycie: zpm --root=<ścieżka> stage <etykieta>"
          quit(1)
        runBuildingStage(cfg, buildRoot, positional[1])
      else:
        echo &"[zpm --building] Nieznana komenda: {positional[0]}"
        quit(1)
      return

    if positional.len == 0:
      printHelp()
      return

    # `zpm refresh` -- odświeża TYLKO custom/own-repository.json.
    if positional[0] == "refresh":
      cmdRefresh(cfg)
      return

    # `zpm lock [nazwa...]` -- (re)pinuje zpm.lock.
    if positional[0] == "lock":
      cmdLock(cfg, positional[1..^1])
      return

    # `zpm verify <plik.zpk> [--pubkey=...]` -- odpowiednik `zpk verify`:
    # manifest (v0.4) mieszka W ŚRODKU archiwum, nie obok niego.
    if positional[0] == "verify":
      if positional.len < 2:
        echo "[zpm verify] Użycie: zpm verify <plik.zpk> [--pubkey=<klucz publiczny PEM>]"
        quit(1)
      let (ok, _, messages) = verifyZpkArchive(positional[1], pubKeyOpt)
      for msg in messages:
        echo (if ok: "[zpm verify] ✔ " else: "[zpm verify]   ") & msg
      if ok:
        echo &"[zpm verify] ✔ {positional[1]} zweryfikowany pomyślnie."
      else:
        stderr.writeLine(&"[zpm verify] ✘ weryfikacja {positional[1]} nie powiodła się.")
        quit(1)
      return

    # `zpm doctor` -- diagnostyka rozjazdu baza/pokwitowania vs stan faktyczny.
    if positional[0] == "doctor":
      let dbPath = if useUserDb: userDbPath() else: cfg.dbPath
      let db = openDb(dbPath)
      defer: db.closeDb()
      cmdDoctor(cfg, db, doctorFix)
      return

    # `zpm own <subkomenda>` -- ekosystem Zenit (custom/own-repository.json).
    if positional[0] == "own":
      let sub = if positional.len >= 2: positional[1] else: "list"
      case sub
      of "list":
        let repo = loadOwnRepository(cfg.customRepoPath)
        if cfg.jsonOutput: echo listOwnJson(repo)
        else: listOwn(repo)
      of "refresh":
        cmdRefresh(cfg)
      of "info":
        if positional.len < 3:
          echo "[zpm own] Użycie: zpm own info <nazwa>"
          quit(1)
        let repo = loadOwnRepository(cfg.customRepoPath)
        if cfg.jsonOutput: echo infoOwnJson(repo, positional[2])
        else: infoOwn(repo, positional[2])
      of "build":
        if positional.len < 3:
          echo "[zpm own] Użycie: zpm own build <nazwa>  (tylko narzędzia typu 'git', zależności budowane/instalowane automatycznie)"
          quit(1)
        let repo = loadOwnRepository(cfg.customRepoPath)
        if repo.findTool(positional[2]).name.len == 0:
          echo &"[zpm own] Narzędzie '{positional[2]}' nie występuje w own-repository.json."
          quit(1)
        let rootForBuild = if buildRoot.len > 0: buildRoot else: "/"
        let (ok, _) = buildManyOwn(repo, cfg, positional[2], rootForBuild)
        if not ok: quit(1)
      of "install":
        if positional.len < 3:
          echo "[zpm own] Użycie: zpm own install <nazwa...> [--force]  (zależności instalowane automatycznie)"
          quit(1)
        let repo = loadOwnRepository(cfg.customRepoPath)
        if not installManyOwn(repo, cfg, positional[2..^1], cfg.ownToolsInstallDir, "/", force):
          quit(1)
      of "remove", "uninstall":
        if positional.len < 3:
          echo "[zpm own] Użycie: zpm own remove <nazwa...> [--force]"
          quit(1)
        let repo = loadOwnRepository(cfg.customRepoPath)
        var failed = false
        for name in positional[2..^1]:
          if removeOwn(repo, name, cfg, cfg.ownToolsInstallDir, "/", force) != 0:
            failed = true
        if failed: quit(1)
      of "build-stage":
        if positional.len < 3:
          echo "[zpm own] Użycie: zpm own build-stage <etykieta>  (np. stage0, stage1, stage2 -- patrz README)"
          quit(1)
        let repo = loadOwnRepository(cfg.customRepoPath)
        if not buildStageOwn(repo, cfg, positional[2]):
          quit(1)
      of "install-stage":
        if positional.len < 3:
          echo "[zpm own] Użycie: zpm own install-stage <etykieta>"
          quit(1)
        let repo = loadOwnRepository(cfg.customRepoPath)
        if not installStageOwn(repo, cfg, positional[2], cfg.ownToolsInstallDir, "/"):
          quit(1)
      of "verify-reproducible":
        if positional.len < 3:
          echo "[zpm own] Użycie: zpm own verify-reproducible <nazwa>  (tylko typ 'git')"
          quit(1)
        let repo = loadOwnRepository(cfg.customRepoPath)
        let tool = repo.findTool(positional[2])
        if tool.name.len == 0:
          echo &"[zpm own] Narzędzie '{positional[2]}' nie występuje w own-repository.json."
          quit(1)
        let (ok, _, _) = verifyReproducibleBuild(tool, cfg)
        if not ok: quit(1)
      else:
        echo &"[zpm own] Nieznana podkomenda: {sub}"
        echo "[zpm own] Dostępne: list | info <n> | refresh | build <n> | install <n...> | remove <n...> |"
        echo "                    build-stage <etykieta> | install-stage <etykieta> | verify-reproducible <n>"
        quit(1)
      return

    if positional[0] == "init":
      cmdInit(cfg, trustKeys)
      return

    let dbPath = if useUserDb: userDbPath() else: cfg.dbPath
    let db = openDb(dbPath)
    defer: db.closeDb()

    case positional[0]
    of "install":
      if positional.len < 2:
        echo "[zpm] Użycie: zpm install <pakiet...|plik.zpk> [-y]"
        return
      # v0.4 -- argumenty kończące się na ".zpk" i faktycznie istniejące
      # na dysku instalowane są BEZPOŚREDNIO z pliku (pełna weryfikacja
      # integralności/podpisu, patrz installLocalZpk w zpk.nim), zamiast
      # iść przez wyszukiwanie po backendach (które i tak nie znałoby
      # ścieżki do lokalnego pliku jako "nazwy pakietu"). Reszta
      # argumentów (zwykłe nazwy) idzie normalną ścieżką `cmdInstall`.
      var localFailed = false
      var remaining: seq[string] = @[]
      for arg in positional[1..^1]:
        if arg.toLowerAscii.endsWith(".zpk") and fileExists(arg):
          if installLocalZpk(arg, "/", cfg) != 0:
            localFailed = true
        else:
          remaining.add arg
      if remaining.len > 0:
        cmdInstall(cfg, db, remaining, assumeYes)
      if localFailed:
        quit(1)
    of "remove", "uninstall":
      if positional.len < 2:
        echo "[zpm] Użycie: zpm remove <pakiet...> [--force]"
        return
      cmdRemove(cfg, db, positional[1..^1], force)
    of "update", "upgrade":
      cmdUpdate(cfg)
    of "sync":
      cmdSync(cfg)
    of "list":
      cmdList(db, cfg, listAll)
    else:
      echo &"[zpm] Nieznana komenda: {positional[0]}"
      printHelp()

  main()
