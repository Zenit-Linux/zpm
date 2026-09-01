import std/[json, os, osproc, strutils, strformat, algorithm, strtabs, envvars, sets, tables]
import ./types
import ./deps
import ./lockfile
import ./state
import ./filelock
import ./stagingsafety
import ./trustedkeys
import ./logging
import ./netutil
import ./containerengine

const DefaultOwnRepoPath* = "/etc/zpm/custom/own-repository.json"
const DefaultOwnRepoUrl* =
  "https://raw.githubusercontent.com/Zenit-Linux/own-repository/main/repo/own-repository.json"
  ## NAPRAWIONE: wcześniej wskazywało na "Zenit-Linux/zpm/main/custom/
  ## own-repository.json" -- czyli plik `custom/own-repository.json`
  ## WEWNĄTRZ repo `zpm`. To repo/ścieżka nigdy nie istniały (żadnego
  ## takiego pliku tam nie ma i nigdy nie było) -- kanoniczne źródło to
  ## OSOBNE repo `Zenit-Linux/own-repository`, plik `repo/own-repository.json`
  ## (dokładnie ta konwencja, której `zpk schedule-release` używa do
  ## PUBLIKOWANIA wpisów -- patrz zpk/src/zpkpkg/manifest.nim,
  ## `repo = "https://github.com/Zenit-Linux/own-repository"`,
  ## `repoFile = "repo/own-repository.json"`). Efekt starego URL-a: `zpm
  ## refresh`/auto-refresh zawsze dostawał 404 (ciche niepowodzenie --
  ## `refreshOwnRepository` po prostu zwracał false i zostawiał pustą/
  ## nieistniejącą lokalną kopię), więc ekosystem `own` (zpm, installer,
  ## kernel, ...) nigdy nie był rozpoznawany na świeżej maszynie.
const SupportedOwnSchemaVersions = [1, 2]
  ## Wersje `schema_version` z custom/own-repository.json, które ten zpm
  ## UMIE poprawnie zinterpretować. Nowszy plik (przyszła migracja formatu)
  ## dostaje jawny, czytelny błąd zamiast po cichu "działać" z polami,
  ## których ten zpm nie zna/nie honoruje.
  ## v0.3: dodano 2 -- schemat z polem "branches" per-narzędzie (patrz
  ## resolveOwnToolBranch). Pole "branches" jest CZYSTO ADDYTYWNE (stary
  ## zpm znający tylko schema_version=1 po prostu je zignoruje przy
  ## parsowaniu pojedynczego wpisu -- `item{"klucz"}` nie wywala się na
  ## nieznanych kluczach), więc plik z branches i schema_version=2 działa
  ## ze starym zpm TYLKO jeśli ten plik deklaruje schema_version=1 (co jest
  ## poprawne, jeśli branches są tam czysto opcjonalnym dodatkiem, a nie
  ## wymaganym elementem semantyki) -- schema_version=2 to sygnał "ten plik
  ## ZAKŁADA, że branches są rozumiane", nie techniczna konieczność.
  ## (Tablica, nie `set[int]` -- Nim'owe `set` wymaga wąskiego typu
  ## porządkowego, `int` się do tego nie nadaje.)

# ---------------------------------------------------------------------------
# Parsowanie / walidacja custom/own-repository.json
# ---------------------------------------------------------------------------

proc emptyOwnRepository*(): OwnRepository = OwnRepository(schemaVersion: 1, tools: @[])

proc langExt(lang: string): string =
  ## Domyślne rozszerzenie skryptu dla danego języka (używane do wyliczenia
  ## domyślnych nazw build_script / install_script, gdy nie podano ich
  ## wprost w own-repository.json).
  case lang.toLowerAscii
  of "janet": "janet"
  of "python", "python3": "py"
  of "bash": "sh"
  of "sh", "posix": "sh"
  of "node", "js", "javascript": "js"
  of "lua": "lua"
  of "ruby": "rb"
  of "perl": "pl"
  else: lang  # np. "nim" -> "nim", "zig" -> "zig"; nieznany język == rozszerzenie == nazwa

proc langInterpreter*(lang: string): string =
  ## Nazwa binarki interpretera/runtime'u w PATH dla danego języka.
  ## Domyślny język ekosystemu Zenit to Janet.
  case lang.toLowerAscii
  of "", "janet": "janet"
  of "python", "python3": "python3"
  of "bash": "bash"
  of "sh", "posix": "sh"
  of "node", "js", "javascript": "node"
  of "lua": "lua"
  of "ruby": "rb"
  of "perl": "perl"
  else: lang  # zakładamy, że `lang` to wprost nazwa polecenia w PATH

proc jsonStrSeq(node: JsonNode, key: string): seq[string] =
  result = @[]
  if node.hasKey(key) and node[key].kind == JArray:
    for it in node[key]:
      if it.kind == JString: result.add it.getStr

proc looksLikeGitUrl(s: string): bool =
  s.endsWith(".git") or s.startsWith("git@") or s.startsWith("git://") or s.startsWith("ssh://git@")

proc hostArch*(): string =
  ## Architektura hosta, na którym akurat DZIAŁA zpm (nie mylić z
  ## `cfg.targetArch` -- tą, DLA której budujemy przy cross-compilacji).
  let output = execProcess("uname", args = @["-m"], options = {poUsePath})
  output.strip()

proc parseOwnBin(item: JsonNode): tuple[bin: string, byArch: seq[tuple[arch, url: string]]] =
  ## v0.4 -- "bin" może być zwykłym stringiem (jedna, nieoznaczona
  ## architektura -- kompatybilność wsteczna) ALBO obiektem
  ## `{"x86_64": url, "aarch64": url, ...}`, dokładnie to, co `zpk
  ## schedule-release` publikuje dla pakietów zbudowanych na WIĘCEJ NIŻ
  ## JEDNĄ architekturę (patrz `zpk` repo, `release.nim`/
  ## `buildOwnRepoEntry`). Wcześniej `item{"bin"}.getStr("")` na obiekcie
  ## JSON po cichu zwracało "" -- multi-arch wpis wyglądał jak PUSTY
  ## `bin`, więc `parseOwnTool` odrzucało go jako niepoprawny ("wymaga
  ## niepustego pola 'bin'"), mimo że dane były tam, tylko w innym
  ## kształcie niż spodziewany.
  if not item.hasKey("bin"):
    return ("", @[])
  case item["bin"].kind
  of JString:
    (item["bin"].getStr(""), @[])
  of JObject:
    var byArch: seq[tuple[arch, url: string]] = @[]
    for arch, v in item["bin"].pairs:
      if v.kind == JString and v.getStr("").len > 0:
        byArch.add (arch, v.getStr(""))
    if byArch.len == 0:
      return ("", @[])
    # Wybierz wariant dla architektury HOSTA jako `bin` (wartość używana
    # wszędzie tam, gdzie kod NIE jest świadomy multi-arch -- `own
    # list`/`own info`, stary `downloadOwnTool` bez jawnego `cfg` itp.);
    # jeśli hosta nie ma wśród wariantów, spadamy na PIERWSZY zdefiniowany
    # (kolejność zachowana z JSON-a) zamiast po cichu zwracać "".
    let host = hostArch()
    for (arch, url) in byArch:
      if arch == host: return (url, byArch)
    (byArch[0].url, byArch)
  else:
    ("", @[])

proc parseOwnTool*(item: JsonNode): OwnRepoTool =
  ## Parsuje pojedynczy wpis "tools[]". Rzuca ValueError przy brakujących
  ## polach wymaganych dla danego typu narzędzia -- wołający decyduje, czy
  ## to ma być twarda walidacja (refresh) czy tolerowany warning (load).
  let name = item{"name"}.getStr("")
  if name.len == 0:
    raise newException(ValueError, "wpis bez pola 'name'")

  let (binResolved, binByArch) = parseOwnBin(item)
  let repoRaw = item{"repo"}.getStr("")
  let typeRaw = item{"type"}.getStr("")

  let isGit = typeRaw.toLowerAscii == "git" or repoRaw.len > 0 or
              (typeRaw.len == 0 and looksLikeGitUrl(binResolved))

  let lang = item{"lang"}.getStr("janet")

  if isGit:
    let repoUrl = if repoRaw.len > 0: repoRaw else: binResolved
    if repoUrl.len == 0:
      raise newException(ValueError, &"narzędzie '{name}': typ 'git' wymaga pola 'repo' (lub 'bin' z URL-em .git)")
    result = OwnRepoTool(
      name: name,
      kind: otkGit,
      bin: "",
      sha256: item{"sha256"}.getStr(""),
      info: item{"info"}.getStr(""),
      repo: repoUrl,
      gitRef: item{"ref"}.getStr(item{"branch"}.getStr("main")),
      lang: lang,
      buildScript: item{"build_script"}.getStr("build." & langExt(lang)),
      installScript: item{"install_script"}.getStr("install." & langExt(lang)),
      uninstallScript: item{"uninstall_script"}.getStr(""),
      buildArgs: jsonStrSeq(item, "build_args"),
      installArgs: jsonStrSeq(item, "install_args"),
      dependsOn: jsonStrSeq(item, "depends_on"),
      stage: item{"stage"}.getStr(""),
      allowNetwork: item{"allow_network"}.getBool(false),
      signed: item{"signed"}.getBool(false),
    )
  else:
    if binResolved.len == 0:
      raise newException(ValueError, &"narzędzie '{name}': typ 'binary' wymaga niepustego pola 'bin' " &
        "(string albo obiekt {arch: url} z co najmniej jednym niepustym wariantem)")
    result = OwnRepoTool(
      name: name,
      kind: otkBinary,
      bin: binResolved,
      binByArch: binByArch,
      sha256: item{"sha256"}.getStr(""),
      info: item{"info"}.getStr(""),
      dependsOn: jsonStrSeq(item, "depends_on"),
      stage: item{"stage"}.getStr(""),
    )


