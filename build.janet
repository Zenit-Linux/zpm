#!/usr/bin/env janet

(def out-dir "bin")
(def src-file "src/zpm.nim")

(defn sh
  "Uruchamia polecenie powłoki, wypisuje je najpierw, i wychodzi z błędem
  jeśli zwróci kod różny od zera."
  [cmd]
  (print "$ " cmd)
  (def code (os/execute ["/bin/sh" "-c" cmd] :p))
  (when (not= code 0)
    (eprint "build.janet: polecenie nie powiodło się (kod " code "): " cmd)
    (os/exit code)))

(defn ensure-out-dir [] (os/mkdir out-dir))

(defn task-standard []
  (ensure-out-dir)
  (sh (string "nim c --threads:on -d:release -d:ssl --opt:speed --out:" out-dir "/zpm " src-file))
  (print "-> " out-dir "/zpm (tryb standardowy)"))

(defn task-atomic []
  (ensure-out-dir)
  (sh (string "nim c -d:release -d:ssl -d:atomic --opt:speed --out:" out-dir "/zpm-atomic " src-file))
  (print "-> " out-dir "/zpm-atomic (tryb atomowy)"))

(defn task-debug []
  (ensure-out-dir)
  (sh (string "nim c --threads:on -d:ssl --out:" out-dir "/zpm-debug " src-file))
  (print "-> " out-dir "/zpm-debug (debug)"))

(defn task-check []
  (sh (string "nim check --threads:on " src-file)))

(defn task-all []
  (task-standard)
  (task-atomic))

(defn task-clean []
  (sh (string "rm -rf " out-dir " nimcache nimblecache")))

(defn detect-os []
  (case (os/which)
    :linux "linux"
    :macos "macos"
    :windows "windows"
    "unknown"))

(defn detect-arch []
  # os/arch nie istnieje w rdzennym Janecie -- opieramy się na `uname -m`,
  # spójnie z tym, jak zlbpkg/crosscompile.nim w zlb rozpoznaje architekturę.
  (def p (os/spawn ["uname" "-m"] :p {:out :pipe}))
  (def out (string/trim (:read (p :out) :all)))
  (os/proc-wait p)
  out)

(defn task-release [version]
  (task-all)
  (def osname (detect-os))
  (def arch (detect-arch))
  (def std-name (string out-dir "/zpm-" osname "-" arch))
  (def atomic-name (string out-dir "/zpm-atomic-" osname "-" arch))
  (sh (string "cp " out-dir "/zpm " std-name))
  (sh (string "cp " out-dir "/zpm-atomic " atomic-name))
  (sh (string "sha256sum " std-name " " atomic-name " > " out-dir "/SHA256SUMS-" version))
  (print "release " version " gotowy w " out-dir "/ (" std-name ", " atomic-name ")"))

(defn main [&opt task & args]
  (case task
    "standard" (task-standard)
    "atomic" (task-atomic)
    "debug" (task-debug)
    "check" (task-check)
    "all" (task-all)
    "clean" (task-clean)
    "release" (task-release (or (first args) "dev"))
    nil (task-all)
    (do
      (eprint "Nieznane zadanie: " task)
      (eprint "Użycie: janet build.janet <standard|atomic|debug|check|all|clean|release [wersja]>")
      (os/exit 1))))

# `janet build.janet <task> [args...]` -- (dyn :args) to [skrypt task args...]
(let [all-args (or (dyn :args) @[])
      task (get all-args 1)
      rest-args (array/slice all-args 2)]
  (main task ;rest-args))
