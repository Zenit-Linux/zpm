import std/[strformat]
import ./types

## Scentralizowane logowanie -- v0.2.
##
## PRZED: `cfg.verbosity`/`cfg.jsonOutput` były przyjmowane z linii poleceń,
## ale honorowane tylko przez GARSTKĘ komend (`list --json`, `own list/info
## --json`) -- reszta modułów (ownrepo.nim, building.nim, orchestrator.nim
## przy `search`/`own build-stage` itd.) pisała wprost przez gołe `echo`,
## bez sprawdzania poziomu. Efekt: `--quiet` nie wyciszał `zpm own install`,
## a `--verbose` nic nie dokładał.
##
## PO: trzy poziomy (log*Verbose/log/logWarn/logErr), każdy sprawdza
## GLOBALNY poziom ustawiony raz w `zpm.nim` (`setLogVerbosity`) --
## moduły wywołujące `logLine`/`logWarn` nie muszą już same nosić ze sobą
## `cfg` tylko po to, żeby zdecydować, czy coś wypisać. `--json` dodatkowo
## wycisza WSZYSTKIE linie tekstowe typu "postęp" (nie tylko `--quiet`) na
## strumieniu stdout, bo mieszanie ludzkiego tekstu z maszynowym JSON-em na
## tym samym stdout psuje parsowanie (dokładnie problem, na który trafiał
## `zlb`, próbując sparsować teksowy `zpm own list`).
##
## Reguła poziomów (zgodna z tym, co już opisywał --help):
##   verbosity == -1 (--quiet)   -> tylko logErr (i logAlways)
##   verbosity ==  0 (domyślnie) -> logErr + log (informacje "z życia")
##   verbosity ==  1 (--verbose) -> + logVerbose (szczegóły diagnostyczne)
## `--json` wycisza WSZYSTKO poza logErr/logAlways (bo w trybie JSON jedyny
## poprawny tekst na stdout to sam JSON, wypisywany osobno przez wołającego).

var gVerbosity*: int = 0
var gJsonMode*: bool = false

proc setLogVerbosity*(cfg: ZpmConfig) =
  gVerbosity = cfg.verbosity
  gJsonMode = cfg.jsonOutput

proc setLogVerbosity*(verbosity: int, jsonMode: bool = false) =
  gVerbosity = verbosity
  gJsonMode = jsonMode

proc log*(msg: string) =
  ## Zwykła linia informacyjna ("postęp") -- ukryta pod --quiet i --json.
  if gJsonMode: return
  if gVerbosity < 0: return
  echo msg

proc logVerbose*(msg: string) =
  ## Szczegóły diagnostyczne -- widoczne TYLKO pod --verbose, nigdy w --json.
  if gJsonMode: return
  if gVerbosity < 1: return
  echo msg

proc logWarn*(msg: string) =
  ## Ostrzeżenie -- widoczne zawsze poza --json (nawet pod --quiet:
  ## ostrzeżenia o degradacji bezpieczeństwa/best-effort nie powinny dać
  ## się wyciszyć przypadkiem razem z "postępem").
  if gJsonMode: return
  stderr.writeLine(msg)

proc logErr*(msg: string) =
  ## Błąd -- zawsze widoczny, nawet w --json (na stderr, więc nie miesza
  ## się z JSON-em na stdout).
  stderr.writeLine(msg)

proc logAlways*(msg: string) =
  ## Wynik, który MUSI się pojawić niezależnie od trybu (np. sama treść
  ## `--json`) -- wołający sam decyduje, kiedy to wywołać.
  echo msg

when isMainModule:
  setLogVerbosity(1, false)
  log("info")
  logVerbose(&"verbose {1+1}")
  logWarn("warn")
