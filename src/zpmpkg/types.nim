import std/[times, json, tables]

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
    bkOwn        = "own"      ## własny ekosystem Zenit (custom/own-repository.json)
    bkZenitNat   = "zenit"    ## natywny format pakietów Zenit Linux (na przyszłość)

  PackageCandidate* = object
    name*: string             ## nazwa pakietu w danym backendzie
    version*: string          ## wersja (jeśli znana, inaczej "")
    description*: string      ## krótki opis
    backend*: BackendKind      ## który menedżer go dostarcza
    installCmd*: seq[string]   ## komenda instalacji (argv)
    extra*: string             ## dodatkowe info (np. repo, kanał flatpak)
    alsoIn*: seq[BackendKind]  ## v0.2: inne backendy hosta, które zwróciły TEN SAM pakiet (deduplikacja
                                ## wyników `searchAll` -- patrz `dedupCandidates` w orchestrator.nim)

  InstalledPackage* = object
    id*: int
    name*: string
    backend*: BackendKind
    version*: string
    requestedBy*: string       ## "user" | "dependency" | "build"
    installedAt*: DateTime
    origin*: string            ## nazwa/identyfikator użyty przy instalacji
    status*: string            ## "installed" | "failed" -- patrz database.nim/recordFailed

  ZpmMode* = enum
    modeStandard   ## klasyczny orkiestrator hosta
    modeBuilding   ## budowanie obrazu (--building lub --root)
    modeAtomic     ## strażnik kontenerów atomowych (kompilacja -d:atomic)

  ## ---- własny ekosystem Zenit (custom/own-repository.json) --------------
  ##
  ## Format pliku (pełna, rozbudowana wersja):
  ## {
  ##   "schema_version": 1,
  ##   "tools": [
  ##     { "name": "cr", "type": "binary", "bin": "https://.../cr", "sha256": "..." },
  ##     {
  ##       "name": "kernel",
  ##       "type": "git",
  ##       "repo": "https://github.com/Zenit-Linux/kernel.git",
  ##       "ref": "main",
  ##       "lang": "janet",
  ##       "build_script": "build.janet",
  ##       "install_script": "install.janet",
  ##       "info": "kernel, build from source"
  ##     }
  ##   ]
  ## }
  ##
  ## Każdy wpis to narzędzie z ekosystemu Zenit Linux (np. `zpm` samo,
  ## `installer`, `kernel`, `zlb` i przyszłe narzędzia). Wspierane są DWA
  ## rodzaje dystrybucji (pole `type`, patrz OwnToolKind):
  ##
  ##  - `binary` -- dosłownie zlinkowana, gotowa binarka (`bin`), pobierana
  ##    wprost przez std/httpclient i (opcjonalnie) weryfikowana sumą
  ##    sha256. To oficjalna alternatywa dla `curl ... | sh`.
  ##
  ##  - `git` -- repozytorium źródłowe (`repo`, dawniej też dozwolone jako
  ##    `bin` kończące się na ".git" -- wykrywane automatycznie dla
  ##    wstecznej zgodności z istniejącym own-repository.json). zpm klonuje
  ##    (lub aktualizuje) repo do lokalnego cache'u, checkoutuje `ref`
  ##    (branch/tag/commit, domyślnie "main"), a następnie uruchamia po
  ##    kolei DWA skrypty w katalogu repo:
  ##      1. `build_script`   (domyślnie "build.<ext języka>")   -- budowanie ze źródeł
  ##      2. `install_script` (domyślnie "install.<ext języka>") -- instalacja w systemie
  ##    Domyślny język to Janet (`janet build.janet`, `janet install.janet`),
  ##    ale `lang` pozwala wskazać inny interpreter/runtime (patrz
  ##    `langInterpreter` w ownrepo.nim).
  OwnToolKind* = enum
    otkBinary = "binary"   ## pojedyncza, gotowa binarka pod dosłownym URL-em
    otkGit    = "git"      ## repozytorium git budowane ze źródeł (build.janet + install.janet)

  OwnRepoTool* = object
    name*: string              ## nazwa narzędzia, np. "zpm", "installer", "cr"
    kind*: OwnToolKind          ## otkBinary | otkGit
    bin*: string                ## dosłowny URL do binarki (tylko dla otkBinary)
    sha256*: string             ## opcjonalny checksum do weryfikacji (może być puste)
    info*: string                ## opcjonalny, krótki opis narzędzia
    repo*: string                ## URL repozytorium git (tylko dla otkGit)
    gitRef*: string              ## branch/tag/commit do checkoutowania (domyślnie "main")
    lang*: string                 ## język/runtime skryptów budujących, domyślnie "janet"
    buildScript*: string          ## nazwa skryptu budującego, domyślnie "build.<ext>"
    installScript*: string        ## nazwa skryptu instalującego, domyślnie "install.<ext>"
    uninstallScript*: string      ## opcjonalny skrypt odinstalowujący (może być puste)
    buildArgs*: seq[string]       ## dodatkowe argumenty przekazywane do skryptu budującego
    installArgs*: seq[string]     ## dodatkowe argumenty przekazywane do skryptu instalującego
    dependsOn*: seq[string]       ## nazwy innych narzędzi `own`, które muszą być zbudowane/
                                    ## zainstalowane wcześniej (graf zależności, patrz deps.nim)
    stage*: string                 ## etykieta etapu bootstrapu, czysto informacyjna dla buildera
                                    ## (np. zlb) -- zpm jej NIE interpretuje, tylko przekazuje
                                    ## dalej (ZPM_TOOL_STAGE) i wypisuje w `own info`/`own list`
    allowNetwork*: bool            ## czy build/install SMIE mieć dostęp do sieci w piaskownicy
                                    ## (domyślnie false -- patrz sandbox w ownrepo.nim)
    signed*: bool                  ## czy `ref` (tag/commit) ma być zweryfikowany GPG-em przed
                                    ## checkoutem (git verify-tag/verify-commit)
    rawJson*: JsonNode              ## v0.3 -- pełny oryginalny wpis JSON tego narzędzia (potrzebny do
                                     ## rozwiązywania "branches" -- patrz resolveOwnToolBranch w
                                     ## ownrepo.nim). Nie jest serializowany/porównywany nigdzie poza tym.

  OwnRepository* = object
    schemaVersion*: int
    tools*: seq[OwnRepoTool]

  ## ---- zpm.lock -- reprodukowalność --------------------------------------
  ## Pinuje DOKŁADNY stan świata w chwili udanego builda: dla narzędzi `git`
  ## dokładny commit (nie branch/tag, które mogą się przesunąć), dla `binary`
  ## sumę sha256 faktycznie pobranego pliku. `zpm own build/install` używa
  ## zablokowanego wpisu zamiast `gitRef`/`bin`, jeśli lockfile go zawiera
  ## -- to jest to, co odróżnia "buduje się z 'main'" od "buduje się
  ## deterministycznie z tego, co dokładnie zbudowało się poprzednim razem".
  LockEntry* = object
    name*: string
    kind*: OwnToolKind
    resolvedRef*: string       ## dokładny commit git (kind=git) -- 40 znaków sha1/sha256
    sha256*: string             ## suma binarki (kind=binary) lub tree-hash (kind=git, opcjonalnie)
    sourceUrl*: string           ## repo/bin w chwili blokowania (wykrywanie dryfu URL-a)
    lockedAt*: string             ## znacznik czasu ISO8601

  ZpmLockFile* = object
    schemaVersion*: int
    sourceDateEpoch*: int64      ## znormalizowany czas budowania (patrz SOURCE_DATE_EPOCH)
    entries*: seq[LockEntry]

  ## ---- natywny format pakietów Zenit (.zpk) ------------------------------
  ## Sformalizowana wersja tego, co robi ekosystem `own` typu `git`, ale
  ## z pełnymi metadanymi wersji/zależności/architektury i spakowanym
  ## artefaktem (tar.zst) zamiast "zainstaluj wprost ze źródeł od nowa".
  ZpkManifest* = object
    name*: string
    version*: string
    arch*: string                ## np. "x86_64", "aarch64", "any"
    dependsOn*: seq[string]
    sha256*: string               ## suma samego archiwum .zpk
    description*: string
    buildRecipe*: string           ## nazwa/ścieżka recipe.janet użytego do zbudowania (informacyjnie)
    builtAt*: string                ## znacznik czasu ISO8601 builda pakietu
    files*: seq[ZpkFileEntry]        ## lista plików (ścieżka względna do "/" + sha256) --
                                      ## pozwala na realne `zpm remove` (jak w .deb), nie tylko instalację

  ZpkFileEntry* = object
    path*: string     ## ścieżka WZGLĘDNA do "/", np. "usr/local/bin/cr"
    sha256*: string

  ZpkRepoIndex* = object
    schemaVersion*: int
    packages*: seq[ZpkManifest]

  ## Pokwitowanie instalacji jednego pakietu .zpk NA DANYM `rootPath` --
  ## osobno od indeksu (który opisuje co JEST DOSTĘPNE), to opisuje co
  ## FAKTYCZNIE wylądowało na dysku w tym konkretnym miejscu, i pozwala
  ## `removeNative` skasować dokładnie te pliki, nie zgadywać.
  ZpkInstallReceipt* = object
    name*: string
    version*: string
    rootPath*: string
    files*: seq[ZpkFileEntry]
    installedAt*: string

  ## Analogiczne pokwitowanie dla narzędzi ekosystemu `own` typu `git` --
  ## `install.janet` może zrobić dowolną rzecz, więc jedyne co zpm wie na
  ## pewno to NA JAKIM COMMICIE i DO JAKIEGO ROOTA się to udało. Używane
  ## do idempotencji (installManyOwn nie buduje/instaluje ponownie tego,
  ## co już jest na miejscu z tym samym commitem) i do reverse-dependency
  ## check przy `own remove`.
  OwnInstallReceipt* = object
    name*: string
    resolvedRef*: string     ## commit/ref, na którym się zainstalowało (kind=git) albo "" (kind=binary)
    sha256*: string            ## suma binarki zainstalowanej (kind=binary)
    rootPath*: string
    installedAt*: string

  PackageSpec* = object
    ## Wpis z package.list / argumentu CLI: nazwa pakietu + opcjonalny
    ## wymuszony backend, np. "systemd" albo "systemd -> apt" / "systemd@apt".
    ##
    ## v0.3 -- rozbudowane o `variant` (trzeci segment po drugiej "->") i
    ## opcjonalny opis po ":", patrz `parsePackageSpec` w orchestrator.nim:
    ##   kernel -> own -> testing         : branch "testing" narzędzia 'own'
    ##   git -> apt -> debian.testing     : zainstaluj z Debiana testing,
    ##                                       nie z natywnych repo hosta
    ##   curl                             : pusty backend/variant = weź
    ##                                       domyślny branch/distro z distro.hcl
    name*: string
    backend*: string           ## "" = autodetekcja/domyślny backend
    variant*: string           ## v0.3: "" = domyślny. Dla backendu "own" -- nazwa brancha
                                ## (stable/rolling/semi-rolling/testing/...) z pola "branches"
                                ## w own-repository.json. Dla backendów hosta (apt/dnf/...) --
                                ## docelowa dystrybucja (opcjonalnie z ".suite", np.
                                ## "debian.testing") -- patrz crossdistro.nim: instalacja NIE
                                ## dotyka natywnej bazy pakietów hosta, tylko izolowanego
                                ## kontenera tej dystrybucji (bezpieczeństwo -- patrz komentarz
                                ## w crossdistro.nim).
    description*: string       ## v0.3: opcjonalny opis po ":" w package.list -- czysto
                                ## informacyjny (wyświetlany w `zpm list`/logach), nieużywany
                                ## do żadnej logiki instalacji.

  ZpmConfig* = object
    dbPath*: string            ## ścieżka do bazy SQLite, domyślnie /var/lib/zpm/zpm.db
    enabledBackends*: seq[BackendKind]
    parallelUpdates*: bool
    confirmBeforeInstall*: bool
    preferredOrder*: seq[BackendKind]  ## kolejność preferencji przy remisach
    atomicStorePath*: string   ## gdzie trzymane są kontenery atomowe
    buildingCacheDir*: string  ## katalog cache przy budowaniu obrazów
    customRepoPath*: string    ## ścieżka do lokalnej kopii custom/own-repository.json
    ownRepoUrl*: string        ## zdalny URL, z którego `zpm refresh` pobiera own-repository.json
    ownRepoMirrors*: seq[string] ## dodatkowe URL-e-mirrory, próbowane po kolei gdy ownRepoUrl zawiedzie
    ownToolsInstallDir*: string ## gdzie trafiają binarki backendu `own` (host)
    ownGitCacheDir*: string    ## gdzie zpm klonuje repozytoria git narzędzi typu `git` (own)
    defaultBuildingBackend*: string ## domyślny backend dla `zpm --root ...` bez `--backend`

    # ---- reprodukowalność / zpm.lock --------------------------------------
    lockPath*: string           ## ścieżka do zpm.lock
    sourceDateEpoch*: int64      ## 0 = wylicz automatycznie (data commitu / czas builda)

    # ---- offline / vendoring -----------------------------------------------
    offlineMode*: bool           ## ustawiane runtime przez --offline; brak sieci = tylko cache
    vendorSources*: bool          ## czy po udanym `git clone` tworzyć lokalny `git bundle` do cache'u

    # ---- bezpieczeństwo budowania -------------------------------------------
    verifySignatures*: bool      ## weryfikuj `git verify-tag`/`verify-commit` przed użyciem repo
    requirePinnedRef*: bool       ## odmów budowania, gdy `ref` to "main"/"master" (bez zpm.lock)
    sandboxEnabled*: bool          ## uruchamiaj build/install przez `bwrap` (jeśli obecny w PATH)
    sandboxCmd*: string             ## nazwa polecenia piaskownicy, domyślnie "bwrap"
    sandboxRequired*: bool           ## gdy true (domyślnie): brak `bwrap`/`gpg` w PATH to TWARDY błąd
                                       ## instalacyjny (quit), nie ciche działanie bez ochrony
    buildTimeoutSec*: int             ## limit czasu (`timeout <n>s`) na KAŻDE uruchomienie
                                        ## build.<lang>/install.<lang>/recipe.janet -- 0 = bez limitu
    buildMemoryLimit*: string          ## np. "4G" -- limit pamięci przez `systemd-run -p MemoryMax=`
                                        ## (v0.2: gdy systemd-run niedostępny, PRÓBUJE cgroups v2 wprost
                                        ## zanim odda "best effort"; patrz resourceWrap w ownrepo.nim)
    buildCpuQuota*: string              ## np. "200%" -- limit CPU przez `systemd-run -p CPUQuota=`
    strictResourceLimits*: bool         ## v0.2: gdy true, brak JAKIEGOKOLWIEK mechanizmu egzekwowania
                                         ## build_memory_limit/build_cpu_quota (ani systemd-run, ani
                                         ## cgroups v2 zapisywalne) to TWARDY błąd, nie tylko ostrzeżenie

    # ---- v0.2: sieć -- zaufane hosty / limity pobierania / cache HTTP ------
    trustedHosts*: seq[string]     ## security.trusted_hosts -- puste = brak ograniczenia (jak dawniej);
                                    ## niepuste = KAŻDE pobieranie (remote_url/mirrors/repo/bin/native
                                    ## indeks) musi mieć host na tej liście, inaczej twardy błąd
    pinnedCertSha256*: seq[string]  ## security.pin_sha256 -- opcjonalne piny SHA-256 certyfikatów
                                     ## TLS (DER) dla dodatkowej warstwy ponad samo CA-trust hosta
    maxDownloadMb*: int              ## security.max_download_mb -- 0 = bez limitu; w przeciwnym razie
                                      ## pobieranie przerywane, gdy Content-Length (albo faktyczny
                                      ## rozmiar w locie) przekroczy ten limit
    httpCacheDir*: string            ## cache.http_cache_dir -- ETag/Last-Modified dla refresh/indeksu

    # ---- v0.2: transakcyjność wielo-pakietowych operacji `own` --------------
    rollbackOnFailure*: bool         ## security.rollback_on_failure (domyślnie true) -- `zpm own
                                      ## install A B C`, gdzie B się nie uda, cofa (usuwa) A, jeśli A
                                      ## zostało NOWO zainstalowane w tym samym wywołaniu

    # ---- v0.2: zaufane klucze GPG (--trust-keys) -----------------------------
    trustedKeysStatePath*: string    ## gdzie persystuje się zestaw zaufanych fingerprintów po `init
                                      ## --trust-keys=<plik>` (patrz trustedkeys.nim)

    # ---- v0.3: kilka trybów izolacji budowania 'own' -------------------------
    buildIsolation*: string          ## security.build_isolation -- "bwrap" (domyślnie, obecny
                                      ## `sandboxWrap`: przestrzenie nazw dzielą jądro hosta, szybkie,
                                      ## bez osobnego obrazu) | "container" (v0.3: build/install
                                      ## uruchamiane WEWNĄTRZ efemerycznego kontenera podman/buildah
                                      ## -- innego obrazu bazowego niż host, mocniejsza izolacja
                                      ## kosztem czasu startu; patrz containerSandboxWrap w
                                      ## containerengine.nim) | "none" (jawny, głośno ostrzegany opt-out)
    buildIsolationImage*: string      ## obraz bazowy dla build_isolation="container"

    # ---- v0.3: instalacja cross-distro (pakiet -> backend -> dystrybucja) ----
    crossDistroImages*: Table[string, string]  ## native.distro_images -- nadpisania/dodatki do
                                                ## wbudowanej mapy dystrybucja->obraz kontenerowy
                                                ## (patrz crossdistro.nim); "{suite}" w wartości jest
                                                ## podmieniane na suitę z package.list (np. "testing")

    # ---- blokady współbieżności (flock) --------------------------------------
    lockTimeoutSec*: int           ## ile czekać na zajętą blokadę pliku, zanim zpm się podda

    # ---- stan instalacji (idempotencja, pokwitowania) ------------------------
    ownStateDir*: string           ## OwnInstallReceipt per narzędzie (idempotencja `own`, reverse-deps)
    nativeStateDir*: string         ## ZpkInstallReceipt per (pakiet, root) -- realne `zpm remove` dla .zpk

    # ---- wyjście / logowanie ---------------------------------------------------
    jsonOutput*: bool               ## ustawiane runtime przez --json
    verbosity*: int                  ## -1 = --quiet, 0 = domyślny, 1 = --verbose

    # ---- cross-compilation ---------------------------------------------------
    targetArch*: string           ## ustawiane runtime przez --target-arch ("" = arch hosta)

    # ---- cache budowania (ccache/sccache) -------------------------------------
    ccacheDir*: string             ## katalog bazowy cache'u kompilacji, per-narzędzie w podkatalogach

    # ---- natywny format pakietów (.zpk / bkZenitNat) ---------------------------
    nativeRepoIndexUrl*: string    ## URL zdalnego indeksu pakietów .zpk (jak Packages.gz w APT)
    nativeRepoCacheDir*: string     ## lokalny cache indeksu + pobranych .zpk
    nativePackageOutDir*: string     ## gdzie `zpm pack` zostawia zbudowane .zpk
