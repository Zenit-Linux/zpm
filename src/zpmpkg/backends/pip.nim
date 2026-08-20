import ./common
import ../types

const kind = bkPip

proc isPresent*(): bool = backendAvailable("pip") or backendAvailable("pip3")

proc pipBin(): string =
  if backendAvailable("pip3"): "pip3" else: "pip"

proc search*(query: string): seq[PackageCandidate] =
  result = @[]
  if not isPresent(): return
  # Brak działającego pip search — dajemy jednego kandydata "best guess".
  result.add(PackageCandidate(
    name: query, version: "", description: "(PyPI — wyszukiwarka wyłączona przez upstream, instalacja spróbuje bezpośrednio)",
    backend: kind, installCmd: @[pipBin(), "install", "--user", query],
    extra: "pip --user"
  ))

proc install*(name: string): int =
  runInteractive(pipBin(), @["install", "--user", name])

proc remove*(name: string): int =
  runInteractive(pipBin(), @["uninstall", "-y", name])

proc updateAll*(): int = 0
proc cleanup*(): int = 0
