import std/[strutils, os]
import ./common
import ../types

const kind = bkCargo

proc isPresent*(): bool = backendAvailable("cargo")

proc search*(query: string): seq[PackageCandidate] =
  result = @[]
  if not isPresent(): return
  let (output, code) = runCapture("cargo", @["search", query, "--limit", "10"])
  if code != 0: return
  for line in output.splitLines():
    if line.len == 0 or not ('=' in line): continue
    let parts = line.split('=', maxsplit = 1)
    let name = parts[0].strip()
    var desc = ""
    let hashIdx = line.find('#')
    if hashIdx >= 0: desc = line[hashIdx+1 .. ^1].strip()
    result.add(PackageCandidate(
      name: name, version: "", description: desc, backend: kind,
      installCmd: @["cargo", "install", name], extra: "cargo (binarka trafia do ~/.cargo/bin)"
    ))

proc isInstalled*(name: string): bool =
  if not isPresent(): return false
  let (_, code) = runCapture("cargo", @["install", "--list"])
  # `cargo install --list` nie ma trybu zapytania per-pakiet -- sprawdzamy obecność
  # binarki o tej nazwie w ~/.cargo/bin jako praktyczne przybliżenie.
  discard code
  fileExists(getHomeDir() / ".cargo" / "bin" / name)

proc install*(name: string): int =
  runInteractive("cargo", @["install", name])

proc remove*(name: string): int =
  runInteractive("cargo", @["uninstall", name])

proc updateAll*(): int =
  # cargo nie ma natywnego "update all" bez cargo-update; traktujemy jako no-op
  0

proc cleanup*(): int = 0