proc parseOwnRepositoryJson*(raw: string, strict: bool = true): OwnRepository =
  ## `strict=true` (domyślnie, używane przez `refresh`): CAŁY plik jest
  ## odrzucany (wyjątek) przy JAKIMKOLWIEK błędnym wpisie -- nie chcemy
  ## podmieniać działającej lokalnej kopii na coś częściowo zepsutego.
  ##
  ## `strict=false` (używane przez `loadOwnRepository`, v0.3 -- POPRAWKA
  ## realnego buga): pojedynczy błędny wpis (np. placeholder na
  ## przyszłe narzędzie z pustym `bin`, zanim jego release zostanie
  ## opublikowany) jest POMIJANY z ostrzeżeniem, reszta pliku nadal się
  ## wczytuje. Wcześniej `loadOwnRepository` owijał TEN SAM, zawsze
  ## ścisły parser w try/except na poziomie CAŁEGO pliku -- jeden
  ## niepoprawny wpis (dokładnie to, co miał samo repo zpm: `cr`, `gr`,
  ## `mk`, `pm`, `rm`, `zesh`, `dl`, `about`, `ow` z `"bin": ""`)
  ## powodował, że KAŻDE narzędzie w pliku znikało (`result =
  ## emptyOwnRepository()`), nie tylko to jedno wadliwe -- sprzeczne z
  ## własnym komentarzem dokumentującym tę funkcję ("jeden zły wpis nie
  ## powinien wywalać całego pliku").
  result = emptyOwnRepository()
  let trimmed = raw.strip()
  if trimmed.len == 0:
    return
  let data = parseJson(trimmed)
  if data.kind != JObject:
    raise newException(ValueError, "oczekiwano obiektu JSON na najwyższym poziomie")
  result.schemaVersion = data{"schema_version"}.getInt(1)
  if result.schemaVersion notin SupportedOwnSchemaVersions:
    raise newException(ValueError,
      &"nieobsługiwana wersja schematu {result.schemaVersion} w own-repository.json -- " &
      &"ten zpm obsługuje tylko: {SupportedOwnSchemaVersions} (zaktualizuj zpm albo obniż schema_version źródła)")
  if not data.hasKey("tools"):
    return
  if data["tools"].kind != JArray:
    raise newException(ValueError, "'tools' musi być tablicą")
  var seen: seq[string] = @[]
  for item in data["tools"]:
    if item.kind != JObject: continue
    var tool: OwnRepoTool
    try:
      tool = parseOwnTool(item)
    except ValueError as e:
      if strict:
        raise
      stderr.writeLine(&"[zpm:own] Ostrzeżenie: pomijam niepoprawny wpis w own-repository.json: {e.msg}")
      continue
    if tool.name in seen:
      let msg = &"zduplikowana nazwa narzędzia: '{tool.name}'"
      if strict:
        raise newException(ValueError, msg)
      stderr.writeLine(&"[zpm:own] Ostrzeżenie: {msg} -- pomijam kolejne wystąpienie.")
      continue
    seen.add tool.name
    var toolWithRaw = tool
    toolWithRaw.rawJson = item
    result.tools.add toolWithRaw

proc loadOwnRepository*(path: string): OwnRepository =
  ## Wczytuje lokalną kopię custom/own-repository.json. Pusty/brakujący/
  ## uszkodzony plik (JSON się w ogóle nie parsuje, albo schema_version
  ## nieznana) zwraca pustą listę narzędzi zamiast wywalać cały zpm.
  ## v0.3: POJEDYNCZE niepoprawne wpisy (patrz `parseOwnRepositoryJson`,
  ## `strict=false`) już NIE zabierają całej reszty pliku ze sobą.
  ## Dla ścisłej walidacji całego pliku (np. przy `refresh`) użyj
  ## `parseOwnRepositoryJson(raw, strict = true)`.
  result = emptyOwnRepository()
  if not fileExists(path):
    return
  let raw = readFile(path)
  try:
    result = parseOwnRepositoryJson(raw, strict = false)
  except JsonParsingError as e:
    stderr.writeLine(&"[zpm:own] Ostrzeżenie: nie udało się sparsować {path} ({e.msg}), ignoruję.")
    result = emptyOwnRepository()
  except ValueError as e:
    stderr.writeLine(&"[zpm:own] Ostrzeżenie: {path} nie przeszedł walidacji ({e.msg}), ignoruję.")
    result = emptyOwnRepository()

proc findTool*(repo: OwnRepository, name: string): OwnRepoTool =
  for t in repo.tools:
    if t.name == name: return t
  OwnRepoTool(name: "", kind: otkBinary, bin: "")

proc availableBranches*(tool: OwnRepoTool): seq[string] =
  ## Nazwy branchy zdefiniowanych dla narzędzia (puste, jeśli
  ## own-repository.json go w ogóle nie definiuje "branches" dla tego wpisu).
  result = @[]
  if tool.rawJson.isNil or tool.rawJson.kind != JObject: return
  if not tool.rawJson.hasKey("branches"): return
  let b = tool.rawJson["branches"]
  if b.kind != JObject: return
  for k in b.keys: result.add k

proc resolveOwnToolBranch*(tool: OwnRepoTool, branch: string): tuple[ok: bool, resolved: OwnRepoTool, err: string] =
  ## v0.3 -- rozwiązuje `kernel -> own -> testing` na PEŁNY, samodzielny
  ## `OwnRepoTool` przez shallow-merge pól z `branches[branch]` NA wierzch
  ## oryginalnego wpisu JSON, a następnie ponowne przepuszczenie przez
  ## `parseOwnTool` -- więc branch dostaje TĘ SAMĄ walidację co zwykły
  ## wpis (musi mieć `bin` niepuste dla `binary`, `repo` dla `git`, itd.),
  ## zamiast osobnej, potencjalnie niespójnej ścieżki kodu.
  ##
  ## Pola NIEPODANE w branchu (np. `depends_on`, `stage`, `allow_network`)
  ## są DZIEDZICZONE z bazowego wpisu -- branch nie musi powtarzać
  ## wszystkiego, tylko to, co się różni (typowo `bin`/`repo`/`ref`/`type`).
  if branch.len == 0:
    return (true, tool, "")
  if tool.rawJson.isNil or tool.rawJson.kind != JObject or not tool.rawJson.hasKey("branches"):
    return (false, tool, &"narzędzie '{tool.name}' nie definiuje pola 'branches' w own-repository.json " &
      &"-- '{branch}' niedostępny (dostępny tylko domyślny wariant, bez -> {branch})")
  let branches = tool.rawJson["branches"]
  if branches.kind != JObject or not branches.hasKey(branch):
    let avail = availableBranches(tool)
    let availStr = if avail.len > 0: avail.join(", ") else: "(brak zdefiniowanych)"
    return (false, tool, &"narzędzie '{tool.name}' nie ma brancha '{branch}' -- dostępne: {availStr}")

  var merged = copy(tool.rawJson)
  merged.delete("branches")  # nie propagujemy zagnieżdżonych branchy do wewnątrz
  let branchNode = branches[branch]
  if branchNode.kind != JObject:
    return (false, tool, &"branch '{branch}' narzędzia '{tool.name}' musi być obiektem JSON")
  for k, v in branchNode.pairs:
    merged[k] = v

  try:
    var resolved = parseOwnTool(merged)
    resolved.rawJson = merged
    return (true, resolved, "")
  except ValueError as e:
    return (false, tool, &"branch '{branch}' narzędzia '{tool.name}' nie przeszedł walidacji: {e.msg}")

proc searchOwn*(repo: OwnRepository, query: string): seq[PackageCandidate] =
  result = @[]
  let q = query.toLowerAscii
  for t in repo.tools:
    if t.name.toLowerAscii.contains(q) or (t.info.len > 0 and t.info.toLowerAscii.contains(q)):
      let src = if t.kind == otkGit: &"repo git ({t.repo}, ref={t.gitRef}, {t.lang})" else: t.bin
      result.add PackageCandidate(
        name: t.name, version: "", description: "narzędzie z ekosystemu Zenit (own): " & src,
        backend: bkOwn, installCmd: @[], extra: src
      )

# ---------------------------------------------------------------------------
# `zpm refresh` / `zpm own refresh` -- pobranie świeżego own-repository.json
# ---------------------------------------------------------------------------

proc normalizeOwnRepoUrl*(url: string): string =
  ## Pozwala wkleić do configu zwykły link "github.com/.../blob/..." (tak
  ## jak w treści zadania) i sam zamienia go na link do surowej treści na
  ## raw.githubusercontent.com, zamiast pobierać stronę HTML z GitHuba.
  result = url.strip()
  if "github.com/" in result and "/blob/" in result:
    result = result.replace("https://github.com/", "https://raw.githubusercontent.com/")
    result = result.replace("http://github.com/", "https://raw.githubusercontent.com/")
    result = result.replace("/blob/", "/")

proc refreshOwnRepository*(cfg: ZpmConfig): bool =
  ## Pobiera custom/own-repository.json z `cfg.ownRepoUrl` (a przy błędzie
  ## kolejno próbuje `cfg.ownRepoMirrors`), WALIDUJE go (musi się dać
  ## sparsować i przejść wymagania pól), i dopiero wtedy podmienia lokalną
  ## kopię pod `cfg.customRepoPath`. Poprzednia kopia trafia do
  ## `<path>.bak`, więc uszkodzone/nieosiągalne repo zdalne nigdy nie
  ## psuje działającej instalacji.
  ##
  ## v0.2:
  ##  - pobrania idą teraz przez netutil.nim -- honorują
  ##    `security.trusted_hosts`/`security.max_download_mb`;
  ##  - główne (pierwsze) źródło korzysta z `cachedFetch` (ETag/
  ##    If-Modified-Since) -- odpowiedź 304 kończy `zpm update` bez
  ##    ponownego ściągania całego JSON-a. Mirrory (używane tylko gdy
  ##    główne źródło zawiedzie) idą przez zwykłe pobranie, bo cache jest
  ##    przypisany do KONKRETNEGO URL-a.
  if cfg.offlineMode:
    stderr.writeLine("[zpm:refresh] Tryb --offline: pomijam pobieranie, zostaje lokalna kopia custom/own-repository.json.")
    return true

  var urls: seq[string] = @[]
  if cfg.ownRepoUrl.len > 0: urls.add normalizeOwnRepoUrl(cfg.ownRepoUrl)
  for m in cfg.ownRepoMirrors:
    if m.len > 0: urls.add normalizeOwnRepoUrl(m)

  if urls.len == 0:
    stderr.writeLine("[zpm:refresh] Brak skonfigurowanego 'custom.remote_url' (ani mirrorów) -- pomijam.")
    return false

  var body = ""
  var fetched = false
  var fromCache = false
  let cachePath = cfg.httpCacheDir / "own-repository.json"
  for i, url in urls:
    echo &"[zpm:refresh] Pobieram {url} ..." & (if i > 0: &" (mirror {i+1}/{urls.len})" else: "")
    let r =
      if i == 0: cachedFetch(url, cachePath, cfg, "zpm:refresh")
      else: safeFetchUrlBody(url, cfg, "zpm:refresh")
    if r.ok:
      body = r.body
      fetched = true
      fromCache = r.fromCache
      break
    else:
      stderr.writeLine(&"[zpm:refresh] Próbuję kolejne źródło...")

  if not fetched:
    stderr.writeLine("[zpm:refresh] ✘ Żadne z skonfigurowanych źródeł (remote_url + mirrors) nie odpowiedziało.")
    return false

  if fromCache and fileExists(cfg.customRepoPath):
    log("[zpm:refresh] ✔ Serwer potwierdził brak zmian (304) -- lokalna kopia już aktualna.")
    return true

  var parsed: OwnRepository
  try:
    parsed = parseOwnRepositoryJson(body)
  except CatchableError as e:
    stderr.writeLine(&"[zpm:refresh] ✘ Pobrany plik nie przeszedł walidacji, NIE nadpisuję lokalnej kopii: {e.msg}")
    return false

  createDir(parentDir(cfg.customRepoPath))

  if fileExists(cfg.customRepoPath):
    try:
      copyFile(cfg.customRepoPath, cfg.customRepoPath & ".bak")
    except CatchableError as e:
      stderr.writeLine(&"[zpm:refresh] Ostrzeżenie: nie udało się zrobić kopii zapasowej: {e.msg}")

  let tmpPath = cfg.customRepoPath & ".tmp"
  try:
    writeFile(tmpPath, body)
    moveFile(tmpPath, cfg.customRepoPath)
  except CatchableError as e:
    stderr.writeLine(&"[zpm:refresh] ✘ Nie udało się zapisać {cfg.customRepoPath}: {e.msg}")
    return false

  log(&"[zpm:refresh] ✔ own-repository.json odświeżony -- {parsed.tools.len} narzędzi (schema v{parsed.schemaVersion}).")
  true

