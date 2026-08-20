version       = "0.1.0-proto"
author        = "Zenith Linux Project"
description   = "Zenith Package Manager (zpm) — inteligentny orkiestrator pakietów dla Zenith Linux"
license       = "MIT"
srcDir        = "src"
bin           = @["zpm"]
binDir        = "bin"

requires "nim >= 1.6.0"

# --- Zadania pomocnicze -----------------------------------------------

task standard, "Buduje zpm w trybie STANDARDOWYM (orkiestrator hosta)":
  exec "nim c -d:release --out:bin/zpm src/zpm.nim"

task atomic, "Buduje zpm w trybie ATOMOWYM (strażnik kontenerów/obrazów)":
  exec "nim c -d:release -d:atomic --out:bin/zpm-atomic src/zpm.nim"

task debugBuild, "Buduje wersję debug (standardowa) z pełnymi asercjami":
  exec "nim c --out:bin/zpm-debug src/zpm.nim"
