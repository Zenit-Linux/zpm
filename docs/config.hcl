core {
  db_path                 = "/var/lib/zpm/zpm.db"
  parallel_updates        = true
  confirm_before_install  = true
}

backends {
  // Kolejność ma znaczenie tylko przy remisach (kilka backendów ma ten sam pakiet)
  enabled = ["own", "flatpak", "apt", "dnf", "pacman", "zypper", "snap", "brew", "cargo", "pip", "npm"]

  preferred_order = ["own", "flatpak", "apt", "dnf", "pacman", "zypper", "snap", "brew", "cargo", "pip", "npm"]
}

// Ustawienia aktywne wyłącznie w binarce skompilowanej z -d:atomic
atomic {
  store_path = "/var/lib/zpm/atomic"
}

// Ustawienia aktywne przy uruchomieniu z flagą --building lub --root
building {
  cache_dir       = "/var/cache/zpm/building"
  // backend używany, gdy `zpm --root <ścieżka> install <pkg>` nie mówi
  // wprost skąd brać pakiet (patrz distro.hcl -> default_backend w zlb,
  // oraz składnia "pakiet -> backend" w modules/*/package.list)
  default_backend = "apt"
}

// Własny ekosystem Zenit Linux -- narzędzia (zlb, zpk, installer, kernel,
// i inne) dystrybuowane albo jako pojedyncze binarki spod dosłownych
// URL-i (type=binary), albo jako repozytoria git budowane ze źródeł
// przez build.<lang> + install.<lang> (type=git, domyślnie lang=janet).
// Backend `own` szuka tu kandydatów, `zpm refresh` (lub `zpm own refresh`)
// pobiera świeżą wersję tego pliku z `remote_url` i podmienia lokalną
// kopię pod `repository_path` (dopiero po pomyślnym sparsowaniu -- stara
// kopia trafia do <repository_path>.bak).
//
// v0.3: kanoniczne źródło tego pliku to OSOBNE repozytorium
// https://github.com/Zenit-Linux/own-repository (plik repo/own-repository.json)
// -- NIE repo zpm. Wcześniej ten plik mieszkał w custom/own-repository.json
// WEWNĄTRZ repo zpm, co nie miało sensu: to repo to kod źródłowy samego
// zpm, nie rejestr pakietów. `zpk schedule-release`/`zpk tutorial-release`
// (osobne narzędzie, https://github.com/Zenit-Linux/zpk) publikują tam
// nowe/zaktualizowane wpisy przez Pull Request. `repository_path` poniżej
// to WCIĄŻ LOKALNA ścieżka cache'u na hoście (nazwa katalogu "custom/"
// pozostała bez zmian -- to tylko lokalna kopia robocza, nie źródło).
custom {
  repository_path = "/etc/zpm/custom/own-repository.json"
  remote_url       = "https://raw.githubusercontent.com/Zenit-Linux/own-repository/main/repo/own-repository.json"
  // Próbowane po kolei, jeśli remote_url zawiedzie (np. rate-limit GitHuba).
  mirrors          = ["https://mirror.zenit-linux.org/own-repository/own-repository.json"]
  install_dir      = "/usr/local/bin"
  git_cache_dir    = "/var/cache/zpm/own-src"
  // Po udanym `git clone` online od razu twórz lokalny `git bundle`
  // (obok cache'u) -- pozwala potem budować w trybie --offline bez sieci.
  vendor_sources   = false
}

// Reprodukowalność buildów: zpm.lock + SOURCE_DATE_EPOCH.
// `zpm lock [nazwa...]` pinuje dokładne commity git / sumy sha256 binarek
// -- bez tego `ref: "main"` w own-repository.json oznacza, że dwa buildy
// tego samego dnia mogą dać różny wynik.
reproducible {
  lock_path          = "/etc/zpm/zpm.lock"
  // 0 = wylicz automatycznie (data commitu / czas builda dla każdego narzędzia)
  source_date_epoch  = 0
}

