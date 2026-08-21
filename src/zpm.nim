import std/[os, parseopt, strutils, strformat]
import ./zpmpkg/types
import ./zpmpkg/config
import ./zpmpkg/database
import ./zpmpkg/ownrepo

when defined(atomic):
  import ./zpmpkg/atomic
else:
  import ./zpmpkg/orchestrator
  import ./zpmpkg/building

const ZpmVersion = "0.1.0-proto"

proc printBanner() =
  when defined(atomic):
    echo &"zpm {ZpmVersion} — Zenith Package Manager [TRYB ATOMOWY / STRAŻNIK KONTENERÓW]"
  else:
    echo &"zpm {ZpmVersion} — Zenith Package Manager [TRYB STANDARDOWY]"

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
    echo "  zpm remove  <pakiet...>          Usuwa 1+ pakiet(ów) śledzonych przez zpm"
    echo "  zpm update | upgrade             Aktualizuje wszystkie rejestry (równolegle) i sprząta"
    echo "  zpm sync                         Alias `update` (zgodny z wywołaniami zlb)"
    echo "  zpm list                         Listuje pakiety zainstalowane przez zpm"
    echo "  zpm own list                     Listuje narzędzia z custom/own-repository.json"
    echo "  zpm init                          Inicjalizuje bazę hosta (patrz --trust-keys)"
    echo ""
    echo "  Tryb budowania obrazów (rootfs dla zlb, nigdy nie dotyka hosta):"
    echo "  zpm --root=<ścieżka> [--backend=apt|dnf|pacman|zypper|brew|own] init [--trust-keys=<plik>]"
    echo "  zpm --root=<ścieżka> [--backend=...] install <pkg...>"
    echo "  zpm --root=<ścieżka> [--backend=...] remove  <pkg...>"
    echo "  zpm --root=<ścieżka> sync"
    echo "  zpm --building --root=<ścieżka> --backend=<apt|dnf|pacman|zypper> install <pkg...>"
    echo "                                   (forma zgodności wstecznej dla powyższego)"
    echo ""
    echo "Flagi globalne:"
    echo "  -y, --yes           nie pytaj, wybierz automatycznie najlepszego kandydata"
    echo "  -c, --config=ŚCIEŻKA użyj innego pliku konfiguracyjnego niż /etc/zpm/config.hcl"
    echo "      --user-db        użyj lokalnej bazy w $HOME/.local/share/zpm/zpm.db zamiast /var/lib/zpm"
    echo "      --trust-keys=P   (z `init`) zaufaj zestawowi kluczy repo z pliku P"
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
        else: discard
      of cmdEnd: discard

    let cfg = loadConfig(configPath)

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
      else:
        echo &"[zpm --building] Nieznana komenda: {positional[0]}"
        quit(1)
      return

    if positional.len == 0:
      printHelp()
      return

    # `zpm own <list>` -- inspekcja ekosystemu Zenith bez dotykania hosta.
    if positional[0] == "own":
      let repo = loadOwnRepository(cfg.customRepoPath)
      listOwn(repo)
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
        echo "[zpm] Użycie: zpm install <pakiet...> [-y]"
        return
      cmdInstall(cfg, db, positional[1..^1], assumeYes)
    of "remove", "uninstall":
      if positional.len < 2:
        echo "[zpm] Użycie: zpm remove <pakiet...>"
        return
      cmdRemove(cfg, db, positional[1..^1])
    of "update", "upgrade":
      cmdUpdate(cfg)
    of "sync":
      cmdSync(cfg)
    of "list":
      cmdList(db)
    else:
      echo &"[zpm] Nieznana komenda: {positional[0]}"
      printHelp()

  main()