# ---------------------------------------------------------------------------
# Instalacja narzędzi typu `binary` (dosłowna, zlinkowana binarka)
# ---------------------------------------------------------------------------

proc sha256sumOf*(path: string): string =
  ## Bez zależności krypto -- deleguje do sha256sum, tak jak reszta zpm/zlb.
  let sha = execProcess("sha256sum", args = @[path], options = {poUsePath})
  if sha.len == 0: return ""
  sha.split(' ')[0].strip()

proc resolveOwnBinUrl*(tool: OwnRepoTool, cfg: ZpmConfig): string =
  ## v0.4 -- wybiera właściwy URL z `tool.binByArch` dla ARCHITEKTURY
  ## DOCELOWEJ pobierania: `cfg.targetArch`, jeśli ustawione (cross-arch,
  ## np. budowanie obrazu innej dystrybucji), inaczej architektura hosta.
  ## Dla wpisów jednoarchitekturowych (`binByArch` puste -- "bin" był
  ## zwykłym stringiem w JSON-ie) po prostu zwraca `tool.bin` -- pełna
  ## kompatybilność wsteczna, zero zmiany zachowania dla starych wpisów.
  if tool.binByArch.len == 0:
    return tool.bin
  let want = if cfg.targetArch.len > 0: cfg.targetArch else: hostArch()
  for (arch, url) in tool.binByArch:
    if arch == want: return url
  # Architektura docelowa nie ma dedykowanego builda -- spadamy na to, co
  # `parseOwnTool` już wybrało jako "najlepsze dopasowanie" (host albo
  # pierwszy wariant), zamiast twardo zawodzić.
  log(&"[zpm:own] ⚠ '{tool.name}': brak wariantu 'bin' dla architektury '{want}' -- używam {tool.bin}")
  tool.bin

proc downloadOwnTool*(tool: OwnRepoTool, destDir: string, cfg: ZpmConfig): tuple[ok: bool, path: string] =
  ## Pobiera binarkę narzędzia z jego dosłownego URL-a przez netutil.nim
  ## (v0.2: honoruje `security.trusted_hosts`/`max_download_mb`, loguje
  ## postęp pobierania co ~10% pod --verbose -- zamiast w pełni cichego
  ## `std/httpclient.downloadFile` bez żadnej z tych warstw),
  ## zapisuje do destDir/<name>, ustawia +x i (jeśli podano) weryfikuje sha256.
  ## v0.4: jeśli narzędzie ma kilka wariantów architektur (`binByArch`),
  ## wybiera ten pasujący do `cfg.targetArch`/hosta -- patrz `resolveOwnBinUrl`.
  let binUrl = resolveOwnBinUrl(tool, cfg)
  if binUrl.len == 0:
    return (false, "")
  createDir(destDir)
  let dest = destDir / tool.name
  log(&"[zpm:own] Pobieram '{tool.name}' z {binUrl} ...")
  let (dlOk, dlErr) = safeDownloadFile(binUrl, dest, cfg, "zpm:own")
  if not dlOk:
    stderr.writeLine(&"[zpm:own] ✘ Pobieranie '{tool.name}' nie powiodło się: {dlErr}")
    return (false, "")

  when defined(posix):
    discard execShellCmd(&"chmod +x \"{dest}\"")

  if tool.sha256.len > 0:
    let got = sha256sumOf(dest)
    if got.len > 0 and got != tool.sha256:
      stderr.writeLine(&"[zpm:own] ✘ Suma sha256 narzędzia '{tool.name}' nie zgadza się " &
        &"(oczekiwano {tool.sha256}, otrzymano {got}) -- usuwam plik.")
      removeFile(dest)
      return (false, "")

  log(&"[zpm:own] ✔ '{tool.name}' zainstalowane w {dest}")
  (true, dest)

# ---------------------------------------------------------------------------
# Instalacja narzędzi typu `git` (budowanie ze źródeł: build.<lang> + install.<lang>)
# ---------------------------------------------------------------------------

proc gitAvailable(): bool = findExe("git").len > 0

proc toolCacheDir*(cfg: ZpmConfig, tool: OwnRepoTool): string =
  cfg.ownGitCacheDir / tool.name

proc bundlePath(cfg: ZpmConfig, tool: OwnRepoTool): string =
  cfg.ownGitCacheDir / (tool.name & ".bundle")

proc effectiveGitRef*(tool: OwnRepoTool, cfg: ZpmConfig): tuple[refStr: string, fromLock: bool] =
  ## Zwraca ref, którego NAPRAWDĘ mamy użyć: jeśli zpm.lock ma wpis dla
  ## tego narzędzia -- dokładny zablokowany commit (reprodukowalność
  ## wygrywa z tym, co akurat mówi own-repository.json). W przeciwnym
  ## razie -- `tool.gitRef` z JSON-a (zwykle branch, np. "main").
  let lock = loadLock(cfg.lockPath)
  let (found, entry) = lock.findEntry(tool.name)
  if found and entry.kind == otkGit and entry.resolvedRef.len > 0:
    return (entry.resolvedRef, true)
  (tool.gitRef, false)

proc resolveAndLockGitRef*(tool: OwnRepoTool, cfg: ZpmConfig): tuple[ok: bool, commit: string] =
  ## Używane WYŁĄCZNIE przez `zpm lock --update` -- w przeciwieństwie do
  ## `ensureGitSource` celowo IGNORUJE istniejący wpis w zpm.lock (bo cały
  ## sens tej procedury to policzenie NOWEGO pinu): klonuje/aktualizuje
  ## repo, checkoutuje `tool.gitRef` z own-repository.json wprost (np.
  ## "main"), i zwraca dokładny commit, na którym się to zatrzymało.
  if not gitAvailable():
    stderr.writeLine("[zpm:lock] ✘ Polecenie 'git' nie jest dostępne w PATH.")
    return (false, "")
  let cacheDir = toolCacheDir(cfg, tool)
  let lock =
    try:
      acquireLock(cacheDir, cfg.lockTimeoutSec)
    except LockTimeoutError as e:
      stderr.writeLine(e.msg)
      return (false, "")
  defer: release(lock)
  if dirExists(cacheDir / ".git"):
    discard execCmd(&"git -C \"{cacheDir}\" fetch --all --tags --quiet")
  else:
    createDir(parentDir(cacheDir))
    if dirExists(cacheDir): removeDir(cacheDir)
    if execCmd(&"git clone --quiet \"{tool.repo}\" \"{cacheDir}\"") != 0:
      stderr.writeLine(&"[zpm:lock] ✘ 'git clone' nie powiodło się dla '{tool.name}'.")
      return (false, "")
  let ref0 = if tool.gitRef.len > 0: tool.gitRef else: "main"
  if execCmd(&"git -C \"{cacheDir}\" checkout --quiet \"{ref0}\"") != 0:
    stderr.writeLine(&"[zpm:lock] ✘ Nie udało się checkoutować ref '{ref0}' dla '{tool.name}'.")
    return (false, "")
  discard execCmd(&"git -C \"{cacheDir}\" pull --ff-only --quiet")
  let commit = resolveGitCommit(cacheDir)
  if commit.len == 0:
    stderr.writeLine(&"[zpm:lock] ✘ Nie udało się odczytać commitu HEAD dla '{tool.name}'.")
    return (false, "")
  (true, commit)

