import std/[osproc, strutils, os, streams]
import ../types

proc backendAvailable*(binName: string): bool =
  ## Sprawdza, czy dana komenda istnieje w PATH hosta.
  findExe(binName).len > 0

proc runCapture*(cmd: string, args: seq[string]): tuple[output: string, code: int] =
  let p = startProcess(cmd, args = args, options = {poUsePath, poStdErrToStdOut})
  let outp = streams.readAll(p.outputStream)
  let code = p.waitForExit()
  p.close()
  (outp, code)

proc runInteractive*(cmd: string, args: seq[string]): int =
  ## Uruchamia proces z dziedziczonym stdin/stdout/stderr — używane dla
  ## realnej instalacji (sudo apt install, itd.), żeby użytkownik widział
  ## pasek postępu i mógł odpowiadać na pytania [T/n].
  if findExe(cmd).len == 0:
    echo "[zpm] Brak polecenia '" & cmd & "' w PATH — pomijam tę operację."
    return 127
  let p = startProcess(cmd, args = args,
                        options = {poUsePath, poParentStreams})
  result = p.waitForExit()
  p.close()
