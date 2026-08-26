import std/[tables, sets, strutils, strformat]
import ./types

## Graf zależności między narzędziami ekosystemu `own` (pole `depends_on`
## w own-repository.json). Odpowiada za dwie rzeczy:
##
##  1. Policzenie KOLEJNOŚCI budowania/instalacji dla zbioru celów --
##     zależności zawsze przed zależnymi od nich (sortowanie topologiczne,
##     DFS + stos wyjścia).
##  2. Wykrycie cykli (A zależy od B, B zależy od A) -- to jest błąd
##     konfiguracji own-repository.json, a NIE coś, co zpm ma prawo
##     "rozwiązać" samo. Modelowanie wieloetapowego bootstrapu (stage0/
##     stage1/stage2, gdzie cykle są rozrywane etapami) to zadanie
##     buildera (zlb), nie zpm -- `stage` w OwnRepoTool jest tu wyłącznie
##     informacyjną etykietą przekazywaną dalej, zpm jej nie interpretuje.

type
  DepsError* = object of CatchableError

proc buildIndex(repo: OwnRepository): Table[string, OwnRepoTool] =
  result = initTable[string, OwnRepoTool]()
  for t in repo.tools:
    result[t.name] = t

proc resolveBuildOrder*(repo: OwnRepository, targets: seq[string]): seq[string] =
  ## Zwraca listę nazw narzędzi w kolejności bezpiecznej do budowania/
  ## instalacji: każda zależność występuje w wyniku PRZED narzędziami,
  ## które jej potrzebują. Zawiera `targets` oraz wszystkie ich zależności
  ## przechodnie (ale NIE narzędzia niepowiązane z `targets`).
  ##
  ## Rzuca DepsError, gdy:
  ##  - `targets` (lub jakaś zależność) nie istnieje w `repo`,
  ##  - graf zawiera cykl.
  let index = buildIndex(repo)
  for t in targets:
    if t notin index:
      raise newException(DepsError, &"nieznane narzędzie '{t}' -- brak w custom/own-repository.json")

  var visited = initHashSet[string]()   ## w pełni przetworzone (na stosie wyjściowym)
  var onStack = initHashSet[string]()   ## aktualnie na ścieżce DFS (do wykrywania cykli)
  var order: seq[string] = @[]

  proc visit(name: string, path: seq[string]) =
    if name in visited:
      return
    if name in onStack:
      let cyclePath = (path & name).join(" -> ")
      raise newException(DepsError, &"cykl zależności w own-repository.json: {cyclePath}")
    if name notin index:
      let chain = path.join(" -> ")
      raise newException(DepsError,
        &"'{name}' (zależność {chain}) nie istnieje w custom/own-repository.json")

    onStack.incl name
    let tool = index[name]
    for dep in tool.dependsOn:
      visit(dep, path & name)
    onStack.excl name
    visited.incl name
    order.add name

  for t in targets:
    visit(t, @[])

  order

proc directDependents*(repo: OwnRepository, name: string): seq[string] =
  ## Narzędzia, które WPROST deklarują zależność od `name` -- przydatne np.
  ## żeby ostrzec przy `zpm own remove <name>`, co się razem z nim psuje.
  result = @[]
  for t in repo.tools:
    if name in t.dependsOn:
      result.add t.name
