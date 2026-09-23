import std/[os, json, times, strutils, strformat, httpclient]
when defined(posix):
  import std/[termios, posix]
import ./logging

## v0.5 -- `zpm login`/`zpm logout`: token GitHub dla ZWYKŁYCH, INTERAKTYWNYCH
## użytkowników zpm (w odróżnieniu od GITHUB_TOKEN/GH_TOKEN ze środowiska,
## który jest dla CI -- patrz netutil.nim, `githubAuthHeaderIfApplicable` i
## `currentGithubToken` niżej, które łączą OBIE ścieżki w jedno miejsce).
##
## Motywacja: `api.github.com` ogranicza niezalogowane zapytania do 60/h NA
## ADRES IP (patrz `fetchLatestGithubRelease` w ownrepo.nim -- backend "own"
## bez przypiętej wersji odpytuje ten endpoint za każdym razem, gdy zpm nie
## wie jeszcze, co to jest "najnowsza wersja"). Jeśli tego narzędzia ma
## używać codziennie mnóstwo ludzi z tego samego biura/uczelni/dostawcy
## internetu (współdzielony adres IP wychodzący na świat), 60/h na WSZYSTKICH
## naraz wyczerpie się natychmiast. `zpm login` daje każdemu WŁASny,
## zapamiętany token, więc limit (min. 1000/h) liczy się per-token, nie
## per-IP.
##
## Token jest trzymany w `~/.config/zpm/auth.json` (uprawnienia 0600 --
## wyłącznie właściciel), NIGDY w zpm.hcl/logach/output JSON. Przy każdym
## użyciu (`currentGithubToken`) sprawdzamy `expires_at`, jeśli GitHub go
## podał przy logowaniu (fine-grained PAT / OAuth token z wygaśnięciem) --
## po przekroczeniu tej daty token jest AUTOMATYCZNIE kasowany z dysku i
## traktowany jako "brak" (bez żadnej akcji użytkownika), więc zpm nigdy nie
## próbuje uderzyć w API z tokenem, o którym wie, że jest już martwy.
## Klasyczne PAT-y bez wygaśnięcia (GitHub ich teraz odradza, ale nadal
## działają) po prostu nie mają `expires_at` -- trzymane bezterminowo, aż do
## ręcznego `zpm logout`.

type
  StoredAuth = object
    token*: string
    login*: string      ## nazwa użytkownika GitHub, jeśli udało się ustalić (patrz cmdLogin)
    createdAt*: string  ## kiedy `zpm login` zapisało ten token (ISO8601 UTC)
    expiresAt*: string  ## "" = bez wygaśnięcia (klasyczny PAT). W przeciwnym
                         ## razie ISO8601 UTC z nagłówka odpowiedzi GitHuba
                         ## `github-authentication-token-expiration`.

proc authDir(): string = getConfigDir() / "zpm"
proc authFilePath*(): string = authDir() / "auth.json"

proc saveAuth(a: StoredAuth) =
  createDir(authDir())
  let path = authFilePath()
  let j = %*{
    "token": a.token,
    "login": a.login,
    "created_at": a.createdAt,
    "expires_at": a.expiresAt,
  }
  writeFile(path, pretty(j) & "\n")
  try:
    setFilePermissions(path, {fpUserRead, fpUserWrite})
  except CatchableError as e:
    logWarn(&"[zpm login] ostrzeżenie: nie udało się ustawić uprawnień 0600 na {path}: {e.msg} " &
      "-- plik zawiera sekret, rozważ ręczne `chmod 600 {path}`")

proc loadAuth(): StoredAuth =
  let path = authFilePath()
  if not fileExists(path):
    return StoredAuth()
  try:
    let j = parseJson(readFile(path))
    StoredAuth(
      token: j{"token"}.getStr(""),
      login: j{"login"}.getStr(""),
      createdAt: j{"created_at"}.getStr(""),
      expiresAt: j{"expires_at"}.getStr(""),
    )
  except CatchableError:
    StoredAuth()

proc clearAuth*() =
  let path = authFilePath()
  if fileExists(path):
    removeFile(path)

