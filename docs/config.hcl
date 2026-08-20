core {
  db_path                 = "/var/lib/zpm/zpm.db"
  parallel_updates        = true
  confirm_before_install  = true
}

backends {
  // Kolejność ma znaczenie tylko przy remisach (kilka backendów ma ten sam pakiet)
  enabled = ["flatpak", "apt", "dnf", "pacman", "zypper", "snap", "cargo", "pip", "npm"]

  preferred_order = ["flatpak", "apt", "dnf", "pacman", "zypper", "snap", "cargo", "pip", "npm"]
}

// Ustawienia aktywne wyłącznie w binarce skompilowanej z -d:atomic
atomic {
  store_path = "/var/lib/zpm/atomic"
}

// Ustawienia aktywne przy uruchomieniu z flagą --building
building {
  cache_dir = "/var/cache/zpm/building"
}
