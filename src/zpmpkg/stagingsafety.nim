import std/[os, osproc, strformat, strutils, algorithm]
import ./logging

## v0.2 -- zamyka lukę "Sandbox chroni PRZED stagingiem, nie SAM staging".
##
## Piaskownica (`sandboxWrap` w ownrepo.nim) skutecznie ogranicza to, co
## `install.<lang>` może zrobić PODCZAS działania (widzi tylko stagingDir
## jako zapisywalny). Nieuwzględniony pozostawał krok PO: `mergeStagingInto`
## kopiujący staging do `rootPath` UŻYWAJĄC PEŁNYCH UPRAWNIEŃ procesu zpm
## (poza piaskownicą), gdzie złośliwy `install.<lang>` mógł zostawić w
## stagingu symlinki mające przy scaleniu:
##   a) wyjść POZA staging (dangling/absolute symlink) -- nieszkodliwe samo
##      w sobie, ALE jeśli coś później zapisze PRZEZ taki symlink (kolejna
##      instalacja, inny proces), skończy się to zapisem poza `rootPath`,
##   b) podmienić PRZEZ ISTNIEJĄCY W ROOTPATH symlink (np. z poprzedniej,
##      też złośliwej instalacji) -- `cp -a`, kopiując rekurencyjnie,
##      podąża za symlinkiem OBECNYM W DESTYNACJI przy wchodzeniu w
##      podkatalogi, więc zawartość może wylądować gdzie indziej niż widać.
##
## Ten moduł dodaje DWIE niezależne warstwy:
##   1. `validateStagingTree` -- odrzuca CAŁY merge, jeśli staging zawiera
##      jakikolwiek symlink (bezwzględna reguła w v0.2: install.<lang> nie
##      ma uzasadnionego powodu, żeby w OGÓLE tworzyć symlinki w miejscu,
##      które i tak zostanie dosłownie skopiowane -- jeśli okaże się to
##      zbyt restrykcyjne dla realnych narzędzi, wyjątek trzeba będzie
##      jawnie wypisać w own-repository.json per-narzędzie, NIE domyślnie
##      zezwalać).
##   2. `safeMergeStaging` -- kopiuje plik-po-pliku zamiast `cp -a` na
##      całym drzewie, sprawdzając PRZED KAŻDYM zapisem, czy którykolwiek
##      z katalogów nadrzędnych w `rootPath` jest symlinkiem (odrzuca, jeśli
##      tak -- nigdy nie "podąża" przez istniejący symlink w destynacji).
##      Robi backup NADPISYWANYCH plików do katalogu swap i w razie
##      niepowodzenia W TRAKCIE kopiowania: usuwa nowo utworzone wpisy i
##      przywraca nadpisane z backupu (lepsza, choć wciąż nie w 100%
##      idealna, atomowość -- pełna atomowa podmiana to zadanie Trybu
##      Atomowego / overlayfs, patrz README).

type
  StagingValidationError* = object of CatchableError
  MergeResult* = object
    ok*: bool
    createdPaths*: seq[string]   ## nowe pliki/katalogi utworzone w rootPath (do cofnięcia)
    backedUpPaths*: seq[tuple[dest, backup: string]]  ## pliki nadpisane (do przywrócenia)
    error*: string

proc validateStagingTree*(stagingDir: string): tuple[ok: bool, reason: string] =
  ## Odrzuca staging zawierający JAKIKOLWIEK symlink. Celowo zero-tolerancji
  ## w v0.2 -- prostsza, audytowalna reguła niż próba klasyfikacji "które
  ## symlinki są bezpieczne".
  if not dirExists(stagingDir):
    return (true, "")
  for path in walkDirRec(stagingDir, {pcLinkToFile, pcLinkToDir}, relative = true):
    return (false, &"staging zawiera symlink '{path}' -- odrzucone (v0.2: install.<lang> nie może " &
                    "tworzyć symlinków w katalogu stagingu, patrz stagingsafety.nim)")
  (true, "")

proc anyAncestorIsSymlink(rootPath, relPath: string): tuple[bad: bool, at: string] =
  ## Sprawdza, czy JAKIKOLWIEK katalog nadrzędny `relPath` w `rootPath`
  ## (już istniejący na dysku) jest symlinkiem -- jeśli tak, zapis "przez"
  ## niego mógłby wylądować poza `rootPath`, więc odmawiamy.
  var acc = rootPath
  for part in relPath.parentDir.split(DirSep):
    if part.len == 0: continue
    acc = acc / part
    if fileExists(acc) or dirExists(acc):
      if symlinkExists(acc):
        return (true, acc)
  (false, "")

proc freeBytes(path: string): BiggestInt =
  ## `statvfs` przez `df -Pk` (przenośne, bez FFI) -- ile wolnego miejsca
  ## (w bajtach) zostało na systemie plików zawierającym `path`.
  var dir = path
  while not dirExists(dir) and dir.len > 1:
    dir = parentDir(dir)
  if dir.len == 0: dir = "/"
  let (output, code) = execCmdEx(&"df -Pk \"{dir}\" | tail -1 | awk '{{print $4}}'")
  if code != 0: return -1  # nieznane -- wołający traktuje jako "nie sprawdzaj"
  try:
    return parseBiggestInt(output.strip()) * 1024
  except ValueError:
    return -1

proc dirSizeBytes(path: string): BiggestInt =
  if not dirExists(path): return 0
  let (output, code) = execCmdEx(&"du -sk \"{path}\" | awk '{{print $1}}'")
  if code != 0: return -1
  try:
    return parseBiggestInt(output.strip()) * 1024
  except ValueError:
    return -1

