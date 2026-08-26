_zpm_complete() {
  local cur prev words cword
  _init_completion || return

  local commands="install remove update upgrade sync refresh list doctor own lock pack init atomic"
  local own_subcommands="list info build install remove refresh build-stage install-stage verify-reproducible"
  local global_flags="-y --yes -c --config --user-db --trust-keys --offline --target-arch --json --verbose -q --quiet -f --force --fix -h --help -v --version --root --backend --building"
  local backends="apt dnf pacman zypper brew flatpak snap cargo npm pip own"

  case "${prev}" in
    zpm)
      COMPREPLY=($(compgen -W "${commands} ${global_flags}" -- "${cur}"))
      return
      ;;
    own)
      COMPREPLY=($(compgen -W "${own_subcommands}" -- "${cur}"))
      return
      ;;
    --backend|-\>|@)
      COMPREPLY=($(compgen -W "${backends}" -- "${cur}"))
      return
      ;;
    --config|-c|--trust-keys|--root)
      _filedir
      return
      ;;
  esac

  # zpm install <TAB> -- brak sensownej listy statycznej (zależy od
  # backendów hosta), więc podpowiadamy tylko flagi, żeby nie sugerować
  # niepoprawnych nazw pakietów.
  if [[ "${cur}" == -* ]]; then
    COMPREPLY=($(compgen -W "${global_flags}" -- "${cur}"))
    return
  fi

  case "${words[1]}" in
    remove|list)
      COMPREPLY=($(compgen -W "$(zpm list --json 2>/dev/null | grep -o '"name":"[^"]*"' | cut -d'"' -f4)" -- "${cur}"))
      ;;
    own)
      if [[ "${words[2]}" =~ ^(install|remove|build|info)$ ]]; then
        COMPREPLY=($(compgen -W "$(zpm own list --json 2>/dev/null | grep -o '"name":"[^"]*"' | cut -d'"' -f4)" -- "${cur}"))
      fi
      ;;
  esac
}

complete -F _zpm_complete zpm
