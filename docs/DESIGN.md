# Projekt zpm

* **Kolejność w `guard`:** atrapa → (opcjonalnie) usunięcie zainstalowanych zastąpionych pakietów `rpm -e --nodeps` → blokady. Usunięcie po
  atrapie zostawia bazę rpm spójną (zależności są spełnione przez Provides).
* **Wersja atrapy:** `Release` = FNV-1a z posortowanej listy `provides`; zmiana profilu daje nowe wydanie i `rpm -U --oldpackage --replacepkgs`.
* **Blokady:** `zypper addlock`; istnienie sprawdzane w `<root>/etc/zypp/locks` (`solvable_name:`), więc `guard` jest idempotentny.
* **Opcje:** `--root`, `--profile`, `--no-guard`, `--zpm-dry` należą do zpm; reszta globalnych opcji (także z wartością, np. `--pkg-cache-dir X`) idzie do zypper.
* **Granica odpowiedzialności:** zpm nie jest solverem. Nie zastępuje zypper — wstrzykuje do jego świata prawdziwe, ale puste pakiety i blokady.
* **Czego atrapa nie załatwi:** pakiet, który naprawdę *uruchamia* funkcje systemd (D-Bus `org.freedesktop.systemd1`, logind), nie zadziała —
  to ograniczenie zenitd (zob. docs/COMPAT.md zenitd), nie zpm. Biblioteki (`libsystemd0`, `libudev1`) i `udev` nie są blokowane domyślnie.
* **Dystrybucja zpm:** niezdecydowana (pakiet RPM we własnym repo / binarka z GitHub Releases). zlb szuka `zpm` w PATH albo pod `zpm.binary`.
