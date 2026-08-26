import std/[strutils, tables, strformat]

type
  HclValueKind* = enum
    hvString, hvInt, hvBool, hvList

  HclValue* = object
    case kind*: HclValueKind
    of hvString: strVal*: string
    of hvInt: intVal*: int
    of hvBool: boolVal*: bool
    of hvList: listVal*: seq[string]

  HclBlock* = ref object
    name*: string
    attrs*: Table[string, HclValue]
    children*: seq[HclBlock]

  HclParseError* = object of CatchableError
    ## Rzucany z NUMEREM LINII w komunikacie -- celowo zamiast po cichu
    ## mis-parsować (np. traktować niedomknięty blok jako pusty string),
    ## bo cichy błąd konfiguracji w produkcyjnym `/etc/zpm/config.hcl`
    ## jest dużo gorszy niż `quit(1)` z jasnym miejscem problemu.

proc newHclBlock*(name: string): HclBlock =
  HclBlock(name: name, attrs: initTable[string, HclValue](), children: @[])

proc unescapeHclString(inner: string, lineNo: int): string =
  ## Obsługuje `\"` i `\\` wewnątrz stringów HCL (np. ścieżki Windows albo
  ## URL-e z escapowanym cudzysłowem) -- bez tego `"a \" b"` było po
  ## prostu ucinane na pierwszym escapowanym cudzysłowie bez ostrzeżenia.
  result = newStringOfCap(inner.len)
  var i = 0
  while i < inner.len:
    if inner[i] == '\\' and i + 1 < inner.len and inner[i+1] in {'"', '\\'}:
      result.add inner[i+1]
      i += 2
    elif inner[i] == '\\' and i + 1 >= inner.len:
      raise newException(HclParseError, &"linia {lineNo}: string urwany na znaku ucieczki '\\' na końcu linii")
    else:
      result.add inner[i]
      inc i

proc parseValue(raw: string, lineNo: int): HclValue =
  let v = raw.strip()
  if v.len == 0:
    raise newException(HclParseError, &"linia {lineNo}: brak wartości po '=' (pusta prawa strona)")
  if v[0] == '"':
    # Szukaj zamykającego, NIEescapowanego cudzysłowu -- string bez niego
    # to błąd konfiguracji (literówka), a nie "po prostu string do końca linii".
    var closeIdx = -1
    var j = 1
    while j < v.len:
      if v[j] == '"' and v[j-1] != '\\':
        closeIdx = j
        break
      inc j
    if closeIdx < 0:
      raise newException(HclParseError, &"linia {lineNo}: niedomknięty string (brakujący końcowy '\"')")
    result = HclValue(kind: hvString, strVal: unescapeHclString(v[1 ..< closeIdx], lineNo))
  elif v == "true" or v == "false":
    result = HclValue(kind: hvBool, boolVal: v == "true")
  elif v[0] == '[':
    if v[^1] != ']':
      raise newException(HclParseError, &"linia {lineNo}: niedomknięta lista (brakujący końcowy ']')")
    let inner = v[1 ..< v.high]
    var items: seq[string] = @[]
    for part in inner.split(','):
      let p = part.strip().strip(chars = {'"'})
      if p.len > 0:
        items.add(p)
    result = HclValue(kind: hvList, listVal: items)
  else:
    var ok = true
    for c in v:
      if not c.isDigit(): ok = false
    if ok and v.len > 0:
      result = HclValue(kind: hvInt, intVal: parseInt(v))
    else:
      # Nieznana, niecudzysłowiona wartość (np. literówka zamiast "true"/
      # liczby/listy/stringa w cudzysłowie) -- zamiast cicho przyjąć to
      # jako string dosłownie, ostrzegamy: to niemal zawsze błąd configu.
      raise newException(HclParseError,
        &"linia {lineNo}: nierozpoznana wartość '{v}' -- oczekiwano stringa w cudzysłowach, " &
        "liczby, true/false albo listy [\"a\",\"b\"]")

