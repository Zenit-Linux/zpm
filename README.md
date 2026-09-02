# zpm — Zenit Package Manager

Prototyp menedżera pakietów dla dystrybucji **Zenit Linux**, napisany
w 100% w języku **Nim**.

> Status: **wczesny prototyp / proof-of-concept**. Kod się kompiluje i
> działa (przetestowano oba tryby), ale interfejsy, format bazy i
> konfiguracja mogą się jeszcze mocno zmienić.

## Filozofia

Zenit Linux ma być dystrybucją, która **buduje samą siebie** — a `zpm`
ma być jednym z jej głównych filarów. Dlatego to jeden kod źródłowy,
z którego w zależności od sposobu kompilacji powstają **dwa różne
programy**:

| Kompilacja | Rezultat |
|---|---|
| `nim c zpm.nim` | **Tryb Standardowy** — inteligentna powłoka nad APT/DNF/Pacman/Zypper/Flatpak/Snap/Cargo/Pip/NPM, z flagą runtime `--building` do budowania obrazów |
| `nim c -d:atomic zpm.nim` | **Tryb Atomowy** — strażnik izolowanych, odtwarzalnych kontenerów/piaskownic |

## 1. Tryb Standardowy

Zakłada, że system bazowy **już istnieje** i jest używany przez
użytkownika. `zpm` nie jest kolejnym menedżerem pakietów obok innych —
jest **orkiestratorem nad tymi, które już masz**.

```bash
zpm install discord
```

1. Równolegle (`spawn`/`threadpool`) przeszukuje wszystkie **obecne na
   hoście** i **włączone w konfiguracji** backendy: apt, dnf, pacman,
   zypper, flatpak, snap, cargo, pip, npm.
2. Pokazuje ponumerowaną listę znalezionych kandydatów wraz ze źródłem.
3. Użytkownik wybiera — instalacja trafia do właściwego backendu.
4. Fakt instalacji (nazwa, wersja, backend, kto/co zażądało) trafia do
   **centralnej bazy SQLite** w `/var/lib/zpm/zpm.db`.

Inne komendy:

```bash
zpm remove <pakiet>     # usuwa pakiet śledzony przez zpm
zpm update               # aktualizuje RÓWNOLEGLE wszystkie rejestry + autoremove/clean
zpm list                 # co zainstalował zpm i skąd
```

Flagi globalne: `-y/--yes` (bez pytania), `-c/--config=<ścieżka>`
(inny plik konfiguracyjny), `-h/--help`, `-v/--version`.

### Tryb budowania (`--building`)

Specjalny tryb runtime (bez osobnej kompilacji) do instalowania
pakietów **do katalogu docelowego**, a nie na system hosta — do
budowania obrazów OCI, ISO instalatora, czy zwykłych rootfsów:

```bash
zpm --building --root=/mnt/target --backend=apt install base-files bash coreutils
```

* Nigdy nie dotyka bazy SQLite hosta.
* Nieinteraktywny (jak w CI).
* Każdy build zostawia log w `/var/cache/zpm/building/build-<timestamp>.log`.

### Ekosystem `own` (`custom/own-repository.json`)

