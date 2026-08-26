import std/[strutils, os]
import ./common
import ../types
import ../logging

## brew.nim -- backend Homebrew/Linuxbrew.
##
## Na Linuksie brew żyje zwykle w /home/linuxbrew/.linuxbrew/bin/brew albo
## ~/.linuxbrew/bin/brew i nie zawsze trafia na PATH ustawiony przez zpm
## (np. w minimalnym rootfsie budowanym przez `zlb`), więc szukamy też
## po tych typowych lokalizacjach zanim uznamy backend za nieobecny.

const kind = bkBrew

const wellKnownBrewPaths = [
  "/home/linuxbrew/.linuxbrew/bin/brew",
  "/opt/homebrew/bin/brew",
  "/usr/local/bin/brew"
]

proc brewBin(): string =
  let onPath = findExe("brew")
  if onPath.len > 0: return onPath
  for c in wellKnownBrewPaths:
    if fileExists(c): return c
  let home = getHomeDir()
  let userLocal = home / ".linuxbrew" / "bin" / "brew"
  if fileExists(userLocal): return userLocal
  ""

proc isPresent*(): bool = brewBin().len > 0

proc search*(query: string): seq[PackageCandidate] =
  result = @[]
  let bin = brewBin()
  if bin.len == 0: return
  let (output, code) = runCapture(bin, @["search", query])
  if code != 0: return
  for line in output.splitLines():
    let name = line.strip()
    if name.len == 0: continue
    if name.startsWith("==>"): continue   # nagłówki sekcji ("==> Formulae" itd.)
    result.add(PackageCandidate(
      name: name, version: "", description: "Homebrew/Linuxbrew formula", backend: kind,
      installCmd: @[bin, "install", name], extra: "brew"
    ))

proc isInstalled*(name: string): bool =
  let bin = brewBin()
  if bin.len == 0: return false
  let (_, code) = runCapture(bin, @["list", "--versions", name])
  code == 0

proc install*(name: string): int =
  let bin = brewBin()
  if bin.len == 0:
    log("[zpm] Brew nie znaleziony (ani na PATH, ani w typowych lokalizacjach) — pomijam.")
    return 127
  runInteractive(bin, @["install", name])

proc remove*(name: string): int =
  let bin = brewBin()
  if bin.len == 0: return 127
  runInteractive(bin, @["uninstall", name])

proc updateAll*(): int =
  let bin = brewBin()
  if bin.len == 0: return 127
  discard runInteractive(bin, @["update"])
  runInteractive(bin, @["upgrade"])

proc cleanup*(): int =
  let bin = brewBin()
  if bin.len == 0: return 0
  runInteractive(bin, @["cleanup", "-s"])
