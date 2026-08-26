#!/usr/bin/env janet
# Szablon build.janet -- konwencja zpm dla narzędzi typu "git" w
# custom/own-repository.json. zpm woła ten skrypt jako:
#
#   janet build.janet [build_args z own-repository.json...]
#
# w katalogu roboczym = korzeń zklonowanego repozytorium (po checkoucie
# `ref`). Zadaniem tego skryptu jest wyłącznie ZBUDOWANIE ze źródeł --
# NIC nie instalować w systemie (tym zajmuje się install.janet).
#
# Dostępne zmienne środowiskowe (ustawiane przez zpm):
#   ZPM_TOOL_NAME -- nazwa narzędzia z own-repository.json
#   ZPM_TOOL_REF  -- checkoutowany branch/tag/commit
#
# Kod wyjścia 0 = sukces, cokolwiek innego = zpm przerywa i NIE
# uruchamia install.janet.

(defn sh [cmd]
  (print "$ " cmd)
  (def code (os/execute ["/bin/sh" "-c" cmd] :p))
  (when (not= code 0)
    (eprint "build.janet: polecenie nie powiodło się (kod " code "): " cmd)
    (os/exit code)))

(print "==> budowanie " (or (os/getenv "ZPM_TOOL_NAME") "narzędzia")
       " (ref=" (or (os/getenv "ZPM_TOOL_REF") "?") ")")

# Tu miejsce na rzeczywiste kroki budowania, np.:
# (sh "make -j$(nproc)")
# albo (dla projektów w Nim): (sh "nim c -d:release --out:bin/tool src/tool.nim")

(print "==> build OK")
