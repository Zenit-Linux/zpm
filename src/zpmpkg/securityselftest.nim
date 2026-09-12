import std/[os, osproc, strformat, strutils, sequtils]
import ./types
import ./logging

## v0.3.2 -- `zpm security selftest`: domyka lukę "sandbox/podpisy/TLS
## pinning są zaimplementowane, ale nikt tego nie przetestował pod kątem
## realnych ataków". To NIE jest pełny audyt bezpieczeństwa (patrz
## zastrzeżenie w README) -- to automatyczny, powtarzalny test tego, co
## MOŻNA zweryfikować programowo bez ingerencji człowieka: czy `bwrap`
## faktycznie odcina sieć/zapis poza dozwolone katalogi TAK, jak
## `ownrepo.sandboxWrap` obiecuje. Zewnętrzny przegląd bezpieczeństwa
## (ludzki, przeciwny sobie) pozostaje rekomendowany -- to uzupełnia go,
## nie zastępuje.
##
## Filozofia: zamiast czytać kod `sandboxWrap` i wierzyć na słowo, że
## flagi `bwrap` robią to, co komentarz mówi -- URUCHOM DOKŁADNIE TĘ SAMĄ
## kompozycję flag i zaobserwuj REALNY efekt (czy atak się powiódł, czy
## nie), tak samo jak `containerengine.overlaySelfTest` robi to dla
## overlayfs zamiast wierzyć metadanym.

type
  CheckResult = object
    name: string
    ok: bool
    detail: string

proc runBwrap(cfg: ZpmConfig, extraFlags: openArray[string], innerCmd: string): tuple[ok: bool, output: string] =
  let sandboxBin = if cfg.sandboxCmd.len > 0: cfg.sandboxCmd else: "bwrap"
  var args = @["--die-with-parent", "--unshare-all",
               "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp"]
  for f in extraFlags: args.add f
  args.add "--"
  args.add "sh"
  args.add "-c"
  args.add innerCmd
  let (output, code) = execCmdEx(sandboxBin & " " & args.mapIt(it.quoteShell).join(" "))
  (code == 0, output)

proc checkBwrapAvailable(cfg: ZpmConfig): CheckResult =
  let sandboxBin = if cfg.sandboxCmd.len > 0: cfg.sandboxCmd else: "bwrap"
  if findExe(sandboxBin).len > 0:
    CheckResult(name: "bwrap w PATH", ok: true, detail: &"znaleziono '{sandboxBin}'")
  else:
    CheckResult(name: "bwrap w PATH", ok: false,
      detail: &"'{sandboxBin}' nie jest w PATH -- reszta testów pominięta (zainstaluj 'bubblewrap')")

proc checkNetworkIsolation(cfg: ZpmConfig): CheckResult =
  ## Bez `--share-net` (tak jak `sandboxWrap` dla narzędzi z allow_network=false)
  ## próba połączenia TCP powinna zawieść -- brak interfejsu sieciowego w
  ## nowej przestrzeni nazw sieciowej (`--unshare-all` obejmuje `--unshare-net`).
  let probe = "curl --connect-timeout 2 -s -o /dev/null -w '%{http_code}' http://1.1.1.1 2>&1 || echo UNREACHABLE"
  let (_, output) = runBwrap(cfg, [], probe)
  if "UNREACHABLE" in output or output.strip().len == 0 or "000" in output:
    CheckResult(name: "izolacja sieciowa (bez --share-net)", ok: true,
      detail: "połączenie TCP z wnętrza bwrap bez --share-net faktycznie zawiodło (sieć odcięta)")
  else:
    CheckResult(name: "izolacja sieciowa (bez --share-net)", ok: false,
      detail: &"połączenie TCP Z WNĘTRZA bwrap POWIODŁO SIĘ mimo braku --share-net " &
        &"(odpowiedź: '{output.strip()}') -- sieć NIE jest odcięta, to naruszenie obietnicy izolacji")

proc checkNetworkAllowedWhenRequested(cfg: ZpmConfig): CheckResult =
  ## Sanity check w drugą stronę: z `--share-net` (tak jak dla narzędzi z
  ## allow_network=true) połączenie POWINNO działać. Traktowane jako
  ## OSTRZEŻENIE, nie twardy fail, jeśli się nie uda -- host sam może nie
  ## mieć internetu (np. offline CI), co nie świadczy o błędzie bwrap.
  let probe = "curl --connect-timeout 2 -s -o /dev/null -w '%{http_code}' http://1.1.1.1 2>&1 || echo UNREACHABLE"
  let (_, output) = runBwrap(cfg, ["--share-net"], probe)
  if "200" in output or "301" in output or "302" in output:
    CheckResult(name: "sieć DOSTĘPNA z --share-net", ok: true, detail: "połączenie powiodło się (zgodnie z oczekiwaniem)")
  else:
    CheckResult(name: "sieć DOSTĘPNA z --share-net", ok: true,
      detail: &"połączenie nie powiodło się (host może być offline -- to NIE test bwrap, pomijam jako niekrytyczne; wynik: '{output.strip()}')")

