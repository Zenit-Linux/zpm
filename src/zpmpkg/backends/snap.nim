import std/[strutils]
import ./common
import ../types

const kind = bkSnap

proc isPresent*(): bool = backendAvailable("snap")

proc search*(query: string): seq[PackageCandidate] =
  result = @[]
  if not isPresent(): return
  let (output, code) = runCapture("snap", @["find", query])
  if code != 0: return
  var first = true
  for line in output.splitLines():
    if first: (first = false; continue)  # pomiń nagłówek tabeli
    if line.len == 0: continue
    let cols = line.splitWhitespace()
    if cols.len < 1: continue
    let name = cols[0]
    let version = if cols.len > 1: cols[1] else: ""
    let desc = if cols.len > 4: cols[4 .. ^1].join(" ") else: ""
    result.add(PackageCandidate(
      name: name, version: version, description: desc, backend: kind,
      installCmd: @["sudo", "snap", "install", name], extra: "snap"
    ))

proc install*(name: string): int =
  runInteractive("sudo", @["snap", "install", name])

proc remove*(name: string): int =
  runInteractive("sudo", @["snap", "remove", name])

proc updateAll*(): int =
  runInteractive("sudo", @["snap", "refresh"])

proc cleanup*(): int =
  # Snap sam czyści stare wersje; nic dodatkowego nie trzeba robić.
  0
