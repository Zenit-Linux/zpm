import std/[json, os, osproc, strutils, strformat, httpclient, algorithm]
import ./types

const DefaultOwnRepoPath* = "/etc/zpm/custom/own-repository.json"

proc emptyOwnRepository*(): OwnRepository = OwnRepository(tools: @[])

proc loadOwnRepository*(path: string): OwnRepository =
  ## Wczytuje custom/own-repository.json. Pusty/brakujący plik zwraca
  ## pustą listę narzędzi zamiast wywalać cały zpm -- backend `own`
  ## wtedy po prostu nie znajduje żadnych kandydatów.
  result = emptyOwnRepository()
  if not fileExists(path):
    return
  let raw = readFile(path).strip()
  if raw.len == 0:
    return
  var data: JsonNode
  try:
    data = parseJson(raw)
  except JsonParsingError:
    stderr.writeLine(&"[zpm:own] Ostrzeżenie: nie udało się sparsować {path}, ignoruję.")
    return
  if data.kind != JObject or not data.hasKey("tools"):
    return
  for item in data["tools"]:
    let name = item{"name"}.getStr("")
    let bin = item{"bin"}.getStr("")
    if name.len == 0 or bin.len == 0: continue
    result.tools.add OwnRepoTool(
      name: name,
      bin: bin,
      sha256: item{"sha256"}.getStr("")
    )

proc findTool*(repo: OwnRepository, name: string): OwnRepoTool =
  for t in repo.tools:
    if t.name == name: return t
  OwnRepoTool(name: "", bin: "")

proc searchOwn*(repo: OwnRepository, query: string): seq[PackageCandidate] =
  result = @[]
  let q = query.toLowerAscii
  for t in repo.tools:
    if t.name.toLowerAscii.contains(q):
      result.add PackageCandidate(
        name: t.name, version: "", description: "narzędzie z ekosystemu Zenith (own): " & t.bin,
        backend: bkOwn, installCmd: @[], extra: t.bin
      )

proc sha256sumOf(path: string): string =
  ## Bez zależności krypto -- deleguje do sha256sum, tak jak reszta zpm/zlb.
  let sha = execProcess("sha256sum", args = @[path], options = {poUsePath})
  if sha.len == 0: return ""
  sha.split(' ')[0].strip()

proc downloadOwnTool*(tool: OwnRepoTool, destDir: string): tuple[ok: bool, path: string] =
  ## Pobiera binarkę narzędzia z jego dosłownego URL-a wprost przez
  ## std/httpclient (a więc bez uruchamiania zewnętrznego `curl`/`wget`),
  ## zapisuje do destDir/<name>, ustawia +x i (jeśli podano) weryfikuje sha256.
  if tool.bin.len == 0:
    return (false, "")
  createDir(destDir)
  let dest = destDir / tool.name
  echo &"[zpm:own] Pobieram '{tool.name}' z {tool.bin} ..."
  try:
    var client = newHttpClient(timeout = 60_000)
    defer: client.close()
    client.downloadFile(tool.bin, dest)
  except CatchableError as e:
    stderr.writeLine(&"[zpm:own] ✘ Pobieranie '{tool.name}' nie powiodło się: {e.msg}")
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

  echo &"[zpm:own] ✔ '{tool.name}' zainstalowane w {dest}"
  (true, dest)

proc installOwn*(repo: OwnRepository, name, destDir: string): int =
  let tool = repo.findTool(name)
  if tool.name.len == 0:
    echo &"[zpm:own] Narzędzie '{name}' nie występuje w ekosystemie (custom/own-repository.json)."
    return 1
  let (ok, _) = downloadOwnTool(tool, destDir)
  if ok: 0 else: 1

proc listOwn*(repo: OwnRepository) =
  if repo.tools.len == 0:
    echo "[zpm:own] custom/own-repository.json jest puste lub nie istnieje."
    return
  echo &"[zpm:own] Narzędzia w ekosystemie Zenith ({repo.tools.len}):"
  var names: seq[string] = @[]
  for t in repo.tools: names.add t.name
  names.sort(cmp[string])
  for t in repo.tools:
    echo &"  - {t.name}  <-  {t.bin}"