proc verifyGitSignature(cacheDir, refStr: string, cfg: ZpmConfig, toolName: string, rootPath: string = "/"): bool =
  ## Najpierw próbuje zweryfikować podpisany COMMIT (`verify-commit HEAD`
  ## -- działa dla dowolnego refa po checkoucie), a jeśli to się nie uda,
  ## próbuje zweryfikować `refStr` jako podpisany TAG (`verify-tag`).
  ## Wymaga, żeby autor/tagger miał w systemie zaufany klucz GPG -- to
  ## jest jawnie odpowiedzialność operatora (`git config` / `gpg --import`
  ## zaufanego keyringu Zenit), zpm tego nie zarządza.
  ##
  ## v0.2: jeśli operator wywołał `zpm init --trust-keys=<plik>` (patrz
  ## trustedkeys.nim), samo "git twierdzi, że podpis OK" już NIE
  ## wystarcza -- fingerprint podpisującego klucza musi DODATKOWO być na
  ## tej liście. To domyka lukę, w której `--trust-keys` tylko drukowało
  ## komunikat, nie blokując niczego realnie.
  ##
  ## v0.2.1: `rootPath` jest teraz PRZEKAZYWANE przez cały łańcuch wywołań
  ## (buildOwnFromSource -> ensureGitSource -> verifyGitSignature), więc
  ## w trybie budowania (`zpm --root=<r> own install ...`) sprawdzana jest
  ## lista zaufanych kluczy PER-OBRAZ (`<r>/etc/zpm/trusted-keys.list`,
  ## zapisana przez `runBuildingInit`), nie hostowa. Wcześniej ta funkcja
  ## zawsze patrzyła na hostową ścieżkę (domyślne "/"), więc `zpm --root=X
  ## init --trust-keys=...` i późniejsze `zpm --root=X own install ...`
  ## faktycznie sprawdzały DWIE RÓŻNE listy kluczy -- w praktyce działało
  ## to tylko przez przypadek, jeśli obie ścieżki miały tę samą zawartość.
  let (_, commitCode) = execCmdEx(&"git -C \"{cacheDir}\" verify-commit HEAD")
  var okGit = false
  var tryCommit = true
  if commitCode == 0:
    okGit = true
  else:
    let (_, tagCode) = execCmdEx(&"git -C \"{cacheDir}\" verify-tag \"{refStr}\"")
    okGit = tagCode == 0
    tryCommit = false
  if not okGit: return false

  if not trustedKeysConfigured(cfg, rootPath):
    return true  # kompatybilność wsteczna: brak listy = ufaj samemu gpg/git

  let fpr = extractSignerFingerprint(cacheDir, refStr, tryCommit)
  if fpr.len == 0:
    stderr.writeLine(&"[zpm:own] ✘ '{toolName}': nie udało się ustalić fingerprintu podpisującego klucza mimo poprawnego podpisu.")
    return false
  if not isFingerprintTrusted(cfg, fpr, rootPath):
    let listPath = trustedKeysStatePathFor(cfg, rootPath)
    stderr.writeLine(&"[zpm:own] ✘ '{toolName}': podpis zweryfikowany, ALE klucz {fpr} NIE jest na liście " &
      &"zaufanej ({listPath}) -- odrzucam. Dodaj klucz do pliku --trust-keys i uruchom " &
      "`zpm init --trust-keys=<plik>` ponownie, jeśli to zamierzone.")
    return false
  true

proc ensureGitSource(tool: OwnRepoTool, cacheDir: string, cfg: ZpmConfig, rootPath: string = "/"): tuple[ok: bool, path: string] =
  ## Klonuje repo narzędzia do cacheDir (albo aktualizuje istniejący klon)
  ## i checkoutuje efektywny ref (patrz `effectiveGitRef` -- zpm.lock ma
  ## pierwszeństwo nad `tool.gitRef` z JSON-a). Respektuje `cfg.offlineMode`
  ## (klonuje tylko z lokalnego `git bundle`, nigdy z sieci), opcjonalnie
  ## tworzy taki bundle po udanym klonie online (`cfg.vendorSources`),
  ## wymusza `cfg.requirePinnedRef` i weryfikuje podpisy (`cfg.verifySignatures`).
  if not gitAvailable():
    stderr.writeLine("[zpm:own] ✘ Polecenie 'git' nie jest dostępne w PATH -- wymagane dla narzędzi typu 'git'.")
    return (false, "")

  let (refStr, lockedRef) = effectiveGitRef(tool, cfg)

  if cfg.requirePinnedRef and not lockedRef and (refStr.len == 0 or refStr in ["main", "master"]):
    stderr.writeLine(&"[zpm:own] ✘ '{tool.name}': security.require_pinned_ref=true, ale ref to " &
      &"'{refStr}' i brak wpisu w zpm.lock. Uruchom `zpm lock --update {tool.name}` po " &
      "zweryfikowaniu źródła, albo ustaw w own-repository.json konkretny tag/commit.")
    return (false, "")

  let bundle = bundlePath(cfg, tool)

  # Blokada per katalog cache'u TEGO narzędzia -- chroni przed dwoma
  # równoległymi procesami zpm (typowe w CI: kilka jobów buildera naraz)
  # bijącymi się o ten sam `git clone`/`checkout`. Różne narzędzia mają
  # różne cacheDir, więc nie serializuje się to, co nie musi.
  let lock =
    try:
      acquireLock(cacheDir, cfg.lockTimeoutSec)
    except LockTimeoutError as e:
      stderr.writeLine(e.msg)
      return (false, "")
  defer: release(lock)

  if cfg.offlineMode:
    if dirExists(cacheDir / ".git"):
      log(&"[zpm:own] [offline] Używam istniejącego lokalnego klonu '{tool.name}' w {cacheDir} ...")
    elif fileExists(bundle):
      log(&"[zpm:own] [offline] Klonuję '{tool.name}' z lokalnego bundla {bundle} ...")
      createDir(parentDir(cacheDir))
      let code = execCmd(&"git clone --quiet \"{bundle}\" \"{cacheDir}\"")
      if code != 0:
        stderr.writeLine(&"[zpm:own] ✘ Klonowanie z bundla nie powiodło się dla '{tool.name}' (kod {code}).")
        return (false, "")
    else:
      stderr.writeLine(&"[zpm:own] ✘ [offline] Brak lokalnego klonu i brak bundla {bundle} dla '{tool.name}' -- " &
        "nie da się zbudować bez sieci. Zbuduj raz online z 'custom.vendor_sources = true', żeby taki bundle powstał.")
      return (false, "")
  elif dirExists(cacheDir / ".git"):
    log(&"[zpm:own] Aktualizuję istniejący klon '{tool.name}' w {cacheDir} ...")
    let fetchCode = execCmd(&"git -C \"{cacheDir}\" fetch --all --tags --quiet")
    if fetchCode != 0:
      stderr.writeLine(&"[zpm:own] Ostrzeżenie: 'git fetch' nie powiodło się dla '{tool.name}' (kod {fetchCode}) -- pracuję na tym, co jest w cache'u.")
  else:
    createDir(parentDir(cacheDir))
    if dirExists(cacheDir):
      removeDir(cacheDir)  # niekompletny/stary klon bez .git -- czyste podejście od zera
    log(&"[zpm:own] Klonuję '{tool.name}' z {tool.repo} (ref={refStr}) do {cacheDir} ...")
    let code = execCmd(&"git clone --quiet \"{tool.repo}\" \"{cacheDir}\"")
    if code != 0:
      stderr.writeLine(&"[zpm:own] ✘ 'git clone' nie powiodło się dla '{tool.name}' (kod {code}).")
      return (false, "")
    if cfg.vendorSources:
      createDir(parentDir(bundle))
      let bundleCode = execCmd(&"git -C \"{cacheDir}\" bundle create \"{bundle}\" --all")
      if bundleCode == 0:
        log(&"[zpm:own] Zvendorowano źródła '{tool.name}' do {bundle} (do użytku offline).")
      else:
        stderr.writeLine(&"[zpm:own] Ostrzeżenie: nie udało się utworzyć bundla {bundle} (kod {bundleCode}).")

  let coCode = execCmd(&"git -C \"{cacheDir}\" checkout --quiet \"{refStr}\"")
  if coCode != 0:
    stderr.writeLine(&"[zpm:own] ✘ Nie udało się checkoutować ref '{refStr}' dla '{tool.name}' (kod {coCode}).")
    return (false, "")

  # `pull` ma sens tylko na branchu śledzącym zdalny -- błąd (np. detached
  # HEAD po checkoucie taga/commita/zablokowanego commitu) jest tu
  # całkowicie oczekiwany i nieszkodliwy.
  if not cfg.offlineMode and not lockedRef:
    discard execCmd(&"git -C \"{cacheDir}\" pull --ff-only --quiet")

  if cfg.verifySignatures or tool.signed:
    if not verifyGitSignature(cacheDir, refStr, cfg, tool.name, rootPath):
      stderr.writeLine(&"[zpm:own] ✘ Weryfikacja podpisu GPG nie powiodła się dla '{tool.name}' @ {refStr} -- przerywam.")
      return (false, "")
    log(&"[zpm:own] ✔ Podpis GPG '{tool.name}' @ {refStr} zweryfikowany.")
  (true, cacheDir)

proc buildEnv(extra: openArray[(string, string)]): StringTableRef =
  ## Kopiuje bieżące środowisko procesu i dokłada zmienne specyficzne dla
  ## skryptów build.janet/install.janet -- bez trwałego modyfikowania
  ## środowiska samego zpm (w przeciwieństwie do putEnv).
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  for (k, v) in extra:
    result[k] = v

proc commonToolEnv(tool: OwnRepoTool, cfg: ZpmConfig): seq[(string, string)] =
  ## Zmienne wspólne dla KAŻDEGO uruchomienia skryptu narzędzia `own`:
  ## cache kompilacji (ccache/sccache) i architektura hosta/celu (cross-
  ## -compilation). Osobny katalog cache'u per narzędzie, żeby jeden zepsuty
  ## build nie zaśmiecał/nie kolidował z cache'em innego.
  result = @[]
  if cfg.ccacheDir.len > 0:
    let dir = cfg.ccacheDir / tool.name
    createDir(dir)
    result.add ("CCACHE_DIR", dir)
    result.add ("SCCACHE_DIR", dir)
    result.add ("ZPM_CCACHE_DIR", dir)
  let host = hostArch()
  let target = if cfg.targetArch.len > 0: cfg.targetArch else: host
  result.add ("ZPM_HOST_ARCH", host)
  result.add ("ZPM_TARGET_ARCH", target)
  if cfg.targetArch.len > 0 and cfg.targetArch != host:
    result.add ("ZPM_CROSS_COMPILE", "1")