proc parseHcl*(source: string): HclBlock =
  ## Parsuje cały dokument HCL, zwracając "wirtualny" blok główny (root),
  ## którego `children` to bloki najwyższego poziomu, a `attrs` to
  ## atrybuty zdefiniowane poza blokami. Rzuca `HclParseError` (z numerem
  ## linii) przy niedomkniętym bloku/stringu/liście albo nierozpoznanej
  ## wartości -- zamiast po cichu zwrócić coś innego, niż operator napisał.
  result = newHclBlock("root")
  var stack: seq[HclBlock] = @[result]
  var openLines: seq[int] = @[0]  ## linia otwarcia każdego bloku na stosie (root = 0)

  for idx, rawLine in source.splitLines().pairs():
    let lineNo = idx + 1
    var line = rawLine.strip()
    # usuń komentarze (# lub //), ale NIE wewnątrz cudzysłowów
    line = block:
      var inStr = false
      var cut = line.len
      var k = 0
      while k < line.len:
        if line[k] == '"' and (k == 0 or line[k-1] != '\\'): inStr = not inStr
        elif not inStr and line[k] == '#':
          cut = k; break
        elif not inStr and line[k] == '/' and k + 1 < line.len and line[k+1] == '/':
          cut = k; break
        inc k
      line[0 ..< cut].strip()
    if line.len == 0: continue

    if line.endsWith("{"):
      var header = line[0 ..< line.high].strip()
      var blockName = header
      let quoteStart = header.find('"')
      if quoteStart >= 0:
        let quoteEnd = header.rfind('"')
        if quoteEnd <= quoteStart:
          raise newException(HclParseError, &"linia {lineNo}: niedomknięty string w nagłówku bloku")
        blockName = header[quoteStart+1 ..< quoteEnd]
      else:
        blockName = header.strip()
      if blockName.len == 0:
        raise newException(HclParseError, &"linia {lineNo}: blok bez nazwy przed '{{'")
      let blk = newHclBlock(blockName)
      stack[^1].children.add(blk)
      stack.add(blk)
      openLines.add(lineNo)
    elif line == "}":
      if stack.len <= 1:
        raise newException(HclParseError, &"linia {lineNo}: nadmiarowy '}}' bez odpowiadającego otwarcia")
      discard stack.pop()
      discard openLines.pop()
    elif '=' in line:
      let idxEq = line.find('=')
      let key = line[0 ..< idxEq].strip()
      if key.len == 0:
        raise newException(HclParseError, &"linia {lineNo}: brak nazwy klucza przed '='")
      let valRaw = line[idxEq+1 .. ^1].strip()
      stack[^1].attrs[key] = parseValue(valRaw, lineNo)
    else:
      raise newException(HclParseError,
        &"linia {lineNo}: nierozpoznana linia (oczekiwano 'blok {{', '}}' albo 'klucz = wartość'): {line}")

  if stack.len > 1:
    raise newException(HclParseError,
      &"niedomknięty blok '{stack[^1].name}' otwarty w linii {openLines[^1]} (brakujący '}}' do końca pliku)")

proc getStr*(blk: HclBlock, key: string, default = ""): string =
  if blk.attrs.hasKey(key) and blk.attrs[key].kind == hvString:
    blk.attrs[key].strVal
  else: default

proc getBool*(blk: HclBlock, key: string, default = false): bool =
  if blk.attrs.hasKey(key) and blk.attrs[key].kind == hvBool:
    blk.attrs[key].boolVal
  else: default

proc getInt*(blk: HclBlock, key: string, default = 0): int =
  if blk.attrs.hasKey(key) and blk.attrs[key].kind == hvInt:
    blk.attrs[key].intVal
  else: default

proc getList*(blk: HclBlock, key: string, default: seq[string] = @[]): seq[string] =
  if blk.attrs.hasKey(key) and blk.attrs[key].kind == hvList:
    blk.attrs[key].listVal
  else: default

proc findBlock*(blk: HclBlock, name: string): HclBlock =
  for c in blk.children:
    if c.name == name: return c
  return nil
