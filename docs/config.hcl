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

// Własny ekosystem Zenith Linux -- narzędzia (zlb, installer, i inne)
// dystrybuowane jako pojedyncze binarki spod dosłownych URL-i, zamiast
// przez `curl ... | sh`. Backend `own` szuka tu kandydatów.
custom {
  repository_path = "/etc/zpm/custom/own-repository.json"
  install_dir      = "/usr/local/bin"
}
