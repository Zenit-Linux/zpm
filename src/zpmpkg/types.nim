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
    modeBuilding   ## budowanie obrazu (--building)
    modeAtomic     ## strażnik kontenerów atomowych (kompilacja -d:atomic)

  ZpmConfig* = object
    dbPath*: string            ## ścieżka do bazy SQLite, domyślnie /var/lib/zpm/zpm.db
    enabledBackends*: seq[BackendKind]
    parallelUpdates*: bool
    confirmBeforeInstall*: bool
    preferredOrder*: seq[BackendKind]  ## kolejność preferencji przy remisach
    atomicStorePath*: string   ## gdzie trzymane są kontenery atomowe
    buildingCacheDir*: string  ## katalog cache przy budowaniu obrazów
