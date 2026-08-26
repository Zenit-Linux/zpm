import std/[strutils]
import ./common
import ../types

const kind = bkDnf

proc isPresent*(): bool = backendAvailable("dnf")

proc search*(query: string): seq[PackageCandidate] =
  result = @[]
  if not isPresent(): return
  let (output, code) = runCapture("dnf", @["search", query])
  if code != 0: return
  for line in output.splitLines():
    if line.len == 0 or line.startsWith("=") or not (':' in line): continue
    let parts = line.split(" : ", maxsplit = 1)
    if parts.len < 2: continue
    let namePart = parts[0].strip()
    let name = namePart.split('.')[0]  # usuń sufiks .arch
    result.add(PackageCandidate(
      name: name, version: "", description: parts[1].strip(), backend: kind,
      installCmd: @["sudo", "dnf", "install", "-y", name], extra: "dnf"
    ))

proc isInstalled*(name: string): bool =
  if not isPresent(): return false
  let (_, code) = runCapture("rpm", @["-q", name])
  code == 0

proc install*(name: string): int =
  runInteractive("sudo", @["dnf", "install", "-y", name])

proc remove*(name: string): int =
  runInteractive("sudo", @["dnf", "remove", "-y", name])

proc updateAll*(): int =
  runInteractive("sudo", @["dnf", "upgrade", "--refresh", "-y"])

proc cleanup*(): int =
  runInteractive("sudo", @["dnf", "autoremove", "-y"])
