version       = "0.1.0-proto"
author        = "Zenit Linux Developers"
description   = "Zenit Package Manager (zpm) — inteligentny orkiestrator pakietów dla Zenit Linux"
license       = "Apache-2.0"
srcDir        = "src"
bin           = @["zpm"]
binDir        = "bin"

requires "nim >= 1.6.0"
requires "db_connector >= 0.1.0"

# --- Zadania pomocnicze -----------------------------------------------
# Preferowanym sposobem budowania jest teraz `janet build.janet <task>`
# (patrz build.janet) -- te taski nimble zostają jako cienka warstwa
# zgodności / do użycia bez janeta zainstalowanego na hoście.

task standard, "Buduje zpm w trybie STANDARDOWYM (orkiestrator hosta)":
  exec "nim c --threads:on -d:release -d:ssl --out:bin/zpm src/zpm.nim"

task atomic, "Buduje zpm w trybie ATOMOWYM (strażnik kontenerów/obrazów)":
  exec "nim c -d:release -d:ssl -d:atomic --out:bin/zpm-atomic src/zpm.nim"

task debugBuild, "Buduje wersję debug (standardowa) z pełnymi asercjami":
  exec "nim c --threads:on -d:ssl --out:bin/zpm-debug src/zpm.nim"