proc parseGithubTimestamp(s: string): DateTime =
  ## GitHub zwraca wygaśnięcie tokenu w formacie "2026-12-31 23:59:59 UTC"
  ## (nagłówek github-authentication-token-expiration), a `zpm login` sam
  ## zapisuje `created_at` w ISO8601 ("yyyy-MM-dd'T'HH:mm:ss'Z'") -- ta
  ## funkcja rozumie oba, żeby `isExpired` działało niezależnie od tego,
  ## który z nich akurat parsuje.
  let t = s.strip()
  try:
    return parse(t, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
  except CatchableError:
    discard
  parse(t, "yyyy-MM-dd HH:mm:ss 'UTC'", utc())

proc isExpired(a: StoredAuth): bool =
  if a.expiresAt.len == 0:
    return false  ## klasyczny PAT bez wygaśnięcia -- trzymamy bezterminowo
  try:
    let exp = parseGithubTimestamp(a.expiresAt)
    return now().utc >= exp
  except CatchableError:
    ## Nie umiemy sparsować -- bezpieczniej NIE ufać nieznanej dacie i
    ## traktować token jako wciąż ważny (zamiast co chwilę go kasować);
    ## prawdziwe API i tak odrzuci token realnie wygasły (401), a
    ## `githubAuthHeaderIfApplicable` w netutil.nim i tak nigdy nie
    ## traktuje 401 jako coś innego niż zwykły błąd requestu.
    false

proc currentGithubToken*(): string =
  ## Jedno miejsce prawdy używane przez netutil.nim: env (CI, GITHUB_TOKEN/
  ## GH_TOKEN) ma PIERWSZEŃSTWO -- jest krótkotrwały i i tak ograniczony do
  ## joba, nie ma potrzeby nic z nim "pamiętać". W przeciwnym razie sięgamy
  ## do zapamiętanego przez `zpm login` tokenu z dysku, o ile nie wygasł
  ## (jeśli wygasł -- kasujemy go W TEJ SAMEJ chwili, więc kolejne wywołanie
  ## już nawet nie musi tego sprawdzać).
  let envToken = getEnv("GITHUB_TOKEN", getEnv("GH_TOKEN", ""))
  if envToken.len > 0:
    return envToken
  let a = loadAuth()
  if a.token.len == 0:
    return ""
  if isExpired(a):
    logVerbose("[zpm] zapisany token GitHub (zpm login) wygasł -- zapominam go, uruchom 'zpm login' ponownie")
    clearAuth()
    return ""
  a.token

proc verifyTokenWithGithub(token: string): tuple[ok: bool, login, expiresAt, err: string] =
  ## Waliduje token PRZED zapisaniem go na dysk -- `zpm login` nigdy nie
  ## zapisuje tokenu, którego GitHub od razu odrzuca. Próbujemy najpierw
  ## /user (daje nam ładną nazwę do wyświetlenia), a jeśli token ma zbyt
  ## wąski zakres uprawnień (fine-grained PAT bez dostępu do profilu) --
  ## spadamy na /rate_limit, który działa z KAŻDYM poprawnym tokenem, bez
  ## wymogu żadnego konkretnego scope'a.
  var client = newHttpClient(timeout = 15_000)
  defer: client.close()
  client.headers = newHttpHeaders({
    "User-Agent": "zpm/0.2",
    "Authorization": &"Bearer {token}",
  })

  proc expirationHeader(resp: Response): string =
    for name in ["github-authentication-token-expiration", "GitHub-Authentication-Token-Expiration"]:
      let v = resp.headers.getOrDefault(name)
      if v.len > 0: return v
    ""

  try:
    let resp = client.get("https://api.github.com/user")
    if resp.code == Http200:
      let login = (try: parseJson(resp.body){"login"}.getStr("") except CatchableError: "")
      return (true, login, expirationHeader(resp), "")
    if resp.code == Http401:
      return (false, "", "", "GitHub odrzucił token (401 -- nieprawidłowy albo już wygasły)")
    # inny kod (np. 403 -- token bez scope'a do /user): spróbuj /rate_limit
  except CatchableError as e:
    return (false, "", "", &"nie udało się połączyć z api.github.com: {e.msg}")

  try:
    let resp2 = client.get("https://api.github.com/rate_limit")
    if resp2.code == Http200:
      return (true, "", expirationHeader(resp2), "")
    if resp2.code == Http401:
      return (false, "", "", "GitHub odrzucił token (401 -- nieprawidłowy albo już wygasły)")
    (false, "", "", &"GitHub API zwróciło nieoczekiwany kod: {resp2.code}")
  except CatchableError as e:
    (false, "", "", &"nie udało się połączyć z api.github.com: {e.msg}")

proc readTokenHidden(): string =
  ## Czyta token z terminala BEZ echo (jak `ssh-keygen`/`sudo`), żeby nie
  ## zostawał widoczny na ekranie ani w historii scrollbacka. Jeśli stdin
  ## nie jest terminalem (np. potokowane w skrypcie/CI) albo cokolwiek się
  ## nie uda -- bezpiecznie spada na zwykłe, widoczne `readLine`, zamiast
  ## się wywalić.
  when defined(posix):
    var oldT, newT: Termios
    if isatty(cint(0)) != 0 and tcGetAttr(cint(0), addr oldT) == 0:
      newT = oldT
      newT.c_lflag = newT.c_lflag and not Cflag(ECHO)
      discard tcSetAttr(cint(0), TCSANOW, addr newT)
      try:
        result = readLine(stdin).strip()
      finally:
        discard tcSetAttr(cint(0), TCSANOW, addr oldT)
        stdout.write("\n")
      return
  result = readLine(stdin).strip()

const ZenitOAuthClientId* = ""
  ## v0.7 -- `zpm login --device` (OAuth Device Flow, jak `gh auth login`):
  ## zamiast wklejać token ręcznie, użytkownik dostaje krótki kod + link,
  ## klika w przeglądarce, zpm sam odbiera token w tle. WYMAGA
  ## zarejestrowanej OAuth App (albo GitHub App z włączonym Device Flow)
  ## po stronie Zenit-Linux -- to jednorazowa czynność na github.com/
  ## settings/developers, której NIE da się zrobić z poziomu samego kodu.
  ## Dopóki ta stała jest pusta, `zpm login --device` jasno o tym
  ## informuje i podpowiada zwykłe `zpm login --token=...`.

type DeviceCodeResp = object
  deviceCode, userCode, verificationUri: string
  expiresIn, interval: int

proc requestDeviceCode(clientId: string): DeviceCodeResp =
  var client = newHttpClient(timeout = 15_000)
  defer: client.close()
  client.headers = newHttpHeaders({"Accept": "application/json", "User-Agent": "zpm/0.2"})
  let body = &"client_id={clientId}&scope="
  let resp = client.postContent("https://github.com/login/device/code", body = body)
  let j = parseJson(resp)
  DeviceCodeResp(
    deviceCode: j{"device_code"}.getStr(""),
    userCode: j{"user_code"}.getStr(""),
    verificationUri: j{"verification_uri"}.getStr("https://github.com/login/device"),
    expiresIn: j{"expires_in"}.getInt(900),
    interval: j{"interval"}.getInt(5),
  )

proc pollForAccessToken(clientId, deviceCode: string, intervalSec, expiresIn: int): tuple[ok: bool, token, err: string] =
  var client = newHttpClient(timeout = 15_000)
  defer: client.close()
  client.headers = newHttpHeaders({"Accept": "application/json", "User-Agent": "zpm/0.2"})
  var waited = 0
  var interval = intervalSec
  while waited < expiresIn:
    sleep(interval * 1000)
    waited += interval
    let body = &"client_id={clientId}&device_code={deviceCode}&grant_type=urn:ietf:params:oauth:grant-type:device_code"
    try:
      let resp = client.postContent("https://github.com/login/oauth/access_token", body = body)
      let j = parseJson(resp)
      if j.hasKey("access_token"):
        return (true, j["access_token"].getStr(""), "")
      let errCode = j{"error"}.getStr("")
      case errCode
      of "authorization_pending":
        continue  # użytkownik jeszcze nie kliknął -- pytamy dalej
      of "slow_down":
        interval += 5
        continue
      of "expired_token":
        return (false, "", "kod wygasł, zanim zdążyłeś autoryzować -- uruchom 'zpm login --device' ponownie")
      of "access_denied":
        return (false, "", "odmówiono autoryzacji w przeglądarce")
      else:
        return (false, "", &"GitHub zwrócił błąd: {errCode}")
    except CatchableError as e:
      return (false, "", &"nie udało się połączyć z github.com: {e.msg}")
  (false, "", "przekroczono czas oczekiwania na autoryzację")

proc cmdLoginDevice*() =
  ## `zpm login --device` -- patrz komentarz przy ZenitOAuthClientId.
  if ZenitOAuthClientId.len == 0:
    stderr.writeLine("[zpm login --device] ✘ logowanie przez przeglądarkę (OAuth Device Flow) nie jest jeszcze")
    stderr.writeLine("  skonfigurowane w tej kompilacji zpm -- wymaga zarejestrowanej OAuth App po stronie")
    stderr.writeLine("  Zenit-Linux (github.com/settings/developers) i wpisania jej client_id do kodu")
    stderr.writeLine("  (auth.nim :: ZenitOAuthClientId).")
    stderr.writeLine("")
    stderr.writeLine("  Na razie użyj zwykłego: zpm login --token=<TOKEN> (albo 'zpm login' interaktywnie).")
    quit(1)

  log("[zpm login --device] proszę o kod urządzenia z github.com ...")
  let dc = requestDeviceCode(ZenitOAuthClientId)
  if dc.userCode.len == 0:
    stderr.writeLine("[zpm login --device] ✘ GitHub nie zwrócił kodu urządzenia -- spróbuj 'zpm login --token=...'")
    quit(1)

  echo ""
  echo &"  1. Otwórz w przeglądarce: {dc.verificationUri}"
  echo &"  2. Wpisz kod: {dc.userCode}"
  echo ""
  log("[zpm login --device] czekam na autoryzację w przeglądarce ...")

  let (ok, token, err) = pollForAccessToken(ZenitOAuthClientId, dc.deviceCode, dc.interval, dc.expiresIn)
  if not ok:
    stderr.writeLine(&"[zpm login --device] ✘ {err}")
    quit(1)

  let (verifyOk, ghLogin, expiresAt, verifyErr) = verifyTokenWithGithub(token)
  if not verifyOk:
    stderr.writeLine(&"[zpm login --device] ✘ token otrzymany, ale odrzucony przy weryfikacji: {verifyErr}")
    quit(1)

  saveAuth(StoredAuth(
    token: token,
    login: ghLogin,
    createdAt: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    expiresAt: expiresAt,
  ))
  if ghLogin.len > 0:
    log(&"[zpm login --device] ✔ zalogowano jako '{ghLogin}'.")
  else:
    log("[zpm login --device] ✔ zalogowano.")

proc cmdLogin*(tokenArg: string) =
  ## `zpm login [--token=<TOKEN>]` -- bez `--token` pyta interaktywnie
  ## (ukryty input). Waliduje token przez prawdziwe zapytanie do
  ## api.github.com PRZED zapisaniem -- literówka albo odwołany token nigdy
  ## nie trafia na dysk jako "zalogowany".
  var token = tokenArg
  if token.len == 0:
    if getEnv("ZPM_GITHUB_TOKEN").len > 0:
      token = getEnv("ZPM_GITHUB_TOKEN")
    else:
      echo "Wklej Personal Access Token z GitHuba (github.com/settings/tokens)."
      echo "Wystarczy token bez żadnych specjalnych uprawnień (public_repo/żadnych scope'ów) --"
      echo "służy WYŁĄCZNIE do podniesienia limitu zapytań API, nie do żadnych operacji na Twoim koncie."
      stdout.write("Token: ")
      stdout.flushFile()
      token = readTokenHidden()
  token = token.strip()
  if token.len == 0:
    stderr.writeLine("[zpm login] ✘ pusty token -- przerywam, nic nie zapisano")
    quit(1)

  log("[zpm login] sprawdzam token w api.github.com ...")
  let (ok, login, expiresAt, err) = verifyTokenWithGithub(token)
  if not ok:
    stderr.writeLine(&"[zpm login] ✘ {err}")
    quit(1)

  saveAuth(StoredAuth(
    token: token,
    login: login,
    createdAt: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    expiresAt: expiresAt,
  ))
  if login.len > 0:
    log(&"[zpm login] ✔ zalogowano jako '{login}'. Token zapisany w {authFilePath()} (uprawnienia 0600).")
  else:
    log(&"[zpm login] ✔ token zweryfikowany i zapisany w {authFilePath()} (uprawnienia 0600).")
  if expiresAt.len > 0:
    log(&"[zpm login]   token wygasa: {expiresAt} -- zpm sam go wtedy zapomni, wystarczy zalogować się ponownie.")
  else:
    log("[zpm login]   token bez daty wygaśnięcia -- zostanie zapamiętany do `zpm logout`.")

proc cmdLogout*() =
  if not fileExists(authFilePath()):
    log("[zpm logout] i tak nie było zapisanego tokenu -- nic do zrobienia.")
    return
  clearAuth()
  log(&"[zpm logout] ✔ token usunięty z {authFilePath()}.")

proc cmdAuthStatus*() =
  ## `zpm login --status` / pomocnicze -- pokazuje, czy i skąd zpm weźmie
  ## token PRZY NASTĘPNYM zapytaniu do api.github.com, bez ujawniania
  ## samego tokenu.
  let envToken = getEnv("GITHUB_TOKEN", getEnv("GH_TOKEN", ""))
  if envToken.len > 0:
    log("[zpm login] aktywne źródło: zmienna środowiskowa GITHUB_TOKEN/GH_TOKEN (ma pierwszeństwo nad `zpm login`).")
    return
  let a = loadAuth()
  if a.token.len == 0:
    log("[zpm login] nie zalogowano -- zapytania do api.github.com idą anonimowo (limit 60/h na adres IP).")
    return
  if isExpired(a):
    log(&"[zpm login] zapisany token WYGASŁ ({a.expiresAt}) -- zostanie zapomniany przy następnym użyciu. Uruchom 'zpm login' ponownie.")
    return
  if a.login.len > 0:
    log(&"[zpm login] zalogowano jako '{a.login}'.")
  else:
    log("[zpm login] token zapisany i ważny.")
  if a.expiresAt.len > 0:
    log(&"[zpm login]   wygasa: {a.expiresAt}")
  else:
    log("[zpm login]   bez daty wygaśnięcia.")
