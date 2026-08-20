import std/[strutils, tables]

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

proc newHclBlock*(name: string): HclBlock =
  HclBlock(name: name, attrs: initTable[string, HclValue](), children: @[])

proc parseValue(raw: string): HclValue =
  let v = raw.strip()
  if v.len >= 2 and v[0] == '"' and v[^1] == '"':
    result = HclValue(kind: hvString, strVal: v[1 ..< v.high])
  elif v == "true" or v == "false":
    result = HclValue(kind: hvBool, boolVal: v == "true")
  elif v.len > 0 and v[0] == '[':
    let inner = v.strip(chars = {'[', ']'})
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
      result = HclValue(kind: hvString, strVal: v)

proc parseHcl*(source: string): HclBlock =
  ## Parsuje cały dokument HCL, zwracając "wirtualny" blok główny (root),
  ## którego `children` to bloki najwyższego poziomu, a `attrs` to
  ## atrybuty zdefiniowane poza blokami.
  result = newHclBlock("root")
  var stack: seq[HclBlock] = @[result]

  for rawLine in source.splitLines():
    var line = rawLine.strip()
    # usuń komentarze (# lub //)
    let hashPos = line.find('#')
    if hashPos >= 0: line = line[0 ..< hashPos].strip()
    let slashPos = line.find("//")
    if slashPos >= 0: line = line[0 ..< slashPos].strip()
    if line.len == 0: continue

    if line.endsWith("{"):
      # np:  backend "apt" {   albo   settings {
      var header = line[0 ..< line.high].strip()
      var blockName = header
      let quoteStart = header.find('"')
      if quoteStart >= 0:
        let quoteEnd = header.rfind('"')
        blockName = header[quoteStart+1 ..< quoteEnd]
      else:
        blockName = header.strip()
      let blk = newHclBlock(blockName)
      stack[^1].children.add(blk)
      stack.add(blk)
    elif line == "}":
      if stack.len > 1:
        discard stack.pop()
    elif '=' in line:
      let idx = line.find('=')
      let key = line[0 ..< idx].strip()
      let valRaw = line[idx+1 .. ^1].strip()
      stack[^1].attrs[key] = parseValue(valRaw)

proc getStr*(blk: HclBlock, key: string, default = ""): string =
  if blk.attrs.hasKey(key) and blk.attrs[key].kind == hvString:
    blk.attrs[key].strVal
  else: default

proc getBool*(blk: HclBlock, key: string, default = false): bool =
  if blk.attrs.hasKey(key) and blk.attrs[key].kind == hvBool:
    blk.attrs[key].boolVal
  else: default

proc getList*(blk: HclBlock, key: string, default: seq[string] = @[]): seq[string] =
  if blk.attrs.hasKey(key) and blk.attrs[key].kind == hvList:
    blk.attrs[key].listVal
  else: default

proc findBlock*(blk: HclBlock, name: string): HclBlock =
  for c in blk.children:
    if c.name == name: return c
  return nil
