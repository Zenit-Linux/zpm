import std/[json, strutils]
import ./common
import ../types

const kind = bkNpm

proc isPresent*(): bool = backendAvailable("npm")

proc search*(query: string): seq[PackageCandidate] =
  result = @[]
  if not isPresent(): return
  let (output, code) = runCapture("npm", @["search", query, "--json"])
  if code != 0: return
  try:
    let data = parseJson(output)
    for item in data:
      let name = item{"name"}.getStr("")
      if name.len == 0: continue
      result.add(PackageCandidate(
        name: name, version: item{"version"}.getStr(""),
        description: item{"description"}.getStr(""), backend: kind,
        installCmd: @["sudo", "npm", "install", "-g", name], extra: "npm -g"
      ))
  except JsonParsingError:
    discard  # brak wyników / npm nie zwrócił poprawnego JSON

proc install*(name: string): int =
  runInteractive("sudo", @["npm", "install", "-g", name])

proc remove*(name: string): int =
  runInteractive("sudo", @["npm", "uninstall", "-g", name])

proc updateAll*(): int =
  runInteractive("sudo", @["npm", "update", "-g"])

proc cleanup*(): int = 0