proc sandboxWrap(cfg: ZpmConfig, tool: OwnRepoTool, dir: string,
                  extraWritable: openArray[string], cmd: seq[string]): tuple[ok: bool, cmd: seq[string]] =
  ## Gdy `security.sandbox_enabled = true` opakowuje `cmd` w izolację przed
  ## wykonaniem build/install skryptu. v0.3: DWA niezależne tryby wybierane
  ## przez `security.build_isolation`:
  ##   "bwrap" (domyślnie) -- przestrzenie nazw Linuksa dzielą jądro hosta
  ##     (szybkie, bez pobierania obrazu, ale nie izoluje np. wersji libc).
  ##   "container" -- `cmd` uruchamiane wewnątrz efemerycznego kontenera
  ##     podman/buildah opartego o `security.build_isolation_image` (osobny
  ##     rootfs, mocniejsza izolacja, wolniejszy start) -- patrz
  ##     `containerSandboxWrap` w containerengine.nim.
  ##   "none" -- jawny, głośno ostrzegany opt-out (bez żadnej izolacji).
  ##
  ## `security.sandbox_required = true` (domyślnie): brak mechanizmu
  ## wybranego przez `build_isolation` to TWARDY błąd (`ok = false`) --
  ## zpm ODMAWIA cichego uruchomienia bez izolacji. Świadome wyłączenie
  ## (`sandbox_required = false`) zostaje z ostrzeżeniem.
  if not cfg.sandboxEnabled:
    return (true, cmd)

  case cfg.buildIsolation.toLowerAscii
  of "none":
    stderr.writeLine("[zpm:own] Ostrzeżenie: security.build_isolation=\"none\" -- uruchamiam BEZ JAKIEJKOLWIEK izolacji.")
    return (true, cmd)
  of "container":
    let (cOk, cCmd, cErr) = containerSandboxWrap(cfg.buildIsolationImage, dir, extraWritable, tool.allowNetwork, cmd)
    if cOk:
      return (true, cCmd)
    if cfg.sandboxRequired:
      stderr.writeLine(&"[zpm:own] ✘ {cErr}.")
      return (false, cmd)
    stderr.writeLine(&"[zpm:own] Ostrzeżenie: {cErr} -- uruchamiam BEZ piaskownicy (sandbox_required=false).")
    return (true, cmd)
  else:
    discard  # "bwrap" (domyślne) -- kod poniżej, niezmieniony względem v0.2

  let sandboxBin = if cfg.sandboxCmd.len > 0: cfg.sandboxCmd else: "bwrap"
  if findExe(sandboxBin).len == 0:
    if cfg.sandboxRequired:
      stderr.writeLine(&"[zpm:own] ✘ security.sandbox_enabled=true, ale '{sandboxBin}' nie jest w PATH.")
      stderr.writeLine( "[zpm:own]   Zainstaluj 'bubblewrap' (pakiet 'bubblewrap'/'bwrap' w Twojej dystrybucji hosta),")
      stderr.writeLine( "[zpm:own]   albo świadomie wyłącz ochronę: security.sandbox_required = false w config.hcl,")
      stderr.writeLine( "[zpm:own]   albo przełącz na inny tryb: security.build_isolation = \"container\".")
      return (false, cmd)
    stderr.writeLine(&"[zpm:own] Ostrzeżenie: '{sandboxBin}' nie jest w PATH -- uruchamiam BEZ piaskownicy (sandbox_required=false).")
    return (true, cmd)
  var wrapped = @[sandboxBin, "--die-with-parent", "--unshare-all",
                  "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
                  "--tmpfs", "/tmp", "--bind", dir, dir]
  if tool.allowNetwork:
    wrapped.add "--share-net"
  for w in extraWritable:
    if w.len > 0:
      createDir(w)
      wrapped.add "--bind"
      wrapped.add w
      wrapped.add w
  wrapped.add "--"
  (true, wrapped & cmd)

proc cgroupsV2Delegated*(): bool =
  dirExists("/sys/fs/cgroup") and fileExists("/sys/fs/cgroup/cgroup.controllers")

proc tryCgroupV2Wrap(cfg: ZpmConfig, toolName: string, cmd: seq[string]): tuple[ok: bool, cmd: seq[string]] =
  ## v0.2 -- druga (fallback) warstwa egzekwowania MemoryMax/CPUQuota gdy
  ## `systemd-run` nie jest w PATH: pisze wprost do cgroups v2 (jeśli
  ## `/sys/fs/cgroup` jest zdelegowany/zapisywalny dla bieżącego usera --
  ## na hoście z systemd to zwykle prawda dla usera w sesji, na builderze
  ## CI zależy od konfiguracji runnera). Standardowa technika: tworzymy
  ## podgrupę, wpisujemy limity, i owijamy polecenie w `sh -c` które
  ## najpierw wpisuje WŁASNY pid do cgroup.procs, a dopiero potem robi
  ## `exec` w docelowe polecenie -- więc limity obowiązują od pierwszej
  ## instrukcji, nie tylko "od kiedy ktoś zdąży dopisać pid z zewnątrz".
  if not cgroupsV2Delegated(): return (false, cmd)
  let base = "/sys/fs/cgroup/zpm"
  let grp = base / (toolName & "-" & $getCurrentProcessId())
  try:
    createDir(grp)
  except CatchableError:
    return (false, cmd)  # brak uprawnień do delegowanej cgroup -- fallback dalej

  var wrote = false
  if cfg.buildMemoryLimit.len > 0:
    try:
      writeFile(grp / "memory.max", cfg.buildMemoryLimit)
      wrote = true
    except CatchableError:
      discard
  if cfg.buildCpuQuota.len > 0:
    try:
      let pctStr = cfg.buildCpuQuota.strip(chars = {'%'})
      let pctVal = parseFloat(pctStr)
      let quota = int(pctVal / 100.0 * 100_000.0)
      writeFile(grp / "cpu.max", $quota & " 100000")
      wrote = true
    except CatchableError, ValueError:
      discard
  if not wrote:
    return (false, cmd)

  let procsFile = grp / "cgroup.procs"
  let shellCmd = "echo $$ > " & procsFile.quoteShell & "; exec \"$@\""
  (true, @["sh", "-c", shellCmd, "sh"] & cmd)

proc resourceWrap(cfg: ZpmConfig, toolName: string, cmd: seq[string]): tuple[ok: bool, cmd: seq[string]] =
  ## Dwie NIEZALEŻNE warstwy limitów zasobów, dokładane WOKÓŁ (ewentualnie
  ## już opakowanego przez `sandboxWrap`) polecenia:
  ##  1. `timeout <build_timeout_sec>s` (coreutils, zawsze dostępny) --
  ##     runaway proces (zawieszony kompilator, proces czekający na stdin)
  ##     nie wisi w nieskończoność. To NIE jest opcjonalne/best-effort.
  ##  2. MemoryMax/CPUQuota -- PRZEZ `systemd-run --scope`, a gdy ten
  ##     niedostępny (v0.2), PRZEZ bezpośredni zapis do cgroups v2
  ##     (`tryCgroupV2Wrap`) -- dopiero gdy OBIE zawiodą, jest to
  ##     faktycznie best-effort (ostrzeżenie), CHYBA że
  ##     `security.strict_resource_limits = true`, wtedy to TWARDY błąd.
  ##     `bwrap` sam z siebie NIE limituje CPU/RAM/PID-ów (tylko FS/sieć).
  result = (true, cmd)
  if cfg.buildMemoryLimit.len > 0 or cfg.buildCpuQuota.len > 0:
    if findExe("systemd-run").len > 0:
      var wrap = @["systemd-run", "--scope", "--quiet", "--collect", "--same-dir", "--pty"]
      if cfg.buildMemoryLimit.len > 0:
        wrap.add "-p"; wrap.add ("MemoryMax=" & cfg.buildMemoryLimit)
      if cfg.buildCpuQuota.len > 0:
        wrap.add "-p"; wrap.add ("CPUQuota=" & cfg.buildCpuQuota)
      wrap.add "--"
      result.cmd = wrap & result.cmd
    else:
      let (cgOk, cgCmd) = tryCgroupV2Wrap(cfg, toolName, result.cmd)
      if cgOk:
        stderr.writeLine("[zpm:own] Uwaga: 'systemd-run' niedostępny -- egzekwuję MemoryMax/CPUQuota " &
          "bezpośrednio przez cgroups v2 (fallback v0.2).")
        result.cmd = cgCmd
      elif cfg.strictResourceLimits:
        stderr.writeLine("[zpm:own] ✘ security.strict_resource_limits=true, ale ani 'systemd-run', ani " &
          "zapisywalna delegowana cgroup v2 (/sys/fs/cgroup/zpm) nie są dostępne -- odmawiam uruchomienia " &
          "BEZ gwarancji limitów pamięci/CPU. Zainstaluj systemd, deleguj cgroup, albo wyłącz " &
          "strict_resource_limits (świadomie akceptując best-effort).")
        return (false, cmd)
      else:
        stderr.writeLine("[zpm:own] Ostrzeżenie: security.build_memory_limit/build_cpu_quota ustawione, " &
          "ale ani 'systemd-run', ani zapisywalna cgroup v2 nie są dostępne -- pomijam limity CPU/RAM " &
          "dla tego uruchomienia (best effort).")
  if cfg.buildTimeoutSec > 0:
    if findExe("timeout").len > 0:
      result.cmd = @["timeout", "--kill-after=10", &"{cfg.buildTimeoutSec}s"] & result.cmd
    else:
      stderr.writeLine("[zpm:own] Ostrzeżenie: brak polecenia 'timeout' (coreutils) w PATH -- " &
        "build_timeout_sec NIE jest egzekwowany dla tego uruchomienia.")

proc runToolScript(tool: OwnRepoTool, dir, script: string, args: seq[string],
                    cfg: ZpmConfig, extraEnv: openArray[(string, string)] = [],
                    extraWritable: openArray[string] = []): int =
  let interp = langInterpreter(tool.lang)
  let scriptPath = dir / script
  if not fileExists(scriptPath):
    stderr.writeLine(&"[zpm:own] ✘ Brak skryptu '{script}' w {dir} (narzędzie '{tool.name}').")
    return 127
  if findExe(interp).len == 0:
    stderr.writeLine(&"[zpm:own] ✘ Brak interpretera/runtime'u '{interp}' w PATH -- wymagany do uruchomienia '{script}' (lang={tool.lang}).")
    return 127
  let argsStr = args.join(" ")
  let fullEnv = commonToolEnv(tool, cfg) & @extraEnv
  var cmd = @[interp, scriptPath] & args
  let (sandboxOk, sandboxedCmd) = sandboxWrap(cfg, tool, dir, extraWritable, cmd)
  if not sandboxOk:
    return 126  # konwencja shellowa: "polecenie znalezione, ale nie do uruchomienia"
  let (resourceOk, resourcedCmd) = resourceWrap(cfg, tool.name, sandboxedCmd)
  if not resourceOk:
    return 126
  cmd = resourcedCmd
  let tag = if cmd[0] != interp: &"[{cmd[0]}] " else: ""
  log(&"[zpm:own] $ (cwd={dir}) {tag}{interp} {script} {argsStr}")
  let p = startProcess(cmd[0], workingDir = dir, args = cmd[1..^1],
                        env = buildEnv(fullEnv),
                        options = {poUsePath, poParentStreams})
  result = p.waitForExit()
  p.close()
  if result == 124 or result == 137:
    stderr.writeLine(&"[zpm:own] ✘ '{tool.name}': {script} przerwane przez timeout (build_timeout_sec={cfg.buildTimeoutSec}).")

