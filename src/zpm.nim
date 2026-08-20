import std/[os, parseopt, strutils, strformat]
import ./zpmpkg/types
import ./zpmpkg/config
import ./zpmpkg/database

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
    echo "  zpm install <pakiet> [-y]        Szuka i instaluje pakiet ze wszystkich backendów"
    echo "  zpm remove  <pakiet>             Usuwa pakiet śledzony przez zpm"
    echo "  zpm update                       Aktualizuje wszystkie rejestry (równolegle) i sprząta"
    echo "  zpm list                         Listuje pakiety zainstalowane przez zpm"
    echo "  zpm --building --root=<ścieżka> --backend=<apt|dnf|pacman|zypper> install <pkg...>"
    echo "                                   Instaluje pakiety do obrazu / rootfsu, NIE na hosta"
    echo ""
    echo "Flagi globalne:"
    echo "  -y, --yes           nie pytaj, wybierz automatycznie najlepszego kandydata"
    echo "  -c, --config=ŚCIEŻKA użyj innego pliku konfiguracyjnego niż /etc/zpm/config.hcl"
    echo "      --user-db        użyj lokalnej bazy w $HOME/.local/share/zpm/zpm.db zamiast /var/lib/zpm"
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
    var buildBackend = "apt"
    var assumeYes = false
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
        else: discard
      of cmdEnd: discard

    let cfg = loadConfig(configPath)

    if buildingMode:
      # Tryb budowania obrazów — nie dotyka bazy hosta, nie pyta interaktywnie.
      if positional.len < 2 or positional[0] != "install":
        echo "[zpm --building] Użycie: zpm --building --root=<ścieżka> --backend=<apt|dnf|pacman|zypper> install <pkg...>"
        quit(1)
      let packages = positional[1..^1]
      runBuilding(cfg, buildRoot, buildBackend, packages)
      return

    if positional.len == 0:
      printHelp()
      return

    let dbPath = if useUserDb: userDbPath() else: cfg.dbPath
    let db = openDb(dbPath)
    defer: db.closeDb()

    case positional[0]
    of "install":
      if positional.len < 2:
        echo "[zpm] Użycie: zpm install <pakiet> [-y]"
        return
      cmdInstall(cfg, db, positional[1], assumeYes)
    of "remove", "uninstall":
      if positional.len < 2:
        echo "[zpm] Użycie: zpm remove <pakiet>"
        return
      cmdRemove(cfg, db, positional[1])
    of "update", "upgrade":
      cmdUpdate(cfg)
    of "list":
      cmdList(db)
    else:
      echo &"[zpm] Nieznana komenda: {positional[0]}"
      printHelp()

  main()
