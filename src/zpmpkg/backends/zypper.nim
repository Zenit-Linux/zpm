import std/[strutils]
import ./common
import ../types

const kind = bkZypper

proc isPresent*(): bool = backendAvailable("zypper")

proc search*(query: string): seq[PackageCandidate] =
  result = @[]
  if not isPresent(): return
  let (output, code) = runCapture("zypper", @["--non-interactive", "search", query])
  if code != 0: return
  for line in output.splitLines():
    if not ('|' in line): continue
    let cols = line.split('|')
    if cols.len < 3: continue
    let name = cols[1].strip()
    if name.len == 0 or name == "Name": continue
    result.add(PackageCandidate(
      name: name, version: "", description: cols[2].strip(), backend: kind,
      installCmd: @["sudo", "zypper", "install", "-y", name], extra: "zypper"
    ))

proc isInstalled*(name: string): bool =
  if not isPresent(): return false
  let (_, code) = runCapture("rpm", @["-q", name])
  code == 0

proc install*(name: string): int =
  runInteractive("sudo", @["zypper", "install", "-y", name])

proc remove*(name: string): int =
  runInteractive("sudo", @["zypper", "remove", "-y", name])

proc updateAll*(): int =
  runInteractive("sudo", @["zypper", "update", "-y"])

proc cleanup*(): int =
  runInteractive("sudo", @["zypper", "clean", "--all"])