proc buildOwnFromSource*(tool: OwnRepoTool, cfg: ZpmConfig, rootPath: string = "/"): tuple[ok: bool, srcDir: string] =
  ## Klonuje/aktualizuje repo (respektując zpm.lock/offline/podpisy/pinning
  ## -- patrz ensureGitSource) i uruchamia skrypt budujący (domyślnie
  ## build.janet). To jest krok 1/2 dla narzędzi typu `git`.
  ##
  ## v0.2.1: `rootPath` przekazywany dalej do `ensureGitSource` ->
  ## `verifyGitSignature`, żeby w trybie budowania (`--root=<r>`) podpisy
  ## były sprawdzane względem listy zaufanych kluczy PER-OBRAZ, nie hosta.
  if tool.kind != otkGit:
    stderr.writeLine(&"[zpm:own] '{tool.name}' nie jest narzędziem typu 'git'.")
    return (false, "")
  let cacheDir = toolCacheDir(cfg, tool)
  let (cloned, srcDir) = ensureGitSource(tool, cacheDir, cfg, rootPath)
  if not cloned: return (false, "")
  let (refStr, _) = effectiveGitRef(tool, cfg)
  log(&"[zpm:own] Buduję '{tool.name}' ze źródeł ({tool.lang}: {tool.buildScript}, ref={refStr}) ...")
  let code = runToolScript(tool, srcDir, tool.buildScript, tool.buildArgs, cfg,
                            [("ZPM_TOOL_NAME", tool.name), ("ZPM_TOOL_REF", refStr),
                             ("ZPM_TOOL_STAGE", tool.stage)])
  if code != 0:
    stderr.writeLine(&"[zpm:own] ✘ Budowanie '{tool.name}' nie powiodło się (kod {code}).")
    return (false, srcDir)
  log(&"[zpm:own] ✔ '{tool.name}' zbudowane w {srcDir}")
  (true, srcDir)

proc mergeStagingInto(stagingDir, rootPath: string): bool =
  ## "Commit" udanej instalacji: kopiuje zawartość stagingu do rootPath.
  ## Uruchamiane WYŁĄCZNIE po tym, jak install.<lang> zwróciło kod 0.
  ##
  ## v0.2: zamiast gołego `cp -a` (które BEZ ochrony podąża za symlinkami
  ## już istniejącymi w destynacji i nie ma żadnej formy cofnięcia), używa
  ## `safeMergeStaging` (stagingsafety.nim): odrzuca CAŁY staging, jeśli
  ## zawiera jakikolwiek symlink, sprawdza przed KAŻDYM zapisem czy który
  ## z katalogów nadrzędnych w rootPath nie jest symlinkiem, robi
  ## pre-check wolnego miejsca na dysku, i w razie błędu W TRAKCIE
  ## kopiowania cofa to, co zdążyło powstać/zostać nadpisane.
  ##
  ## UCZCIWIE: to WCIĄŻ nie jest pełna atomowa podmiana CAŁEGO rootfs
  ## (rename przez granicę systemów plików między /tmp a rootPath zwykle
  ## się nie uda, a scalenie z istniejącą zawartością rootPath z definicji
  ## nie może być JEDNĄ operacją rename) -- ale KAŻDY POJEDYNCZY plik jest
  ## teraz podmieniany atomowo (kopia do pliku tymczasowego W TYM SAMYM
  ## katalogu + `rename(2)` nad docelowym -- v0.2.1), więc proces przerwany
  ## w trakcie merge'a nie zostawia już ucinanych (torn) plików, tylko co
  ## najwyżej brakujące/stare pliki tam, gdzie merge jeszcze nie dotarł
  ## (co rollback -- patrz stagingsafety.nim -- i tak stara się odtworzyć).
  ## Pełna atomowa podmiana CAŁEGO rootfs to zadanie Trybu Atomowego
  ## (overlayfs), patrz README.
  let r = safeMergeStaging(stagingDir, rootPath)
  if not r.ok:
    stderr.writeLine(&"[zpm:own] ✘ Bezpieczny merge stagingu nie powiódł się: {r.error}")
  r.ok

proc installOwnFromSource*(tool: OwnRepoTool, srcDir: string, rootPath: string, cfg: ZpmConfig): int =
  ## Krok 2/2 dla narzędzi typu `git`: uruchamia skrypt instalujący
  ## (domyślnie install.janet) do TYMCZASOWEGO katalogu stagingu (nie
  ## wprost do `rootPath`!), i dopiero po sukcesie kopiuje staging do
  ## `rootPath` (patrz `mergeStagingInto`). Skrypt install.<lang> nie
  ## wymaga żadnej zmiany konwencji -- dalej dostaje ZPM_INSTALL_ROOT/
  ## ZPM_PREFIX i po prostu pisze względem tego, co tam jest (zwyczajnie
  ## trafia to teraz do stagingu zamiast wprost do systemu docelowego).
  let effectiveRoot = if rootPath.len > 0: rootPath else: "/"
  let (refStr, _) = effectiveGitRef(tool, cfg)
  let stagingDir = getTempDir() / &"zpm-install-{tool.name}-{getCurrentProcessId()}"
  removeDir(stagingDir)
  createDir(stagingDir)
  defer: removeDir(stagingDir)

  log(&"[zpm:own] Instaluję '{tool.name}' (root={effectiveRoot}, staging={stagingDir}) przez {tool.installScript} ...")
  let code = runToolScript(tool, srcDir, tool.installScript, tool.installArgs, cfg,
                            [("ZPM_INSTALL_ROOT", stagingDir), ("ZPM_PREFIX", stagingDir),
                             ("ZPM_TOOL_NAME", tool.name), ("ZPM_TOOL_REF", refStr),
                             ("ZPM_TOOL_STAGE", tool.stage)],
                            [stagingDir])
  if code != 0:
    stderr.writeLine(&"[zpm:own] ✘ Instalacja '{tool.name}' nie powiodła się (kod {code}) -- " &
      &"'{effectiveRoot}' pozostaje NIETKNIĘTY (staging {stagingDir} zostanie odrzucony).")
    return code

  if not mergeStagingInto(stagingDir, effectiveRoot):
    stderr.writeLine(&"[zpm:own] ✘ Kopiowanie stagingu do '{effectiveRoot}' nie powiodło się dla '{tool.name}' " &
      "-- system docelowy może być teraz w częściowym stanie (patrz komentarz przy mergeStagingInto).")
    return 1

  log(&"[zpm:own] ✔ '{tool.name}' zainstalowane (root={effectiveRoot}).")
  0

# ---------------------------------------------------------------------------
# Wspólny punkt wejścia dla obu typów narzędzi (`binary` i `git`)
# ---------------------------------------------------------------------------

proc installOwn*(repo: OwnRepository, name: string, cfg: ZpmConfig,
                  binDestDir: string, rootPath: string = "/", force = false, branch: string = ""): int =
  ## `binDestDir` -- gdzie ląduje gotowa binarka dla narzędzi typu `binary`
  ## (np. /usr/local/bin albo <root>/usr/local/bin przy budowaniu obrazu).
  ## `rootPath`   -- korzeń instalacji przekazywany narzędziom typu `git`
  ## (skrypt install.<lang> sam decyduje, gdzie w jego obrębie coś ląduje).
  ## `force`      -- pomija idempotencję (patrz niżej) i wymusza ponowne
  ## build+install/pobranie, nawet jeśli pokwitowanie mówi, że to już jest.
  ## `branch`     -- v0.3: "" = domyślny wariant z own-repository.json;
  ## niepusty = rozwiąż przez `resolveOwnToolBranch` PRZED czymkolwiek innym
  ## (np. "testing", "rolling" -- patrz pole "branches" w schema_version 2).
  ## Pokwitowanie i tak jest zapisywane pod `name` (nie `name@branch`), więc
  ## `zpm own remove kernel` znajduje go niezależnie od tego, jaki branch
  ## posłużył do instalacji -- branch nie jest częścią tożsamości pakietu
  ## w rejestrze stanu, tylko wyborem ŹRÓDŁA w chwili instalacji.
  var tool = repo.findTool(name)
  if tool.name.len == 0:
    log(&"[zpm:own] Narzędzie '{name}' nie występuje w ekosystemie (custom/own-repository.json).")
    return 1

  if branch.len > 0:
    let (branchOk, resolvedTool, branchErr) = resolveOwnToolBranch(tool, branch)
    if not branchOk:
      stderr.writeLine(&"[zpm:own] ✘ {branchErr}")
      return 1
    tool = resolvedTool
    log(&"[zpm:own] '{name}': używam brancha '{branch}'.")

  # Idempotencja: jeśli DOKŁADNIE ten sam commit (git) / suma sha256
  # (binary) jest już, wedle pokwitowania, zainstalowany na TYM SAMYM
  # rootPath -- nic nie rób. To jest to, czego brakowało `installManyOwn`
  # przy każdym `zpm own install kernel` odbudowującym `zpm` jako
  # zależność od zera, nawet gdy już jest zainstalowany.
  if not force:
    let (found, receipt) = loadOwnReceipt(cfg, tool.name, rootPath)
    if found:
      case tool.kind
      of otkGit:
        let (refStr, _) = effectiveGitRef(tool, cfg)
        if receipt.resolvedRef == refStr and refStr.len > 0:
          log(&"[zpm:own] '{tool.name}' już zainstalowane @ {refStr} (root={rootPath}) -- pomijam (użyj --force, żeby wymusić).")
          return 0
      of otkBinary:
        if tool.sha256.len > 0 and receipt.sha256 == tool.sha256:
          log(&"[zpm:own] '{tool.name}' już zainstalowane (sha256 zgodne, root={rootPath}) -- pomijam (użyj --force, żeby wymusić).")
          return 0

  case tool.kind
  of otkBinary:
    let (ok, path) = downloadOwnTool(tool, binDestDir, cfg)
    if not ok: return 1
    let sha = if tool.sha256.len > 0: tool.sha256 else: sha256sumOf(path)
    saveOwnReceipt(cfg, OwnInstallReceipt(
      name: tool.name, resolvedRef: "", sha256: sha, rootPath: rootPath, installedAt: nowIso8601()
    ))
    0
  of otkGit:
    let (ok, srcDir) = buildOwnFromSource(tool, cfg, rootPath)
    if not ok: return 1
    let code = installOwnFromSource(tool, srcDir, rootPath, cfg)
    if code == 0:
      let (refStr, _) = effectiveGitRef(tool, cfg)
      saveOwnReceipt(cfg, OwnInstallReceipt(
        name: tool.name, resolvedRef: refStr, sha256: "", rootPath: rootPath, installedAt: nowIso8601()
      ))
    code

