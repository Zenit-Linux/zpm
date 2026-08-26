import std/[strutils]
import ./common
import ../types

const kind = bkApt

proc isPresent*(): bool = backendAvailable("apt-cache") or backendAvailable("apt")

proc search*(query: string): seq[PackageCandidate] =
  result = @[]
  if not isPresent(): return
  let (output, code) = runCapture("apt-cache", @["search", "--names-only", query])
  if code != 0: return
  for line in output.splitLines():
    if line.len == 0: continue
    let parts = line.split(" - ", maxsplit = 1)
    let name = parts[0].strip()
    let desc = if parts.len > 1: parts[1].strip() else: ""
    if name.len == 0: continue
    result.add(PackageCandidate(
      name: name, version: "", description: desc, backend: kind,
      installCmd: @["sudo", "apt", "install", "-y", name], extra: "apt"
    ))

proc install*(name: string): int =
  runInteractive("sudo", @["apt", "install", "-y", name])

proc remove*(name: string): int =
  runInteractive("sudo", @["apt", "remove", "-y", name])

proc isInstalled*(name: string): bool =
  ## v0.2 -- dla `zpm doctor`: sprawdza REALNY stan pakietu na dysku
  ## (dpkg -s), a nie tylko "czy zpm ma o nim wpis w bazie".
  if not isPresent(): return false
  let (output, code) = runCapture("dpkg-query", @["-W", "-f=${Status}", name])
  code == 0 and "install ok installed" in output

proc updateAll*(): int =
  discard runInteractive("sudo", @["apt", "update"])
  runInteractive("sudo", @["apt", "upgrade", "-y"])

proc cleanup*(): int =
  discard runInteractive("sudo", @["apt", "autoremove", "-y"])
  runInteractive("sudo", @["apt", "autoclean"])