Backend `own` to oficjalna alternatywa dla `curl ... | sh` przy
bootstrapowaniu narzędzi Zenit Linux (`zpm`, `zlb`, `zpk`, `installer`,
`kernel`, ...). Katalog narzędzi opisuje jeden plik JSON, którego
KANONICZNE źródło to osobne repozytorium
[`Zenit-Linux/own-repository`](https://github.com/Zenit-Linux/own-repository)
(`repo/own-repository.json`) -- **nie** repo zpm (to repo to kod źródłowy
samego zpm, trzymanie tam rejestru pakietów nie miało sensu). Nowe/
zaktualizowane wpisy trafiają tam przez Pull Request, tworzony automatycznie
przez [`zpk schedule-release` / `zpk tutorial-release`](https://github.com/Zenit-Linux/zpk).

Na hoście `zpm` trzyma LOKALNĄ, roboczą kopię pod
`/etc/zpm/custom/own-repository.json` (odświeżaną przez `zpm refresh`/
`zpm update` -- patrz `custom.remote_url` w config.hcl), a każdy wpis jest
jednego z dwóch typów:

* **`binary`** — dosłownie zlinkowana, gotowa binarka (`bin`),
  pobierana wprost przez `std/httpclient`, opcjonalnie weryfikowana
  sumą `sha256`.
* **`git`** — repozytorium źródłowe (`repo`), które zpm klonuje/
  aktualizuje do lokalnego cache'u (`custom.git_cache_dir`, domyślnie
  `/var/cache/zpm/own-src`), checkoutuje `ref` (branch/tag/commit), a
  następnie uruchamia po kolei **dwa skrypty w katalogu repo**:
  1. `build_script` (domyślnie `build.<lang>`) — budowanie ze źródeł,
  2. `install_script` (domyślnie `install.<lang>`) — instalacja w
     systemie (host albo `--root=<rootfs>` przy budowaniu obrazu, przez
     zmienną `ZPM_INSTALL_ROOT`).

  Domyślny język to **Janet** (`build.janet` / `install.janet`), ale
  pole `lang` pozwala wskazać inny interpreter/runtime. Szablony obu
  skryptów, wraz z opisem konwencji i przekazywanych zmiennych
  środowiskowych, są w `docs/git-tool-template/`.

Pełny przykładowy plik `own-repository.json` (dokładnie w formacie, jakiego
używa [`Zenit-Linux/own-repository`](https://github.com/Zenit-Linux/own-repository))
jest w `docs/own-repository.example.json`. Kilka pól wartych osobnego
opisu:

* **`description`** — krótki opis narzędzia. Od schema v0.5 to jest
  nazwa docelowa tego pola (`"info"` jest nadal czytane jako
  przestarzały alias dla wstecznej zgodności ze starszymi plikami, ale
  `zpm own list/info --json` zawsze SERIALIZUJE `"description"`).
* **`tags`** — etykiety narzędzia, albo jako string rozdzielony
  przecinkami (`"tags": "de, graphical-environment"` — konwencja
  własnego repozytorium), albo jako tablica stringów
  (`"tags": ["de", "graphical-environment"]`) — obie formy są
  równoważne. Filtrowanie: `zpm own list --tag=de`.
* **`{version}`** — placeholder w polu `bin` (URL musi wskazywać na
  `github.com`), podmieniany PRZED pobraniem:
  `zpm own install zenit-base` sam ustala najnowszą wersję przez
  GitHub Releases API; `zpm own install zenit-base@1.2.0` wymusza
  dokładnie tę wersję, bez żadnego zapytania sieciowego.
* **`branches`** — alternatywne "systemy"/warianty tego samego
  narzędzia (np. `kernel` ma `stable`, gotowy `.zpk` z wydania, i
  `rolling`, budowany ze źródeł przy każdej instalacji). Zobacz
  `zpm own systems <nazwa>` i `zpm own install <nazwa> --branch=<system>`.

```bash
zpm own list                 # co jest w own-repository.json (typ, źródło, opis, tagi, zależności)
zpm own list --tag=de        # tylko narzędzia z danym tagiem (np. graficzne środowiska)
zpm own info kernel          # pełne szczegóły jednego narzędzia (w tym dostępne systemy/branches)
zpm own systems kernel       # -> stable, rolling
zpm own build kernel         # (tylko 'git') buduje 'kernel' I jego zależności (patrz niżej), bez
                              # końcowej instalacji samego 'kernel'
zpm install kernel           # albo: zpm own install kernel — build + install, z zależnościami
zpm own install kernel --branch=stable    # instaluje gotowy .zpk zamiast budować ze źródeł
zpm own install zenit-base@1.2.0          # wymusza dokładną wersję zamiast auto-detekcji "najnowszej"
zpm own remove kernel         # usuwa (binary: kasuje plik; git: wymaga uninstall_script)

zpm refresh                  # pobiera świeży own-repository.json z custom.remote_url (a przy
                              # błędzie kolejno z custom.mirrors), WALIDUJE go i dopiero wtedy
                              # podmienia lokalną kopię (poprzednia trafia do <ścieżka>.bak);
                              # `zpm own refresh` to alias tej samej komendy
zpm update                   # robi to samo "przy okazji" (jak dotąd), oprócz
                              # odświeżania wszystkich innych backendów (w tym indeksu `zenit`)
```

#### Graf zależności (`depends_on`)

Każdy wpis może mieć `"depends_on": ["nazwa", ...]` — inne narzędzia
z tego samego pliku, które muszą być zainstalowane wcześniej. `zpm own
build/install <nazwa>` (oraz zwykłe `zpm install <nazwa>` przez backend
`own`) same wyliczają poprawną kolejność sortowaniem topologicznym
(`src/zpmpkg/deps.nim`) i **odmawiają** działania, gdy graf zawiera
cykl albo brakującą zależność — zamiast po cichu zainstalować coś
w złej kolejności.

#### Reprodukowalność: `zpm.lock`

`own-repository.json` z `"ref": "main"` to ruchomy cel — dwa buildy
tego samego dnia mogą dać różny wynik. `zpm lock [nazwa...]` rozwiązuje
`ref` na dokładny commit (dla `git`) albo sumę `sha256` faktycznie
pobranego pliku (dla `binary`) i zapisuje to w `zpm.lock`
(`reproducible.lock_path`, domyślnie `/etc/zpm/zpm.lock`). Każdy
kolejny `build`/`install` **automatycznie** używa zablokowanego wpisu
zamiast na nowo pytać "main" o to, co tam aktualnie jest:

```bash
zpm lock                     # zablokuj WSZYSTKIE narzędzia z own-repository.json
zpm lock kernel zpm          # zablokuj tylko wskazane
```

#### Praca offline / vendoring źródeł

```bash
zpm --offline own build kernel
```

Z `--offline` (albo `core`-owo `security`/`custom.vendor_sources`,
patrz config) zpm **nie dotyka sieci**: dla `git` używa istniejącego
lokalnego klonu albo `git bundle` zvendorowanego wcześniej
(`custom.vendor_sources = true` przy pierwszym buildzie online tworzy
taki bundle obok cache'u), dla `refresh`/indeksu `zenit` po prostu
zostawia to, co już jest na dysku. Jeśli ani klonu, ani bundla nie ma —
zpm jawnie odmawia (nie "prawie działa", tylko czytelny błąd).

#### Bezpieczeństwo: podpisy, wymuszony pinning, piaskownica

`security { }` w configu (patrz `docs/config.hcl`):
* `verify_signatures = true` — `git verify-commit`/`verify-tag` przed
  użyciem repo (wymaga zaufanego keyringu GPG operatora).
* `require_pinned_ref = true` — odmowa budowania, gdy `ref` to
  "main"/"master" bez odpowiadającego wpisu w `zpm.lock`.
* `sandbox_enabled = true` — `build.<lang>`/`install.<lang>` uruchamiane
  przez `bwrap`: bez dostępu do sieci (chyba że dany wpis ma
  `"allow_network": true`) ani do systemu plików poza katalogiem repo
  i katalogiem stagingu instalacji (patrz "Transakcyjność" niżej).
  `security.sandbox_required = true` (domyślnie): brak `bwrap` w PATH
  to **twardy błąd instalacyjny**, nie ciche działanie bez ochrony —
  świadome wyłączenie tego zabezpieczenia zostaje z ostrzeżeniem.
* `build_timeout_sec = 3600` — `timeout` (coreutils) wokół KAŻDEGO
  uruchomienia build/install/recipe; zawieszony kompilator albo proces
  czekający na stdin nie wisi w nieskończoność. `build_memory_limit`/
  `build_cpu_quota` dokładają do tego (best effort) limity CPU/RAM
  przez `systemd-run --scope` (cgroups) — `bwrap` sam z siebie limituje
  tylko FS/sieć, nie zasoby.

#### Transakcyjność instalacji (`own` typu git)

`install.<lang>` pisze teraz do TYMCZASOWEGO katalogu stagingu
(`ZPM_INSTALL_ROOT` wskazuje na staging, nie wprost na `rootPath`) —
dopiero po tym, jak skrypt zwróci kod 0, zpm kopiuje staging do
właściwego miejsca. Nieudany `install.<lang>` **nie dotyka już**
systemu docelowego wcale (wcześniej mógł zostawić częściowo
napisane drzewo plików). To nie jest pełna atomowa podmiana (kopiowanie
samo może się przerwać w połowie) — pełną atomowość rootfs-a daje
dopiero Tryb Atomowy (overlayfs).

#### Blokady współbieżności (`flock`)

Dwa równoległe procesy `zpm` (typowe w CI z kilkoma jobami buildera)
nie biją się już o tę samą bazę SQLite, ten sam katalog cache'u git per
narzędzie, ani `zpm.lock` — `src/zpmpkg/filelock.nim` opakowuje te
zasoby blokadą plikową (`flock`, `security.lock_timeout_sec` zanim zpm
podda się czytelnym błędem zamiast wisieć w nieskończoność).

#### Idempotencja i reverse-dependency check

`zpm own install`/`installManyOwn` zapisują **pokwitowanie** instalacji
(`src/zpmpkg/state.nim`, `state.own_dir`) z dokładnym commitem (git)
albo sumą sha256 (binary). Kolejne wywołanie z tym samym stanem
**pomija** pracę (chyba że `--force`) — `zpm own install kernel`
uruchomione drugi raz nie przebudowuje `zpm` od zera jako zależności.
To samo pokwitowanie zasila `zpm own remove`: usunięcie narzędzia,
którego (wedle pokwitowań) potrzebuje inne zainstalowane narzędzie,
jest **blokowane** (`directDependents` z `deps.nim`), chyba że
`--force`.

#### Cross-compilation

`--target-arch=aarch64` (albo `zpm own build ...` w trybie
`--root=<rootfs>`) ustawia `ZPM_TARGET_ARCH` w środowisku
`build.<lang>`/`install.<lang>` (obok zawsze obecnego
`ZPM_HOST_ARCH`) — recipe/build script sam decyduje, jak z tego
skorzystać (np. wybór triple'a kompilatora, `qemu-user-static` do
testów).

#### Cache kompilacji (ccache/sccache)

Każde uruchomienie `build.<lang>` dostaje `CCACHE_DIR`/`SCCACHE_DIR`
ustawione na osobny podkatalog per narzędzie pod `ccache.dir`
(domyślnie `/var/cache/zpm/ccache`) — build script musi sam z tego
skorzystać (np. `CC="ccache gcc"`), zpm tego nie wymusza.

### Bootstrap: `stage`, `own build-stage`, `verify-reproducible`

Zenit Linux ma budować samą siebie. Pełny pipeline **stage0 → stage1 →
stage2** (minimalny seed toolchain → zbuduj nim właściwy Zenit →
zbuduj się jeszcze raz JUŻ zbudowanym Zenitem) to celowo zadanie
**buildera** (np. `zlb`), nie samego `zpm` — to builder decyduje, kiedy
przełączyć się na świeżo zbudowany toolchain i skąd wziąć pierwszy
`zpm` (ściąga binarkę sam, zanim `zpm` w ogóle zacznie działać — to
jest w porządku i nie jest problemem, który zpm musiałby rozwiązywać).

zpm dostarcza natomiast narzędzia, na których taki pipeline może stanąć:

* `"stage": "stage1"` — czysto informacyjna etykieta na każdym wpisie
  w `own-repository.json`; zpm jej nie interpretuje poza filtrowaniem.
* `zpm own build-stage <etykieta>` / `zpm own install-stage <etykieta>`
  — buduje/instaluje WSZYSTKIE narzędzia z daną etykietą (plus ich
  zależności, w poprawnej kolejności) jednym poleceniem, więc builder
  nie musi znać nazw poszczególnych narzędzi:

  ```bash
  zpm --root=/mnt/rootfs stage stage1     # w trybie budowania obrazu
  zpm own install-stage stage1            # albo wprost na hoście/w chroot
  ```
* `zpm own verify-reproducible <nazwa>` — buduje to samo narzędzie typu
  `git` **dwukrotnie**, do dwóch niezależnych katalogów cache'u, i
  porównuje sumy kontrolne wynikowych drzew plików. To jest praktyczna
  wersja testu "stage2 buduje stage2 i porównuje wynik" z dokumentacji
  bootstrapu — narzędzie do weryfikacji, a nie orkiestracja całego
  pipeline'u (tę robi builder, wołając powyższe komendy w swojej
  własnej kolejności, prawdopodobnie z `chroot`/kontenerem między
  etapami).

### Natywny format pakietów (`.zpk`, backend `zenit`)

Sformalizowana wersja tego, co robi ekosystem `own` typu `git`, ale
z pełnymi metadanymi (nazwa/wersja/architektura/zależności/suma
kontrolna/opcjonalny podpis) i **spakowanym, wersjonowanym artefaktem**
zamiast instalowania wprost ze źródeł za każdym razem — odpowiednik
.deb/.rpm/.pkg.tar.zst, tylko swój (`src/zpmpkg/zpk.nim`), w pełni
zgodny z formatem, który produkuje osobne narzędzie
[`zpk`](https://github.com/Zenit-Linux/zpk) -- **budowanie `.zpk`
robi WYŁĄCZNIE `zpk build`** (`zpm` samo nic nie pakuje/nie buduje --
`zpm` to instalator/menedżer, nie builder); `zpm` zajmuje się
wyszukiwaniem, instalacją, weryfikacją i usuwaniem gotowych `.zpk`.

```bash
# zbuduj (w osobnym narzędziu `zpk`, nie tutaj):
#   zpk init && zpk build --release

zpm search cr                 # znajdzie go przez backend `zenit`, jeśli jest
                               # w indeksie (native.repo_index_url)
zpm install cr                 # pobiera .zpk (z native.repo_index_url), w pełni
                               # weryfikuje integralność (i podpis, jeśli skonfigurowano
                               # native.verify_pubkey) PRZED rozpakowaniem względem "/"

zpm install ./cr-1.2.0-x86_64.zpk   # instalacja BEZPOŚREDNIO z lokalnego pliku
                                     # .zpk (np. zbudowanego przez `zpk build`),
                                     # z tą samą pełną weryfikacją co wyżej

zpm verify ./cr-1.2.0-x86_64.zpk [--pubkey=~/.zpk/signing-key.pub]
                               # sprawdza integralność (i podpis, jeśli podano
                               # --pubkey) bez instalowania -- odpowiednik `zpk verify`
```

Indeks (`ZpkRepoIndex`) to jeden plik JSON analogiczny do `Packages.gz`
z APT — `zpm update`/`zpm refresh` odświeżają go z `native.repo_index_url`
tak samo jak `own-repository.json`. Instalacja zapisuje pełną listę
plików pakietu (`ZpkInstallReceipt`), więc `zpm remove <nazwa>` realnie
kasuje dokładnie to, co zostało zainstalowane (tak jak `.deb`/`.rpm`),
zamiast tylko odznaczać pakiet jako "zainstalowany".

**Autentyczność (opcjonalna, v0.4):** jeśli `native.verify_pubkey`
wskazuje na klucz publiczny PEM (RSA/EC lub Ed25519), `zpm install`/
`zpm verify` weryfikują podpis pakietu (o ile go ma) przed instalacją;
`native.require_signature = true` odrzuca instalację pakietów, które w
ogóle nie są podpisane. Bez tej konfiguracji zachowanie jest jak
wcześniej — weryfikowana jest tylko integralność (sha256), a obecność
podpisu jest tylko odnotowywana ostrzeżeniem. Patrz też `zpk`'s
`ZPK_SIGN_KEY`/`zpk build --sign-key=` do podpisywania.

```hcl
native {
  repo_index_url    = "https://raw.githubusercontent.com/Zenit-Linux/zenit-repo/main/index.json"
  repo_cache_dir    = "/var/cache/zpm/native-repo"
  package_out_dir   = "/var/cache/zpm/packages"
  verify_pubkey      = "/etc/zpm/keys/zenit-signing.pub"  # opcjonalne
  require_signature = false                                 # opcjonalne
}
```


## 2. Tryb Atomowy (`-d:atomic`)

```bash
nim c -d:atomic -o:zpm-atomic src/zpm.nim
```

Ta sama nazwa binarki, kompletnie inne zachowanie — program przestaje
być orkiestratorem hosta, a staje się **strażnikiem atomowych
kontenerów**:

```bash
zpm atomic create devbox --base=debian:stable
zpm atomic install devbox neovim
zpm atomic enter devbox
zpm atomic list
zpm atomic destroy devbox
```

Kontenery żyją w `atomic.store_path` (domyślnie `/var/lib/zpm/atomic`),
każdy jako katalog z `rootfs/`, `upper/`, `work/` (przygotowane pod
overlayfs) i metadanymi w `zpm-container.json`. Jeśli w systemie jest
dostępny `podman`, jest używany do realnej izolacji; w środowisku bez
podmana `zpm` tworzy pusty szkielet (tryb offline/prototypowy).

## Konfiguracja: `/etc/zpm/config.hcl`

Format HCL (bloki, `klucz = wartość`, listy `["a","b"]`), parsowany przez
bibliotekę [`hcl_nim`](https://github.com/Zenit-Linux/hcl-nim) (`src/zpmpkg/hcl.nim`
to cienka warstwa kompatybilności nad nią — pełny parser HCL v1/v2, nie
ręcznie pisany fragment składni):

```hcl
core {
  db_path                = "/var/lib/zpm/zpm.db"
  parallel_updates       = true
  confirm_before_install = true
}

backends {
  enabled         = ["flatpak", "apt", "dnf", "pacman", "zypper", "snap", "cargo", "pip", "npm"]
  preferred_order = ["flatpak", "apt", "dnf", "pacman", "zypper", "snap", "cargo", "pip", "npm"]
}

atomic {
  store_path = "/var/lib/zpm/atomic"
}

building {
  cache_dir = "/var/cache/zpm/building"
}

custom {
  repository_path = "/etc/zpm/custom/own-repository.json"
  remote_url       = "https://raw.githubusercontent.com/Zenit-Linux/own-repository/main/repo/own-repository.json"
  mirrors          = ["https://mirror.zenit-linux.org/zpm/own-repository.json"]
  install_dir      = "/usr/local/bin"
  git_cache_dir    = "/var/cache/zpm/own-src"
  vendor_sources   = false
}

reproducible {
  lock_path         = "/etc/zpm/zpm.lock"
  source_date_epoch = 0
}

security {
  verify_signatures  = true
  require_pinned_ref = true
  sandbox_enabled    = true
  sandbox_cmd        = "bwrap"
  sandbox_required   = true
  build_timeout_sec  = 3600
  build_memory_limit = "4G"
  build_cpu_quota    = "200%"
  lock_timeout_sec   = 120
}

state {
  own_dir    = "/var/lib/zpm/own-installed"
  native_dir = "/var/lib/zpm/native-installed"
}

ccache {
  dir = "/var/cache/zpm/ccache"
}

native {
  repo_index_url  = "https://raw.githubusercontent.com/Zenit-Linux/zenit-repo/main/index.json"
  repo_cache_dir  = "/var/cache/zpm/native-repo"
  package_out_dir = "/var/cache/zpm/packages"
}
```

**Bezpieczeństwo domyślnie WŁĄCZONE.** `verify_signatures`,
`require_pinned_ref` i `sandbox_enabled` są `true` od razu po instalacji
— domyślna instalacja Zenit Linuksa nie ufa cicho kodowi z internetu.
Konsekwencje praktyczne:
* `bwrap` i `git`/`gpg` muszą być zainstalowane na hoście/w środowisku
  buildera — ich brak to **twardy błąd** (`quit`), nie ostrzeżenie.
* Nowy wpis `git` w `own-repository.json` z `"ref": "main"` **nie
  zbuduje się**, dopóki nie uruchomisz `zpm lock <nazwa>` (co pinuje
  dokładny commit) — to świadome zabezpieczenie przed budowaniem
  z ruchomego celu bez wiedzy operatora.
* Świadome obniżenie ochrony (np. w kontrolowanym, zaufanym CI) wymaga
  jawnego `= false`/`sandbox_required = false` w configu.

Baza danych **celowo nie jest** w `$HOME` — żyje w `/var/lib/zpm`,
bo to stan systemu, nie stan użytkownika (flaga `--user-db` w trybie
standardowym pozwala przełączyć się na bazę per-użytkownik).

## Struktura projektu

```
zpm/
├── zpm.nimble                    # definicja pakietu + zadania (nimble standard / nimble atomic)
├── etc/zpm/config.hcl            # przykładowa konfiguracja produkcyjna
└── src/
    ├── zpm.nim                   # punkt wejścia — routing standard/atomic
    └── zpmpkg/
        ├── types.nim             # wspólne typy (PackageCandidate, ZpmConfig, ...)
        ├── hcl.nim                # warstwa kompatybilności nad hcl_nim (parser HCL v1/v2)
        ├── config.nim             # wczytywanie /etc/zpm/config.hcl
        ├── database.nim           # warstwa SQLite (centralna baza zainstalowanych pakietów)
        ├── orchestrator.nim       # serce Trybu Standardowego (search/install/update/refresh/lock/list)
        ├── ownrepo.nim            # ekosystem `own`: parsowanie/refresh JSON, binarki, build+install git,
        │                          # zależności, stage/bootstrap, offline/vendor, sandbox, reprodukowalność
        ├── deps.nim                # graf zależności `own` (depends_on): sortowanie topologiczne + cykle
        ├── lockfile.nim            # zpm.lock: pinowanie commitów git / sum sha256
        ├── state.nim                # pokwitowania instalacji `own` (idempotencja, reverse-dependency check)
        ├── filelock.nim             # blokady plikowe (flock) -- baza SQLite, cache git, zpm.lock
        ├── zpk.nim                  # natywny format pakietów Zenit (.zpk): recipe.janet, indeks, instalacja
        ├── building.nim           # logika --building (w tym `stage` -- hak dla buildera/bootstrapu)
        ├── atomic.nim             # logika Trybu Atomowego (aktywna tylko z -d:atomic)
        └── backends/
            ├── common.nim         # wspólne narzędzia (wykrywanie binarek, uruchamianie procesów)
            ├── apt.nim
            ├── dnf.nim
            ├── pacman.nim
            ├── zypper.nim
            ├── flatpak.nim
            ├── snap.nim
            ├── cargo.nim
            ├── pip.nim
            └── npm.nim
```

## Budowanie

```bash
nimble install -d      # (obecnie brak zależności zewnętrznych — sqlite/json/threadpool to stdlib)

# Tryb standardowy (wymaga --threads:on z powodu threadpool):
nim c --threads:on -d:release --out:bin/zpm src/zpm.nim

# Tryb atomowy:
nim c -d:release -d:atomic --out:bin/zpm-atomic src/zpm.nim
```

⚠️ **Ten konkretny stan kodu (moduły `deps.nim`, `lockfile.nim`,
`state.nim`, `filelock.nim`, `zpk.nim` i rozległe zmiany w
`ownrepo.nim`/`orchestrator.nim`/`database.nim`/`hcl.nim`) NIE został
skompilowany ani przetestowany** — środowisko, w którym to powstało,
nie miało zainstalowanego `nim`/`janet`. Wcześniejsza, dużo węższa
wersja prototypu (bez ekosystemu `own`, bez trybu `--building`) była
kiedyś skompilowana i ręcznie przetestowana, ale to nieaktualne wobec
skali zmian od tamtej pory. **Przed jakimkolwiek wdrożeniem: `nim
check`, pełna kompilacja obu wariantów, i przegląd każdej nowej komendy
ręcznie** — to twardy warunek wstępny, nie "miło by było".

## Co dalej — czego brakuje do zastosowań produkcyjnych

To wciąż prototyp. Sporo z pierwotnej listy braków jest już
zaimplementowane (opisane wyżej): graf zależności, `zpm.lock`,
offline/vendoring, podpisy/piaskownica/pinning **domyślnie WŁĄCZONE**,
limity zasobów (`timeout`/`systemd-run`), blokady `flock`,
transakcyjna instalacja (staging), idempotencja i reverse-dependency
check, realne usuwanie `.zpk`, poprawiony `installed_at`, walidacja
`schema_version`, `--json`/`zpm doctor`, cross-compilation, natywny
format `.zpk`, cache kompilacji, haki dla bootstrapu przez `stage`.
To, co realnie zostaje:

**v0.4 (najnowsze):**
* Manifest pakietu `.zpk` (`manifest.json`) mieszka W ŚRODKU archiwum,
  nie w osobnym `<plik>.zpk.json`/`<plik>.zpk.sig` obok niego -- format
  BIT-W-BIT zgodny z tym, co produkuje osobne narzędzie `zpk`.
* Weryfikacja PODPISU (nie tylko sha256) pakietów `.zpk` przy
  `zpm install`/`zpm verify`, sterowana `native.verify_pubkey`/
  `native.require_signature` -- wcześniej `zpm` w ogóle nie czytało
  pola `signature` z manifestu, nawet jeśli `zpk` je policzyło.
* `zpm verify <plik.zpk>` -- lokalny odpowiednik `zpk verify`.
* `zpm install <plik.zpk>` -- instalacja BEZPOŚREDNIO z lokalnego
  pliku, z pełną weryfikacją, bez przechodzenia przez indeks.
* `own-repository.json`: pole `bin` może być obiektem `{arch: url}`
  (multi-arch) -- wcześniej `zpm` po cichu odrzucało takie wpisy jako
  "puste 'bin'"; teraz wybiera wariant dla `native.target_arch`/hosta.

**Bezpieczeństwo (v0.2/v0.3):**
* Sandbox przez `bwrap` (domyślnie) LUB przez efemeryczny kontener
  podman/buildah (`security.build_isolation = "container"`) --
  `build_memory_limit`/`build_cpu_quota` przez `systemd-run`, a gdy
  niedostępny, przez bezpośredni zapis do cgroups v2 (fallback);
  `security.strict_resource_limits = true` zamienia całkowity brak
  mechanizmu w twardy błąd zamiast cichego "best effort".
* Merge stagingu (`stagingsafety.nim`) odrzuca staging zawierający
  JAKIKOLWIEK symlink i sprawdza przed każdym zapisem, czy katalog
  nadrzędny w `rootPath` nie jest symlinkiem -- sandbox chroni PRZED
  stagingiem, TEN mechanizm chroni SAM staging przy scalaniu.
* `--trust-keys` REALNIE blokuje: fingerprint podpisującego klucza
  musi być na liście, inaczej instalacja jest odrzucana (nie tylko
  komunikat) -- także w trybie budowania (`--root=<r>`), per-obraz.
* TLS pinning (`security.pin_sha256`) egzekwowany REALNIE przez
  jednorazowe połączenie `openssl s_client` przed właściwym żądaniem;
  `security.trusted_hosts` -- allowlist hostów dla remote_url/mirrors/repo.

**Niezawodność / UX (v0.2/v0.3):**
* `zpm own install A B` -- nieudane B cofa (rollback) A, jeśli A
  zostało nowo zainstalowane w TYM wywołaniu
  (`security.rollback_on_failure`, domyślnie true).
* Merge stagingu do `rootPath`: każdy pojedynczy plik podmieniany
  atomowo (tmp + rename w tym samym katalogu) + pre-check miejsca na
  dysku + rollback nadpisanych/nowych plików przy błędzie w trakcie.
  UCZCIWIE: to wciąż nie jest jedna atomowa transakcja na CAŁYM
  rootfs -- pełna atomowość na tym poziomie to zadanie Trybu Atomowego.
* Cache HTTP (`ETag`/`If-Modified-Since`) dla `refresh`/indeksu natywnego
  -- niezmieniona treść nie jest ściągana ponownie.
* Progres pobierania (`--verbose`) i limity rozmiaru (`security.max_download_mb`).
* Deduplikacja wyników wyszukiwania między backendami hosta (`alsoIn`).
* `zpm doctor` odpytuje REALNY stan apt/dnf/pacman/zypper/flatpak/snap/
  brew/cargo/npm/pip (nie tylko `own`), `--fix` naprawia osierocone
  pokwitowania/wpisy locka automatycznie.

**Poprawność / kompletność (v0.2/v0.3):**
* Tryb Atomowy: overlayfs REALNIE montowany, podman ORAZ buildah
  wspierane, plus tryb `chroot` bez żadnego silnika kontenerowego.
  Cross-distro (`pakiet -> apt -> debian.testing`) instaluje w
  izolowanym kontenerze, scala tylko diff (`upper/`) do `rootPath`.
* `--json`/`--verbose`/`--quiet` honorowane spójnie przez `logging.nim`
  w większości modułów (nie tylko kilku wybranych komend).
* `zpm list --all` daje ujednolicony widok SQLite + pokwitowania
  `own`/`native`, oznaczając rozjazdy -- ALE `own` i `native` nadal mają
  OSOBNE mechanizmy pokwitowań/blokad pod spodem (to nie zniknęło,
  tylko dostało wspólny punkt odczytu).
* Realna integracja `podman`/`buildah` w Trybie Atomowym (overlayfs,
  wykrywanie menedżera pakietów w kontenerze) -- `systemd-nspawn`
  wciąż niewspierany.
* HCL: parser jest teraz twardszy (numery linii, jawne błędy przy
  niedomkniętych blokach/stringach/listach, escapowane cudzysłowy),
  ale nadal nie wspiera wielolinijkowych stringów, heredoc ani
  interpolacji -- spory, ale wciąż celowy podzbiór.

**Operacyjne:**
* Testy jednostkowe/integracyjne (`nimble test`) i CI budujące oba
  warianty (standard + atomic), najlepiej też z realnym `zpm refresh`,
  `zpm lock`, `zpm own build-stage`/`verify-reproducible`, `zpm verify`
  i `zpm doctor` przeciw testowemu repo git/recipe.janet.
* Strony podręcznika / shell completion (bash/zsh/fish) — nie istnieją.
* `zpm doctor` nie naprawia niczego automatycznie (celowo, patrz wyżej)
  — brak trybu `--fix`.

### O bootstrapie stage0 → stage1 → stage2

Świadomie **nie** ma tu pełnej orkiestracji wieloetapowego bootstrapu —
to zadanie buildera (`zlb`), który sam decyduje o kolejności etapów i
sam dostarcza pierwszy `zpm` (stage0), zanim `zpm` w ogóle zacznie
działać. `zpm` daje temu builderowi trzy konkretne haki: etykietę
`stage` do filtrowania, `own build-stage`/`install-stage`/`zpm --root
... stage <etykieta>` do wykonania całego etapu jednym poleceniem
(z poprawną kolejnością zależności), i `own verify-reproducible` do
sprawdzenia, że dany komponent daje ten sam wynik przy dwóch
niezależnych buildach. Złożenie tego w pełny pipeline (w tym decyzję,
kiedy przełączyć `chroot`/kontener na świeżo zbudowany toolchain)
pozostaje po stronie buildera.
