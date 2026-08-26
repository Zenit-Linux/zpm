set -l zpm_commands install remove update upgrade sync refresh list doctor own lock pack init atomic
set -l own_subcommands list info build install remove refresh build-stage install-stage verify-reproducible
set -l backends apt dnf pacman zypper brew flatpak snap cargo npm pip own

complete -c zpm -f

# Główne komendy (tylko gdy nic jeszcze nie podano)
complete -c zpm -n "not __fish_seen_subcommand_from $zpm_commands" -a "$zpm_commands"

# Podkomendy `own`
complete -c zpm -n "__fish_seen_subcommand_from own" -n "not __fish_seen_subcommand_from $own_subcommands" -a "$own_subcommands"

# Podkomendy `atomic`
complete -c zpm -n "__fish_seen_subcommand_from atomic" -a "create install enter list destroy"

# Flagi globalne
complete -c zpm -s y -l yes -d "nie pytaj, wybierz najlepszego kandydata"
complete -c zpm -s c -l config -d "użyj innego pliku konfiguracyjnego" -r
complete -c zpm -l user-db -d "użyj lokalnej bazy \$HOME/.local/share/zpm/zpm.db"
complete -c zpm -l trust-keys -d "(z init) zaufaj zestawowi kluczy repo z pliku" -r
complete -c zpm -l offline -d "nie dotykaj sieci"
complete -c zpm -l target-arch -d "architektura docelowa (cross-compilation)"
complete -c zpm -l json -d "strukturalne wyjście JSON"
complete -c zpm -l verbose -d "więcej szczegółów diagnostycznych"
complete -c zpm -s q -l quiet -d "tylko błędy/wynik końcowy"
complete -c zpm -s f -l force -d "pomiń idempotencję / reverse-dependency check"
complete -c zpm -l fix -d "(z doctor) napraw automatycznie to, co bezpieczne"
complete -c zpm -l root -d "tryb budowania obrazów: ścieżka rootfs" -r
complete -c zpm -l backend -d "wymuś konkretny backend" -xa "$backends"
complete -c zpm -s h -l help -d "pokaż pomoc"
complete -c zpm -s v -l version -d "pokaż wersję"
