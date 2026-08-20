# zpm — Zenith Package Manager

Prototyp menedżera pakietów dla dystrybucji **Zenith Linux**, napisany
w 100% w języku **Nim**.

> Status: **wczesny prototyp / proof-of-concept**. Kod się kompiluje i
> działa (przetestowano oba tryby), ale interfejsy, format bazy i
> konfiguracja mogą się jeszcze mocno zmienić.

## Filozofia

Zenith Linux ma być dystrybucją, która **buduje samą siebie** — a `zpm`
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

Uproszczony format HCL (bloki, `klucz = wartość`, listy `["a","b"]`),
parsowany bez zewnętrznych zależności (`src/zpmpkg/hcl.nim`):

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
```

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
        ├── hcl.nim                # własny, minimalny parser HCL
        ├── config.nim             # wczytywanie /etc/zpm/config.hcl
        ├── database.nim           # warstwa SQLite (centralna baza zainstalowanych pakietów)
        ├── orchestrator.nim       # serce Trybu Standardowego (search/install/update/list)
        ├── building.nim           # logika --building
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

Oba warianty zostały skompilowane i przetestowane (tworzenie/wypisywanie
kontenerów atomowych, wyszukiwanie i instalacja przez APT, tryb
`--building` z logowaniem do pliku) w środowisku prototypowym.

## Co dalej (poza zakresem tego prototypu)

* Realna integracja z `podman`/`buildah`/`systemd-nspawn` dla pełnej
  izolacji namespace'ów w Trybie Atomowym (overlayfs, cgroups, sieć).
* Natywny format pakietów Zenith Linux (`bkZenithNat` w `types.nim` już
  zarezerwowany).
* Rozstrzyganie konfliktów wersji między backendami i deduplikacja
  wyników wyszukiwania.
* Podpisywanie i weryfikacja pochodzenia pakietów w bazie SQLite.
* Pełniejszy parser HCL (obecny to celowo okrojony podzbiór).
* Testy jednostkowe (`nimble test`) i CI budujące oba warianty.