proc checkDiskSpace*(stagingDir, rootPath: string): tuple[ok: bool, reason: string] =
  ## Pre-flight: odmawia ROZPOCZĘCIA merge'a, jeśli wolne miejsce na
  ## docelowym systemie plików jest WYRAŹNIE mniejsze niż rozmiar stagingu
  ## (z 10% marginesem). Nie eliminuje ryzyka "dysk się zapełnił w
  ## połowie" (inny proces może w międzyczasie zająć miejsce), ale zamyka
  ## najczęstszy, w pełni przewidywalny przypadek.
  let need = dirSizeBytes(stagingDir)
  let free = freeBytes(rootPath)
  if need < 0 or free < 0:
    logVerbose("[zpm:staging] Nie udało się wyliczyć miejsca na dysku (df/du niedostępne?) -- pomijam pre-check.")
    return (true, "")
  let margin = need div 10  # +10%
  if free < need + margin:
    return (false, &"za mało miejsca na dysku w {rootPath}: potrzeba ~{need + margin} B, dostępne {free} B")
  (true, "")

proc safeMergeStaging*(stagingDir, rootPath: string): MergeResult =
  ## Zastępuje dawne `cp -a "$stagingDir/." "$rootPath/"` bezpiecznym
  ## kopiowaniem plik-po-pliku z rejestrowaniem tego, co zrobiono (do
  ## ewentualnego cofnięcia) i sprawdzaniem symlinków w DESTYNACJI przed
  ## każdym zapisem.
  var acc = MergeResult(ok: true, createdPaths: @[], backedUpPaths: @[], error: "")

  let (validOk, validReason) = validateStagingTree(stagingDir)
  if not validOk:
    return MergeResult(ok: false, error: validReason)

  let (spaceOk, spaceReason) = checkDiskSpace(stagingDir, rootPath)
  if not spaceOk:
    return MergeResult(ok: false, error: spaceReason)

  createDir(rootPath)
  let swapDir = getTempDir() / &"zpm-merge-backup-{getCurrentProcessId()}"
  createDir(swapDir)

  proc rollback(acc: MergeResult) =
    logWarn("[zpm:staging] Cofam częściowy merge...")
    for (dest, backup) in acc.backedUpPaths:
      try:
        copyFile(backup, dest)
      except CatchableError as e:
        logWarn(&"[zpm:staging]   ! nie udało się przywrócić {dest}: {e.msg}")
    # Usuń nowe wpisy w odwrotnej kolejności (pliki przed katalogami).
    for p in acc.createdPaths.reversed():
      try:
        if dirExists(p) and not symlinkExists(p): removeDir(p)
        elif fileExists(p) or symlinkExists(p): removeFile(p)
      except CatchableError:
        discard
    removeDir(swapDir)

  if not dirExists(stagingDir):
    removeDir(swapDir)
    return MergeResult(ok: true, createdPaths: @[], backedUpPaths: @[], error: "")

  try:
    for relPath in walkDirRec(stagingDir, {pcFile, pcDir}, relative = true):
      let src = stagingDir / relPath
      let dst = rootPath / relPath

      let (badAncestor, badAt) = anyAncestorIsSymlink(rootPath, relPath)
      if badAncestor:
        acc = MergeResult(ok: false, createdPaths: acc.createdPaths,
                           backedUpPaths: acc.backedUpPaths,
                           error: &"odmawiam zapisu przez istniejący symlink w destynacji: {badAt}")
        rollback(acc)
        return acc

      if dirExists(src):
        if not dirExists(dst) and not symlinkExists(dst):
          createDir(dst)
          acc.createdPaths.add dst
        continue

      # plik zwykły
      if fileExists(dst) or symlinkExists(dst):
        let backup = swapDir / (relPath.replace(DirSep, '_') & &"-{acc.backedUpPaths.len}")
        try:
          copyFile(dst, backup)
          acc.backedUpPaths.add (dst, backup)
        except CatchableError:
          discard  # brak możliwości backupu -- kontynuuj, ale bez gwarancji cofnięcia TEGO pliku
      else:
        acc.createdPaths.add dst
      createDir(parentDir(dst))
      # v0.2.1: kopiuj do pliku tymczasowego W TYM SAMYM katalogu co `dst`,
      # a dopiero na końcu `moveFile` (rename(2) na tym samym systemie
      # plików -- atomowe) NAD `dst`. To NIE rozwiązuje atomowości całego
      # merge'a (to wciąż wiele operacji, nie jedna transakcja), ALE
      # gwarantuje, że KAŻDY POJEDYNCZY plik przechodzi ze stanu
      # "stary/nieobecny" w "nowy" atomowo -- proces przerwany w połowie
      # kopiowania NIGDY nie zostawia ucinanego (torn) pliku pod `dst`,
      # co był realny problem przy poprzednim `copyFile(src, dst)` wprost.
      let tmpDst = dst & &".zpm-tmp-{getCurrentProcessId()}"
      copyFile(src, tmpDst)
      when defined(posix):
        try:
          setFilePermissions(tmpDst, getFilePermissions(src))
        except CatchableError:
          discard
      moveFile(tmpDst, dst)
  except CatchableError as e:
    acc = MergeResult(ok: false, createdPaths: acc.createdPaths,
                       backedUpPaths: acc.backedUpPaths,
                       error: &"błąd podczas kopiowania: {e.msg}")
    rollback(acc)
    return acc

  removeDir(swapDir)
  acc.ok = true
  acc