proc checkFilesystemIsolation(cfg: ZpmConfig): CheckResult =
  ## `--ro-bind / /` -- zapis GDZIEKOLWIEK poza jawnie dodanym `--bind`
  ## powinien zawieść (system plików tylko do odczytu w tej przestrzeni
  ## nazw mount). Celujemy w katalog spoza jakiegokolwiek zpm --bind.
  let marker = &"/tmp/.zpm-selftest-should-fail-{getCurrentProcessId()}"
  # UWAGA: /tmp jest jawnie podmieniane na świeży --tmpfs (zapisywalny z
  # definicji) -- celowo testujemy zapis do /etc, które NIE jest tmpfs,
  # tylko częścią `--ro-bind / /`.
  let target = &"/etc/.zpm-selftest-should-fail-{getCurrentProcessId()}"
  let probe = &"echo x > {target} 2>&1 && echo WROTE || echo BLOCKED"
  let (_, output) = runBwrap(cfg, [], probe)
  discard marker
  if "BLOCKED" in output:
    CheckResult(name: "izolacja zapisu (--ro-bind / /)", ok: true,
      detail: "zapis do /etc (poza jawnym --bind) faktycznie zablokowany")
  else:
    CheckResult(name: "izolacja zapisu (--ro-bind / /)", ok: false,
      detail: &"zapis do /etc Z WNĘTRZA bwrap POWIÓDŁ SIĘ ('{output.strip()}') -- rootfs NIE jest " &
        "faktycznie tylko-do-odczytu, to naruszenie obietnicy izolacji")

proc checkWritableBindWorks(cfg: ZpmConfig, workDir: string): CheckResult =
  ## Dopełnienie powyższego: katalog jawnie dodany przez --bind MUSI
  ## pozostać zapisywalny -- inaczej sam Tryb Atomowy/`own install` by nie
  ## działał (to nie byłby test bezpieczeństwa, tylko fałszywy alarm).
  createDir(workDir)
  let target = workDir / &".zpm-selftest-should-succeed-{getCurrentProcessId()}"
  let probe = &"echo x > {target} 2>&1 && echo WROTE || echo BLOCKED"
  let (_, output) = runBwrap(cfg, ["--bind", workDir, workDir], probe)
  try:
    if fileExists(target): removeFile(target)
  except CatchableError: discard
  if "WROTE" in output:
    CheckResult(name: "zapisywalność jawnego --bind", ok: true, detail: "zapis do katalogu z --bind zadziałał (zgodnie z oczekiwaniem)")
  else:
    CheckResult(name: "zapisywalność jawnego --bind", ok: false,
      detail: &"zapis do katalogu PODANEGO przez --bind nie powiódł się ('{output.strip()}') -- " &
        "prawdopodobnie build/install narzędzi 'own' przestałby działać")

proc securitySelfTest*(cfg: ZpmConfig): tuple[ok: bool, results: seq[CheckResult]] =
  var results: seq[CheckResult] = @[]
  let avail = checkBwrapAvailable(cfg)
  results.add avail
  if not avail.ok:
    return (false, results)

  results.add checkNetworkIsolation(cfg)
  results.add checkNetworkAllowedWhenRequested(cfg)
  results.add checkFilesystemIsolation(cfg)
  results.add checkWritableBindWorks(cfg, getTempDir() / "zpm-security-selftest")

  # Tylko testy WYRAŹNIE oznaczone jako krytyczne (izolacja sieci/fs)
  # decydują o ogólnym wyniku -- sanity-check "sieć dostępna z --share-net"
  # jest zawsze `ok: true` (patrz komentarz w funkcji), więc nie zaniża
  # wyniku przez brak internetu na hoście.
  let allOk = results.allIt(it.ok)
  (allOk, results)

proc runSecuritySelfTestCli*(cfg: ZpmConfig) =
  log("[zpm:security] Uruchamiam selftest izolacji bwrap (patrz `security { sandbox_enabled }`)...")
  log("[zpm:security] UWAGA: to automatyczny test WYBRANYCH właściwości, nie pełny audyt bezpieczeństwa " &
      "-- zewnętrzny przegląd pozostaje rekomendowany.")
  let (ok, results) = securitySelfTest(cfg)
  for r in results:
    let mark = if r.ok: "✔" else: "✘"
    log(&"  {mark} {r.name}: {r.detail}")
  if ok:
    log("[zpm:security] ✔ Wszystkie krytyczne testy przeszły.")
  else:
    stderr.writeLine("[zpm:security] ✘ Co najmniej jeden krytyczny test NIE przeszedł -- patrz linie ✘ powyżej.")
    quit(1)
