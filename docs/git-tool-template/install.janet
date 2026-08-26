#!/usr/bin/env janet
# Szablon install.janet -- konwencja zpm dla narzędzi typu "git" w
# custom/own-repository.json. Wołany PO pomyślnym build.janet, jako:
#
#   janet install.janet [install_args z own-repository.json...]
#
# w tym samym katalogu roboczym (korzeń repo). Zadaniem tego skryptu jest
# skopiowanie zbudowanych artefaktów tam, gdzie mają wylądować.
#
# KLUCZOWE: nigdy nie zakładaj instalacji wprost do "/". Zawsze instaluj
# względem ZPM_INSTALL_ROOT, żeby ten sam skrypt działał identycznie:
#  - na hoście                (ZPM_INSTALL_ROOT=/)
#  - przy budowaniu obrazu    (ZPM_INSTALL_ROOT=<rootfs obrazu>, zpm --root=...)
#
# Dostępne zmienne środowiskowe (ustawiane przez zpm):
#   ZPM_INSTALL_ROOT / ZPM_PREFIX -- korzeń instalacji (domyślnie "/")
#   ZPM_TOOL_NAME                 -- nazwa narzędzia z own-repository.json
#   ZPM_TOOL_REF                  -- checkoutowany branch/tag/commit
#
# Kod wyjścia 0 = sukces.

(defn sh [cmd]
  (print "$ " cmd)
  (def code (os/execute ["/bin/sh" "-c" cmd] :p))
  (when (not= code 0)
    (eprint "install.janet: polecenie nie powiodło się (kod " code "): " cmd)
    (os/exit code)))

(def root (or (os/getenv "ZPM_INSTALL_ROOT") "/"))
(def bindir (string root (if (string/has-suffix? "/" root) "" "/") "usr/local/bin"))

(print "==> instalacja " (or (os/getenv "ZPM_TOOL_NAME") "narzędzia") " do " bindir)

(sh (string "mkdir -p " bindir))
# Tu miejsce na rzeczywistą kopię artefaktu zbudowanego przez build.janet, np.:
# (sh (string "install -m755 bin/tool " bindir "/tool"))

(print "==> install OK (root=" root ")")
