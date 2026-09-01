#!/usr/bin/env janet

(def out-dir "bin")
(def src-file "src/zlb.nim")

(defn sh
  [cmd]
  (print "$ " cmd)
  (def code (os/execute ["/bin/sh" "-c" cmd] :p))
  (when (not= code 0)
    (eprint "build.janet: polecenie nie powiodło się (kod " code "): " cmd)
    (os/exit code)))

(defn ensure-out-dir [] (os/mkdir out-dir))

# NAPRAWIONE: `-d:ssl` usunięte z obu poniższych zadań. Historycznie zlb
# było budowane z `-d:ssl`, bo `zlbpkg/tools.nim` pobierało `zpm`/`installer`
# przez `std/httpclient`, które potrafi obsłużyć HTTPS TYLKO gdy binarka
# jest skompilowana z tą flagą -- inaczej w runtime leci "SSL support is
# not available. Cannot connect over SSL. Compile with -d:ssl to enable."
# (dokładnie ten błąd, na który trafiali użytkownicy bez OpenSSL na
# maszynie budującej). `tools.nim` NIE używa już `std/httpclient` -- wywołuje
# `curl`/`wget` jako podproces właśnie po to, żeby zlb nie musiało wymagać
# OpenSSL w ogóle. `-d:ssl` w tych zadaniach było więc martwym, niepotrzebnym
# wymaganiem: zostawione tutaj, dalej wymuszało (na niektórych systemach)
# obecność OpenSSL tylko po to, żeby zlinkować binarkę, która i tak go
# nigdy nie używa. Jeśli w przyszłości jakiś moduł zlb faktycznie zacznie
# używać `std/httpclient`, tę flagę trzeba będzie przywrócić.
(defn task-release []
  (ensure-out-dir)
  (sh (string "nim c -d:release --opt:speed --out:" out-dir "/zlb " src-file))
  (print "-> " out-dir "/zlb"))

(defn task-debug []
  (ensure-out-dir)
  (sh (string "nim c --out:" out-dir "/zlb-debug " src-file))
  (print "-> " out-dir "/zlb-debug"))

(defn task-check []
  (sh (string "nim check " src-file)))

(defn task-clean []
  (sh (string "rm -rf " out-dir " nimcache nimblecache")))

(defn detect-os []
  (case (os/which)
    :linux "linux"
    :macos "macos"
    :windows "windows"
    "unknown"))

(defn detect-arch []
  (def p (os/spawn ["uname" "-m"] :p {:out :pipe}))
  (def out (string/trim (:read (p :out) :all)))
  (os/proc-wait p)
  out)

(defn task-package [version]
  (task-release)
  (def osname (detect-os))
  (def arch (detect-arch))
  (def name (string out-dir "/zlb-" osname "-" arch))
  (sh (string "cp " out-dir "/zlb " name))
  (sh (string "sha256sum " name " > " out-dir "/SHA256SUMS-" version))
  (print "package " version " gotowy: " name))

(defn main [&opt task & args]
  (case task
    "release" (task-release)
    "debug" (task-debug)
    "check" (task-check)
    "clean" (task-clean)
    "package" (task-package (or (first args) "dev"))
    nil (task-release)
    (do
      (eprint "Nieznane zadanie: " task)
      (eprint "Użycie: janet build.janet <release|debug|check|clean|package [wersja]>")
      (os/exit 1))))

(let [all-args (or (dyn :args) @[])
      task (get all-args 1)
      rest-args (array/slice all-args 2)]
  (main task ;rest-args))
