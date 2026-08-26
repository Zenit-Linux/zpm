import std/[os, posix, strformat]

## Ochrona przed DWOMA RÓWNOLEGŁYMI procesami zpm bijącymi się o ten sam
## zasób (typowe w CI, gdzie kilka jobów buildera może wystartować
## naraz) -- `deps.nim`/`installManyOwn` gwarantują poprawną kolejność
## TYLKO w obrębie jednego procesu; to tutaj chroni przed drugim procesem.
##
## Celowo prosta blokada plikowa przez `flock(2)` (LOCK_EX), nie pełny
## menedżer transakcji -- wystarcza do "jeden zpm naraz dotyka tego
## katalogu/pliku", co jest realnym zagrożeniem tu opisanym.
##
## `flock(2)`/`LOCK_*` to rozszerzenie BSD (sys/file.h), NIE część
## podstawowego POSIX -- `std/posix` go nie gwarantuje, więc deklarujemy
## FFI do niego jawnie tutaj zamiast liczyć na to, że akurat jest
## wystawiony przez `std/posix` na danej wersji Nim/libc.
proc c_flock(fd: cint, operation: cint): cint {.importc: "flock", header: "<sys/file.h>".}
const
  # UWAGA: Nim nie pozwala na identyfikatory kończące się podkreślnikiem
  # ("invalid token: trailing underscore") -- stąd sufiks "C", nie "_".
  LOCK_EX_C = 2.cint
  LOCK_NB_C = 4.cint
  LOCK_UN_C = 8.cint

type
  FileLock* = object
    fd: cint
    path*: string

  LockTimeoutError* = object of CatchableError

proc acquireLock*(resourcePath: string, timeoutSec: int = 120): FileLock =
  ## Blokuje na `resourcePath & ".lock"` (LOCK_EX, blokujące odpytywanie
  ## co 200ms aż do `timeoutSec`). Rzuca `LockTimeoutError` z czytelnym
  ## komunikatem zamiast wisieć w nieskończoność, gdy inny proces zpm
  ## trzyma blokadę dłużej niż rozsądnie można się spodziewać.
  let lockPath = resourcePath & ".lock"
  let dir = parentDir(lockPath)
  if dir.len > 0: createDir(dir)

  let fd = posix.open(lockPath.cstring, O_CREAT or O_RDWR, 0o644)
  if fd < 0:
    raise newException(IOError, &"[zpm:lock] nie można otworzyć pliku blokady {lockPath}")

  var waited = 0.0
  while c_flock(fd, LOCK_EX_C or LOCK_NB_C) != 0:
    if waited >= timeoutSec.float:
      discard posix.close(fd)
      raise newException(LockTimeoutError,
        &"[zpm:lock] blokada {lockPath} zajęta dłużej niż {timeoutSec}s -- czy inny proces " &
        "zpm (być może zawieszony) wciąż nad tym pracuje? Usuń plik ręcznie, jeśli jesteś " &
        "pewien, że nie ma aktywnego procesu.")
    sleep(200)
    waited += 0.2

  FileLock(fd: fd, path: lockPath)

proc release*(lock: FileLock) =
  discard c_flock(lock.fd, LOCK_UN_C)
  discard posix.close(lock.fd)

template withLock*(resourcePath: string, timeoutSec: int, body: untyped): untyped =
  ## `withLock(cfg.dbPath, cfg.lockTimeoutSec): ... praca na zasobie ...`
  ## -- gwarantuje release() nawet gdy `body` rzuci wyjątek.
  block:
    let zpmFileLockHandle = acquireLock(resourcePath, timeoutSec)
    try:
      body
    finally:
      release(zpmFileLockHandle)
