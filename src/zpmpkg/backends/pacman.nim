import std/[strutils]
import ./common
import ../types

const kind = bkPacman

proc isPresent*(): bool = backendAvailable("pacman")

proc search*(query: string): seq[PackageCandidate] =
  result = @[]
  if not isPresent(): return
  let (output, code) = runCapture("pacman", @["-Ss", query])
  if code != 0: return
  let lines = output.splitLines()
  var i = 0
  while i < lines.len:
    let line = lines[i]
    if line.len > 0 and not line.startsWith(" "):
      # linia "repo/nazwa wersja"
      let head = line.split(' ')
      if head.len >= 1:
        let full = head[0]
        let name = if '/' in full: full.split('/')[1] else: full
        var desc = ""
        if i + 1 < lines.len and lines[i+1].startsWith(" "):
          desc = lines[i+1].strip()
          i.inc
        result.add(PackageCandidate(
          name: name, version: (if head.len > 1: head[1] else: ""),
          description: desc, backend: kind,
          installCmd: @["sudo", "pacman", "-S", "--noconfirm", name], extra: "pacman"
        ))
    i.inc

proc install*(name: string): int =
  runInteractive("sudo", @["pacman", "-S", "--noconfirm", name])

proc remove*(name: string): int =
  runInteractive("sudo", @["pacman", "-R", "--noconfirm", name])

proc updateAll*(): int =
  runInteractive("sudo", @["pacman", "-Syu", "--noconfirm"])

proc cleanup*(): int =
  runInteractive("sudo", @["pacman", "-Sc", "--noconfirm"])
