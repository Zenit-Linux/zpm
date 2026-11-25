# zpm — Zenit Package Manager

Nakładka na **zypper** dla dystrybucji openSUSE Tumbleweed **bez systemd** (Zenit Linux i inne). Napisana w całości w [Z#](https://github.com/Zenit-Linux/Z-Sharp).

## Problem

Pakiety Tumbleweed mają zależności od `systemd` (`Requires: systemd >= N`, `Requires: /usr/bin/systemctl`, makra `%service_*`).
Jeśli init to zenitd, zypper i tak wciągnie systemd jako zależność. Usunięcie go potem przez `rpm -e --nodeps` zostawia zepsutą bazę
zależności (`zypper verify` krzyczy), a przy kolejnej aktualizacji systemd wraca.

## Rozwiązanie

zpm pilnuje **profilu init**. Dla profili bez systemd (`zenitd`, `nosystemd`, `openrc`, `runit`, własne) przed każdą transakcją:

1. instaluje **pakiet-atrapę** `zpm-stub-<profil>` — RPM bez plików, który tylko zgłasza `Provides: systemd = 99999`, `/usr/bin/systemctl`, … Zależności są spełnione, więc solver nie ma powodu sięgać po prawdziwy systemd, a baza rpm pozostaje spójna;
2. dodaje **blokady** zypper (`systemd`, `systemd-*`) — zastąpione pakiety nie wrócą nawet przez `zypper dup`.

Profil `systemd` niczego nie zmienia: zpm jest wtedy przezroczystym wrapperem.

```
zpm profile set zenitd           # zapisuje /etc/zpm/zpm.conf
zpm install openssh-server       # = zypper install ... (po drodze: atrapa + blokady)
zpm dup                          # j.w. dla dist-upgrade
zpm analyze gnome-shell          # symulacja: czy wciągnie systemd?
zpm guard --purge                # system już ma systemd? zainstaluj atrapę i usuń go spójnie
zpm doctor                       # atrapa, blokady, zainstalowane zastąpione pakiety
zpm -R /ścieżka/rootfs install … # praca na rootfs (budowa obrazów — tak używa go zlb)
```

Każda inna komenda zypper (`se`, `info`, `rm`, `ref`, `lr` …) i jego opcje globalne są przekazywane bez zmian.

## Profile

`zpm profile list|show|set|current`. Własny profil: `/etc/zpm/profiles.d/<nazwa>.toml`
```toml
description = "s6 jako init"
block    = ["systemd", "systemd-*", "udev"]     # wzorce glob: blokady zypper
allow    = ["systemd-rpm-macros"]               # wyjątki od block
provides = ["systemd = 99999", "/usr/bin/systemctl"]   # co ma zgłaszać atrapa
```
Profil o nazwie wbudowanego nadpisuje jego pola (scalanie).

## Budowanie i testy

Wymaga: zypper, rpm, **rpmbuild** (pakiet `rpm-build`) do zbudowania atrapy.
```
ZSC0=/ścieżka/do/zsc0 scripts/test.sh                    # 60 asercji, w tym prawdziwy rpmbuild + rpm --root (gdy dostępne)
zsc build src/main.zsharp --emit zbc -o zpm.zbc && zsc0 bundle zpm.zbc -o zpm
sudo scripts/install.sh
```

## Status

Sprawdzone na prawdziwym `rpm`/`rpmbuild`: atrapa się buduje i instaluje do `--root`, pakiet z `Requires: systemd >= 254` oraz
`Requires: /usr/bin/systemctl` **nie instaluje się bez atrapy i instaluje się z nią**; instalacja jest idempotentna, usuwanie działa.
Nie sprawdzone: współpraca z prawdziwym zypper i repozytoriami Tumbleweed (blokady `addlock`, `--dry-run` parser opiera się na formacie
wyjścia zypper, pokrytym testem na przykładowym tekście). Dystrybucja zpm (skąd go pobrać) — do zaprojektowania.

Licencja: MPL-2.0.