proc removeOwn*(repo: OwnRepository, name: string, cfg: ZpmConfig,
                binDestDir: string, rootPath: string = "/", force = false): int =
  let tool = repo.findTool(name)
  if tool.name.len == 0:
    log(&"[zpm:own] Narzędzie '{name}' nie jest znane ekosystemowi own -- nic do usunięcia.")
    return 1

  # Reverse-dependency check: nie pozwól ukręcić gałęzi, na której inne,
  # FAKTYCZNIE zainstalowane (ma pokwitowanie na tym samym rootPath)
  # narzędzie wciąż stoi -- `zpm own remove zpm` nie powinno cicho popsuć
  # `kernel`, który go deklaruje w `depends_on`.
  if not force:
    var blockers: seq[string] = @[]
    for dependent in directDependents(repo, name):
      if isOwnInstalled(cfg, dependent, rootPath):
        blockers.add dependent
    if blockers.len > 0:
      let blockersStr = blockers.join(", ")
      stderr.writeLine(&"[zpm:own] ✘ Nie usuwam '{name}' -- wymagane przez (zainstalowane): {blockersStr}.")
      stderr.writeLine( "[zpm:own]   Usuń najpierw te narzędzia, albo `zpm own remove --force` żeby wymusić.")
      return 1

  case tool.kind
  of otkBinary:
    let path = binDestDir / tool.name
    if fileExists(path):
      removeFile(path)
      log(&"[zpm:own] ✔ Usunięto {path}.")
    else:
      log(&"[zpm:own] '{tool.name}' nie znajduje się w {binDestDir} -- nic do usunięcia.")
    removeOwnReceipt(cfg, tool.name, rootPath)
    result = 0
  of otkGit:
    if tool.uninstallScript.len == 0:
      stderr.writeLine(&"[zpm:own] ✘ Narzędzie '{tool.name}' (typ git) nie definiuje 'uninstall_script' -- " &
        "automatyczne odinstalowanie nie jest wspierane, usuń ręcznie.")
      return 1
    let cacheDir = toolCacheDir(cfg, tool)
    if not dirExists(cacheDir):
      stderr.writeLine(&"[zpm:own] ✘ Brak lokalnego klonu '{tool.name}' w {cacheDir} -- nie mogę uruchomić {tool.uninstallScript}.")
      return 1
    let effectiveRoot = if rootPath.len > 0: rootPath else: "/"
    result = runToolScript(tool, cacheDir, tool.uninstallScript, @[], cfg,
                  [("ZPM_INSTALL_ROOT", effectiveRoot), ("ZPM_PREFIX", effectiveRoot),
                   ("ZPM_TOOL_NAME", tool.name)], [effectiveRoot])
    if result == 0:
      removeOwnReceipt(cfg, tool.name, rootPath)

# ---------------------------------------------------------------------------
# Instalacja/budowanie WIELU narzędzi naraz z uwzględnieniem `depends_on`
# ---------------------------------------------------------------------------

proc installManyOwn*(repo: OwnRepository, cfg: ZpmConfig, targets: seq[string],
                      binDestDir: string, rootPath: string = "/", force = false,
                      branchFor: Table[string, string] = initTable[string, string]()): bool =
  ## Rozwiązuje graf zależności (deps.nim) dla `targets`, po czym instaluje
  ## KOLEJNO -- zależności zawsze przed tym, co ich potrzebuje. Przerywa na
  ## pierwszym niepowodzeniu (nie ma sensu instalować B, jeśli jego
  ## zależność A się nie zbudowała). `force` pomija idempotencję (patrz
  ## `installOwn`) -- domyślnie WYŁĄCZONE nawet dla `targets`, żeby
  ## `zpm own install kernel` uruchomione drugi raz nie przebudowywało
  ## niepotrzebnie `zpm` jako zależności.
  ##
  ## `branchFor` -- v0.3: mapa nazwa->branch, np. {"kernel": "testing"}, dla
  ## `kernel -> own -> testing`. Stosowana TYLKO do jawnie podanych `targets`
  ## -- zależności DOCIĄGNIĘTE automatycznie (nieobecne w `targets`) zawsze
  ## używają swojego domyślnego brancha, chyba że same są też w tej mapie.
  ## Innymi słowy: branch to wybór dla KONKRETNEGO żądania instalacji, nie
  ## coś, co "spływa" automatycznie na całe drzewo zależności.
  ##
  ## v0.2 -- zamyka lukę "`flock` chroni przed RÓWNOLEGŁYMI procesami, nie
  ## daje transakcyjności między operacjami": `zpm own install A B`, gdzie
  ## A się uda a B nie, TERAZ (domyślnie, `security.rollback_on_failure =
  ## true`) cofa A -- ALE TYLKO jeśli A zostało NOWO zainstalowane w TYM
  ## WYWOŁANIU (jeśli A było już zainstalowane wcześniej i `installOwn` je
  ## pominął przez idempotencję, rollback go nie rusza -- to nie jest
  ## "jego" instalacja do cofnięcia). Rollback jest best-effort: jeśli sam
  ## się nie powiedzie, jest głośno zgłaszany, nie połykany po cichu.
  var order: seq[string]
  try:
    order = resolveBuildOrder(repo, targets)
  except DepsError as e:
    stderr.writeLine(&"[zpm:own] ✘ {e.msg}")
    return false

  if order.len > targets.len:
    let orderStr = order.join(" -> ")
    log(&"[zpm:own] Kolejność instalacji (z zależnościami): {orderStr}")
  var freshlyInstalled: seq[string] = @[]

  proc rollbackFreshlyInstalled() =
    if freshlyInstalled.len == 0 or not cfg.rollbackOnFailure:
      if freshlyInstalled.len > 0:
        stderr.writeLine(&"[zpm:own] Uwaga: security.rollback_on_failure=false -- pozostawiam " &
          &"częściowo zainstalowane: {freshlyInstalled.join(\", \")} (użyj `zpm own remove` ręcznie).")
      return
    stderr.writeLine(&"[zpm:own] Cofam {freshlyInstalled.len} pakiet(y) zainstalowane w tej operacji " &
      "(security.rollback_on_failure=true)...")
    for name in freshlyInstalled.reversed:
      let code = removeOwn(repo, name, cfg, binDestDir, rootPath, force = true)
      if code == 0:
        stderr.writeLine(&"[zpm:own]   ↺ cofnięto '{name}'")
      else:
        stderr.writeLine(&"[zpm:own]   ✘ nie udało się cofnąć '{name}' (kod {code}) -- może wymagać " &
          "ręcznej interwencji (`zpm own remove` / sprawdź `zpm doctor`).")

  for name in order:
    let alreadyInstalled = not force and isOwnInstalled(cfg, name, rootPath)
    let branch = branchFor.getOrDefault(name, "")
    if installOwn(repo, name, cfg, binDestDir, rootPath, force, branch) != 0:
      stderr.writeLine(&"[zpm:own] ✘ Przerywam -- '{name}' nie zainstalowało się poprawnie.")
      rollbackFreshlyInstalled()
      return false
    if not alreadyInstalled:
      freshlyInstalled.add name
  true

proc buildManyOwn*(repo: OwnRepository, cfg: ZpmConfig, target: string,
                    rootPath: string = "/"): tuple[ok: bool, srcDir: string] =
  ## Jak `buildOwnFromSource`, ale najpierw upewnia się, że WSZYSTKIE
  ## zależności `target` są zainstalowane (dla `git` -- zbudowane +
  ## zainstalowane; dla `binary` -- pobrane), a dopiero na końcu buduje
  ## (bez instalowania) sam `target`. Tak realizuje się np. "zbuduj kernel"
  ## zakładając, że `zpm` (jego zależność) musi już działać w systemie.
  var order: seq[string]
  try:
    order = resolveBuildOrder(repo, @[target])
  except DepsError as e:
    stderr.writeLine(&"[zpm:own] ✘ {e.msg}")
    return (false, "")

  let deps = if order.len > 0: order[0 ..< order.high] else: @[]
  if deps.len > 0:
    let depsStr = deps.join(", ")
    log(&"[zpm:own] Zależności '{target}': {depsStr}")
  for depName in deps:
    if installOwn(repo, depName, cfg, cfg.ownToolsInstallDir, rootPath) != 0:
      stderr.writeLine(&"[zpm:own] ✘ Przerywam budowanie '{target}' -- zależność '{depName}' się nie zainstalowała.")
      return (false, "")

  buildOwnFromSource(repo.findTool(target), cfg, rootPath)

proc buildManyOwn*(repo: OwnRepository, cfg: ZpmConfig, targets: seq[string],
                    rootPath: string = "/"): bool =
  ## Wariant `buildManyOwn` dla WIELU celów naraz (np. wszystkich narzędzi
  ## jednego etapu bootstrapu -- patrz `buildStageOwn` niżej). Zależności
  ## spoza `targets` są w pełni instalowane (są traktowane jak prerekwizyt
  ## środowiska), same `targets` -- tylko budowane (`binary` = pobrane,
  ## `git` = zbudowane), bez końcowej instalacji.
  ##
  ## To jest właśnie ten "hak", którego potrzebuje builder (np. zlb) do
  ## realizacji własnego pipeline'u stage0 -> stage1 -> stage2: zpm
  ## dostarcza graf zależności + filtr po etykiecie `stage`, ale to
  ## BUILDER decyduje, w jakiej kolejności odpala poszczególne etapy i
  ## jakim toolchainem (bo to on np. ściąga pierwszy binarny `zpm`, zanim
  ## `zpm` w ogóle zacznie coś robić -- co jest całkowicie w porządku i
  ## poza zakresem tego, co ma robić sam zpm).
  var order: seq[string]
  try:
    order = resolveBuildOrder(repo, targets)
  except DepsError as e:
    stderr.writeLine(&"[zpm:own] ✘ {e.msg}")
    return false

  var targetSet = initHashSet[string]()
  for t in targets: targetSet.incl t

  for name in order:
    let tool = repo.findTool(name)
    if name notin targetSet:
      # zależność JEDNEGO z targets, spoza samego zbioru -- ma być w pełni
      # zainstalowana, bo kolejne budowanie może jej realnie potrzebować
      # (np. kompilatora czy samego zpm) na PATH/w systemie.
      if installOwn(repo, name, cfg, cfg.ownToolsInstallDir, rootPath) != 0:
        stderr.writeLine(&"[zpm:own] ✘ Przerywam -- zależność '{name}' się nie zainstalowała.")
        return false
    else:
      case tool.kind
      of otkGit:
        let (ok, _) = buildOwnFromSource(tool, cfg, rootPath)
        if not ok: return false
      of otkBinary:
        let (ok, _) = downloadOwnTool(tool, cfg.ownToolsInstallDir, cfg)
        if not ok: return false
  true