// Bezpieczeństwo wykonywania kodu ze źródeł -- kluczowe, bo cały ekosystem
// `own` typu git (łącznie z jądrem/toolchainem w scenariuszu bootstrapu)
// powstaje przez uruchamianie pobranych z internetu build.<lang>/install.<lang>.
// UWAGA: poniższe wartości to DOMYŚLNE zpm (bezpieczne z założenia) --
// ten blok pokazuje je jawnie do wglądu, nie jako "włącz to sam".
// Wyłączanie (np. verify_signatures=false) obniża bezpieczeństwo świadomie.
security {
  // git verify-commit / verify-tag przed użyciem repo (wymaga zaufanego
  // keyringu GPG operatora -- zpm go nie zarządza, tylko woła `git verify-*`)
  verify_signatures   = true
  // odmów budowania, gdy ref to "main"/"master" bez wpisu w zpm.lock
  require_pinned_ref  = true
  // uruchamiaj build/install przez `bwrap` -- bez dostępu do sieci (chyba
  // że "allow_network": true w danym wpisie) ani do systemu plików poza
  // katalogiem repo i ZPM_INSTALL_ROOT
  sandbox_enabled     = true
  sandbox_cmd         = "bwrap"
  // gdy true (domyślnie): brak `bwrap` (sandbox_enabled) albo `gpg`
  // (verify_signatures) w PATH to TWARDY błąd instalacyjny (quit) --
  // NIE ciche kontynuowanie bez ochrony. Ustaw false świadomie tylko
  // w kontrolowanym, zaufanym środowisku CI.
  sandbox_required    = true
  // limit czasu KAŻDEGO uruchomienia build/install/recipe -- runaway
  // proces (zawieszony kompilator, proces czekający na stdin) nie zjada
  // maszyny buildera w nieskończoność. 0 = bez limitu.
  build_timeout_sec   = 3600
  // best-effort limity zasobów przez `systemd-run --scope` (pomijane po
  // cichu -- z ostrzeżeniem -- gdy systemd-run niedostępny w PATH)
  build_memory_limit  = "4G"
  build_cpu_quota     = "200%"
  // ile sekund czekać na zajętą blokadę plikową (baza/cache/lockfile),
  // zanim zpm podda się z czytelnym błędem zamiast wisieć w nieskończoność
  lock_timeout_sec    = 120
}

// Pokwitowania instalacji -- gdzie zpm zapisuje CO faktycznie wylądowało
// na dysku (lista plików dla .zpk, zablokowany commit dla `own` typu git).
// Używane przez `zpm remove` (realne kasowanie plików .zpk) i idempotencję
// (`installManyOwn` nie buduje/instaluje ponownie tego, co już jest).
state {
  own_dir    = "/var/lib/zpm/own-installed"
  native_dir = "/var/lib/zpm/native-installed"
}

// Cache kompilacji (ccache/sccache), osobny podkatalog per narzędzie --
// bez tego przebudowanie jądra/toolchaina od zera w pętli bootstrapu
// (stage0 -> stage1 -> stage2 -> weryfikacja fixed-point) jest nie do
// przyjęcia czasowo.
ccache {
  dir = "/var/cache/zpm/ccache"
}

// Natywny format pakietów Zenit (.zpk, backend `zenit` / bkZenitNat) --
// `zpm pack <katalog> --name=... --pkg-version=...` buduje recipe.janet
// i pakuje wynik; `zpm search`/`install`/`update` @ backend `zenit`
// czytają stąd indeks (analogicznie do Packages.gz w APT).
native {
  repo_index_url   = "https://raw.githubusercontent.com/Zenit-Linux/zenit-repo/main/index.json"
  repo_cache_dir   = "/var/cache/zpm/native-repo"
  package_out_dir  = "/var/cache/zpm/packages"
}
