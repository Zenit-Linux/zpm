import std/[strformat, times, os, json, strutils]
import ./types

## v0.3.2 -- dokłada DRUGI, niezależny kanał logów: NDJSON zapisywany do
## pliku (logging.structured_log_path / --log-file / $ZPM_LOG_FILE), obok
## istniejącego stdout/stderr opisanego niżej. Cel: dziś jedyny sposób
## zdebugowania "co się DOKŁADNIE działo" w buildzie CI to grepowanie
## ludzkiego tekstu z `--verbose` na stdout -- niestrukturyzowanego, bez
## znaczników czasu, bez rozróżnienia, KTÓRY moduł coś zalogował. Ten kanał
## jest zawsze "dopisujący" (append), nie honoruje --quiet/--json (bo służy
## do analizy PO fakcie, nie do bieżącego UX), i nie zastępuje istniejącego
## stdout/stderr -- włącza się wyłącznie, gdy ścieżka jest ustawiona.

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
var gStructuredLogPath*: string = ""

proc setLogVerbosity*(cfg: ZpmConfig) =
  gVerbosity = cfg.verbosity
  gJsonMode = cfg.jsonOutput
  gStructuredLogPath = cfg.structuredLogPath

proc setLogVerbosity*(verbosity: int, jsonMode: bool = false) =
  gVerbosity = verbosity
  gJsonMode = jsonMode

proc setStructuredLogPath*(path: string) =
  ## Wołane z zpm.nim PO setLogVerbosity(cfg), żeby --log-file/$ZPM_LOG_FILE
  ## runtime mogło nadpisać (albo dopiero WŁĄCZYĆ) to, co jest w configu.
  gStructuredLogPath = path

proc writeStructured(level, msg: string) =
  ## Dopisuje jeden wiersz NDJSON: {"ts": ISO8601, "level", "component", "msg"}.
  ## `component` to prefiks w nawiasach kwadratowych, jeśli `msg` go ma
  ## (konwencja całego kodu, np. "[zpm:atomic] ..."), inaczej "zpm".
  if gStructuredLogPath.len == 0: return
  var component = "zpm"
  var text = msg
  if msg.len > 0 and msg[0] == '[':
    let closeIdx = msg.find(']')
    if closeIdx > 0:
      component = msg[1 ..< closeIdx]
      text = msg[closeIdx + 1 .. ^1].strip()
  let line = %*{
    "ts": now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "level": level,
    "component": component,
    "msg": text
  }
  try:
    let parent = parentDir(gStructuredLogPath)
    if parent.len > 0: createDir(parent)
    let f = open(gStructuredLogPath, fmAppend)
    defer: f.close()
    f.writeLine($line)
  except CatchableError:
    discard  # nigdy nie wywalaj reszty programu z powodu logu diagnostycznego

proc log*(msg: string) =
  ## Zwykła linia informacyjna ("postęp") -- ukryta pod --quiet i --json.
  writeStructured("info", msg)
  if gJsonMode: return
  if gVerbosity < 0: return
  echo msg

proc logVerbose*(msg: string) =
  ## Szczegóły diagnostyczne -- widoczne TYLKO pod --verbose, nigdy w --json.
  writeStructured("debug", msg)
  if gJsonMode: return
  if gVerbosity < 1: return
  echo msg

proc logWarn*(msg: string) =
  ## Ostrzeżenie -- widoczne zawsze poza --json (nawet pod --quiet:
  ## ostrzeżenia o degradacji bezpieczeństwa/best-effort nie powinny dać
  ## się wyciszyć przypadkiem razem z "postępem").
  writeStructured("warn", msg)
  if gJsonMode: return
  stderr.writeLine(msg)

proc logErr*(msg: string) =
  ## Błąd -- zawsze widoczny, nawet w --json (na stderr, więc nie miesza
  ## się z JSON-em na stdout).
  writeStructured("error", msg)
  stderr.writeLine(msg)

proc logAlways*(msg: string) =
  ## Wynik, który MUSI się pojawić niezależnie od trybu (np. sama treść
  ## `--json`) -- wołający sam decyduje, kiedy to wywołać.
  writeStructured("info", msg)
  echo msg

when isMainModule:
  setLogVerbosity(1, false)
  log("info")
  logVerbose(&"verbose {1+1}")
  logWarn("warn")
