import std/[times]

type
  BackendKind* = enum
    bkApt        = "apt"
    bkDnf        = "dnf"
    bkPacman     = "pacman"
    bkZypper     = "zypper"
    bkFlatpak    = "flatpak"
    bkSnap       = "snap"
    bkCargo      = "cargo"
    bkPip        = "pip"
    bkNpm        = "npm"
    bkBrew       = "brew"     ## Homebrew / Linuxbrew
    bkOwn        = "own"      ## własny ekosystem Zenith (custom/own-repository.json)
    bkZenithNat  = "zenith"   ## natywny format pakietów Zenith Linux (na przyszłość)

  PackageCandidate* = object
    name*: string             ## nazwa pakietu w danym backendzie
    version*: string          ## wersja (jeśli znana, inaczej "")
    description*: string      ## krótki opis
    backend*: BackendKind      ## który menedżer go dostarcza
    installCmd*: seq[string]   ## komenda instalacji (argv)
    extra*: string             ## dodatkowe info (np. repo, kanał flatpak)

  InstalledPackage* = object
    id*: int
    name*: string
    backend*: BackendKind
    version*: string
    requestedBy*: string       ## "user" | "dependency" | "build"
    installedAt*: DateTime
    origin*: string            ## nazwa/identyfikator użyty przy instalacji

  ZpmMode* = enum
    modeStandard   ## klasyczny orkiestrator hosta
    modeBuilding   ## budowanie obrazu (--building lub --root)
    modeAtomic     ## strażnik kontenerów atomowych (kompilacja -d:atomic)

  ## ---- własny ekosystem Zenith (custom/own-repository.json) --------------
  ##
  ## Format pliku:
  ## {
  ##   "tools": [
  ##     { "name": "cr", "bin": "https://.../cr" },
  ##     { "name": "ow", "bin": "https://.../ow" }
  ##   ]
  ## }
  ##
  ## Każdy wpis to narzędzie z ekosystemu Zenith Linux (np. `zpm` samo,
  ## `installer`, i przyszłe narzędzia), dystrybuowane jako pojedyncza,
  ## doslownie zlinkowana binarka. `zpm install <name>` (backend `own`)
  ## pobiera ją i instaluje z weryfikacją -- to jest oficjalna alternatywa
  ## dla `curl ... | sh` przy bootstrapowaniu narzędzi Zenith.
  OwnRepoTool* = object
    name*: string              ## nazwa narzędzia, np. "zpm", "installer", "cr"
    bin*: string                ## dosłowny URL do binarki
    sha256*: string             ## opcjonalny checksum do weryfikacji (może być puste)

  OwnRepository* = object
    tools*: seq[OwnRepoTool]

  PackageSpec* = object
    ## Wpis z package.list / argumentu CLI: nazwa pakietu + opcjonalny
    ## wymuszony backend, np. "systemd" albo "systemd -> apt" / "systemd@apt".
    name*: string
    backend*: string           ## "" = autodetekcja/domyślny backend

  ZpmConfig* = object
    dbPath*: string            ## ścieżka do bazy SQLite, domyślnie /var/lib/zpm/zpm.db
    enabledBackends*: seq[BackendKind]
    parallelUpdates*: bool
    confirmBeforeInstall*: bool
    preferredOrder*: seq[BackendKind]  ## kolejność preferencji przy remisach
    atomicStorePath*: string   ## gdzie trzymane są kontenery atomowe
    buildingCacheDir*: string  ## katalog cache przy budowaniu obrazów
    customRepoPath*: string    ## ścieżka do custom/own-repository.json
    ownToolsInstallDir*: string ## gdzie trafiają binarki backendu `own` (host)
    defaultBuildingBackend*: string ## domyślny backend dla `zpm --root ...` bez `--backend`