# ---------------------------------------------------------------------------
# Etapy bootstrapu (`stage`) -- FILTR po etykiecie, nie orkiestracja
# ---------------------------------------------------------------------------
#
# Pełny pipeline stage0 -> stage1 -> stage2 (seed toolchain -> zbuduj Zenit
# tym seedem -> zbuduj Zenit jeszcze raz JUŻ zbudowanym Zenitem) to zadanie
# BUILDERA (np. zlb), nie zpm -- to on decyduje, KIEDY przełączyć się na
# świeżo zbudowany toolchain i jak dostarczyć stage0 (zpm siebie samego
# jeszcze nie ma). Zadaniem zpm jest dać buildowi narzędzia, które na to
# pozwalają:
#   - `stage` jako czysto informacyjna etykieta na każdym narzędziu
#     (own-repository.json), po której można filtrować,
#   - `buildStageOwn`/`installStageOwn` -- "zbuduj/zainstaluj WSZYSTKO co
#     ma tę etykietę, z zależnościami", tak żeby builder nie musiał znać
#     nazw poszczególnych narzędzi, tylko wywołać `zpm own build-stage
#     stage1` per etap,
#   - `verifyReproducibleBuild` -- praktyczny test domykający pętlę
#     ("stage2 buduje stage2 i porównuje wynik" z opisu bootstrapu).

proc toolsForStage*(repo: OwnRepository, stage: string): seq[string] =
  result = @[]
  for t in repo.tools:
    if t.stage == stage: result.add t.name

proc buildStageOwn*(repo: OwnRepository, cfg: ZpmConfig, stage: string, rootPath: string = "/"): bool =
  let targets = toolsForStage(repo, stage)
  if targets.len == 0:
    log(&"[zpm:own] Brak narzędzi z stage='{stage}' w own-repository.json -- nic do zbudowania.")
    return true
  let targetsStr = targets.join(", ")
  log(&"[zpm:own] Etap '{stage}': {targetsStr}")
  buildManyOwn(repo, cfg, targets, rootPath)

proc installStageOwn*(repo: OwnRepository, cfg: ZpmConfig, stage: string,
                       binDestDir: string, rootPath: string = "/"): bool =
  let targets = toolsForStage(repo, stage)
  if targets.len == 0:
    log(&"[zpm:own] Brak narzędzi z stage='{stage}' w own-repository.json -- nic do zainstalowania.")
    return true
  let targetsStr = targets.join(", ")
  log(&"[zpm:own] Etap '{stage}': {targetsStr}")
  installManyOwn(repo, cfg, targets, binDestDir, rootPath)

proc artifactChecksum(dir: string): string =
  ## Jedna suma kontrolna dla CAŁEGO katalogu (posortowana lista sha256
  ## każdego pliku, zhaszowana razem) -- używana do porównania dwóch
  ## niezależnych buildów tego samego narzędzia w `verifyReproducibleBuild`.
  if not dirExists(dir): return ""
  let cmd = &"find \"{dir}\" -type f -not -path '*/.git/*' -print0 | " &
            "sort -z | xargs -0 sha256sum | sha256sum"
  let output = execProcess("sh", args = @["-c", cmd], options = {poUsePath})
  let parts = output.strip().split(' ')
  if parts.len == 0: "" else: parts[0]

proc verifyReproducibleBuild*(tool: OwnRepoTool, cfg: ZpmConfig): tuple[ok: bool, hashA, hashB: string] =
  ## "Dystrybucja je własny ogon": buduje TO SAMO narzędzie DWA razy z tego
  ## samego, niezależnego cache'u źródeł (respektując zpm.lock, jeśli jest
  ## -- inaczej "main" mógłby się przesunąć między buildami i test byłby
  ## bez sensu), do dwóch osobnych katalogów, po czym porównuje sumy
  ## kontrolne wynikowych drzew plików. To jest właśnie praktyczna wersja
  ## testu "stage2 buduje stage2 i porównuje wynik" -- narzędzie, nie cała
  ## orkiestracja (tą zajmuje się builder).
  if tool.kind != otkGit:
    stderr.writeLine(&"[zpm:own] Test reprodukowalności ma sens tylko dla narzędzi typu 'git' ('{tool.name}' to '{tool.kind}').")
    return (false, "", "")

  var cfgA = cfg
  var cfgB = cfg
  cfgA.ownGitCacheDir = getTempDir() / &"zpm-repro-{tool.name}-a"
  cfgB.ownGitCacheDir = getTempDir() / &"zpm-repro-{tool.name}-b"
  removeDir(cfgA.ownGitCacheDir)
  removeDir(cfgB.ownGitCacheDir)
  defer:
    removeDir(cfgA.ownGitCacheDir)
    removeDir(cfgB.ownGitCacheDir)

  log(&"[zpm:own] [reprodukowalność] Build #1 '{tool.name}' ...")
  let (okA, dirA) = buildOwnFromSource(tool, cfgA)
  if not okA: return (false, "", "")
  log(&"[zpm:own] [reprodukowalność] Build #2 '{tool.name}' (niezależny cache) ...")
  let (okB, dirB) = buildOwnFromSource(tool, cfgB)
  if not okB: return (false, "", "")

  let hashA = artifactChecksum(dirA)
  let hashB = artifactChecksum(dirB)
  let matches = hashA.len > 0 and hashA == hashB
  if matches:
    log(&"[zpm:own] ✔ '{tool.name}' jest reprodukowalne: {hashA}")
  else:
    stderr.writeLine(&"[zpm:own] ✘ '{tool.name}' NIE jest reprodukowalne: build#1={hashA} != build#2={hashB}")
  (matches, hashA, hashB)

proc ownToolToJson(t: OwnRepoTool): JsonNode =
  result = newJObject()
  result["name"] = %t.name
  result["type"] = %($t.kind)
  result["info"] = %t.info
  result["depends_on"] = %t.dependsOn
  result["stage"] = %t.stage
  case t.kind
  of otkBinary:
    if t.binByArch.len > 0:
      # v0.4 -- odtwarzamy oryginalny kształt obiektu {arch: url}, nie
      # spłaszczamy z powrotem do samego `bin` (który jest tylko
      # WYLICZONYM wariantem dla hosta -- patrz `parseOwnBin`); w
      # przeciwnym razie merge branchy (patrz `mergeToolBranches` niżej)
      # albo `own list --json` po cichu gubiłyby pozostałe architektury.
      var byArchObj = newJObject()
      for (arch, url) in t.binByArch:
        byArchObj[arch] = %url
      result["bin"] = byArchObj
    else:
      result["bin"] = %t.bin
    result["sha256"] = %t.sha256
  of otkGit:
    result["repo"] = %t.repo
    result["ref"] = %t.gitRef
    result["lang"] = %t.lang
    result["allow_network"] = %t.allowNetwork
    result["signed"] = %t.signed

proc listOwnJson*(repo: OwnRepository): string =
  ## `zpm --json own list` -- dla `zlb` i innych narzędzi, które dziś
  ## muszą parsować format tekstowy `listOwn` (kruche). Ustrukturyzowany
  ## odpowiednik: tablica JSON, jedno-do-jednego z `own-repository.json`.
  var arr = newJArray()
  var tools = repo.tools
  tools.sort(proc(a, b: OwnRepoTool): int = cmp(a.name, b.name))
  for t in tools: arr.add ownToolToJson(t)
  arr.pretty()

proc infoOwnJson*(repo: OwnRepository, name: string): string =
  let t = repo.findTool(name)
  if t.name.len == 0:
    return (%*{"error": &"narzędzie '{name}' nie występuje w custom/own-repository.json"}).pretty()
  var j = ownToolToJson(t)
  var dependents = newJArray()
  for d in directDependents(repo, name): dependents.add %d
  j["dependents"] = dependents
  j.pretty()

proc listOwn*(repo: OwnRepository) =
  if repo.tools.len == 0:
    log("[zpm:own] custom/own-repository.json jest puste lub nie istnieje. Spróbuj `zpm refresh`.")
    return
  log(&"[zpm:own] Narzędzia w ekosystemie Zenit ({repo.tools.len}, schema v{repo.schemaVersion}):")
  var tools = repo.tools
  tools.sort(proc(a, b: OwnRepoTool): int = cmp(a.name, b.name))
  for t in tools:
    case t.kind
    of otkBinary:
      log(&"  - {t.name}  [binary]  <-  {t.bin}")
    of otkGit:
      let stageStr = if t.stage.len > 0: &", stage={t.stage}" else: ""
      log(&"  - {t.name}  [git]     <-  {t.repo} (ref={t.gitRef}, lang={t.lang}{stageStr})")
    if t.dependsOn.len > 0:
      let depsStr = t.dependsOn.join(", ")
      log(&"        zależy od: {depsStr}")
    if t.info.len > 0:
      log(&"        {t.info}")
proc infoOwn*(repo: OwnRepository, name: string) =
  let t = repo.findTool(name)
  if t.name.len == 0:
    log(&"[zpm:own] Narzędzie '{name}' nie występuje w custom/own-repository.json.")
    return
  log(&"[zpm:own] {t.name}")
  log(&"  typ:    {t.kind}")
  if t.info.len > 0: log(&"  opis:   {t.info}")
  if t.dependsOn.len > 0:
    let depsStr = t.dependsOn.join(", ")
    log(&"  zależy: {depsStr}")
  if t.stage.len > 0: log(&"  etap:   {t.stage}")
  case t.kind
  of otkBinary:
    log(&"  bin:    {t.bin}")
    if t.sha256.len > 0: log(&"  sha256: {t.sha256}")
  of otkGit:
    let netStr = if t.allowNetwork: "dozwolona w piaskownicy" else: "zablokowana w piaskownicy"
    let signStr = if t.signed: "wymagany (GPG)" else: "nie wymagany"
    log(&"  repo:   {t.repo}")
    log(&"  ref:    {t.gitRef}")
    log(&"  siec:   {netStr}")
    log(&"  podpis: {signStr}")
    log(&"  lang:   {t.lang}")
    echo &"  build:  {t.buildScript}" & (if t.buildArgs.len > 0: " " & t.buildArgs.join(" ") else: "")
    echo &"  instal: {t.installScript}" & (if t.installArgs.len > 0: " " & t.installArgs.join(" ") else: "")
    if t.uninstallScript.len > 0: log(&"  usuń:   {t.uninstallScript}")
    for depender in directDependents(repo, name):
      log(&"  <- wymagane przez: {depender}")
