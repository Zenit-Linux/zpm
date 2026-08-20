import std/[strutils]
import ./common
import ../types

const kind = bkFlatpak

proc isPresent*(): bool = backendAvailable("flatpak")

proc search*(query: string): seq[PackageCandidate] =
  result = @[]
  if not isPresent(): return
  let (output, code) = runCapture("flatpak", @["search", query])
  if code != 0: return
  for line in output.splitLines():
    if line.len == 0 or line.startsWith("Name"): continue
    let cols = line.split('\t')
    if cols.len < 3: continue
    let appId = cols[2].strip()
    result.add(PackageCandidate(
      name: appId, version: (if cols.len > 3: cols[3] else: ""),
      description: cols[1].strip(), backend: kind,
      installCmd: @["flatpak", "install", "-y", "flathub", appId], extra: "flatpak"
    ))

proc install*(appId: string): int =
  runInteractive("flatpak", @["install", "-y", "flathub", appId])

proc remove*(appId: string): int =
  runInteractive("flatpak", @["uninstall", "-y", appId])

proc updateAll*(): int =
  runInteractive("flatpak", @["update", "-y"])

proc cleanup*(): int =
  runInteractive("flatpak", @["uninstall", "--unused", "-y"])
