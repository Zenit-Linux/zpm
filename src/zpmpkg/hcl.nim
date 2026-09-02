import std/[tables, strformat]
import hclnim

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
    ## Ujednolicony typ błędu TEGO modułu -- niezależnie od tego, czy błąd
    ## pochodzi z leksera czy parsera `hcl_nim` (`hclnim.HclLexError`/
    ## `hclnim.HclParseError`, importowane, ale NIE eksportowane -- patrz
    ## `parseHcl` niżej, gdzie oba są łapane i opakowywane w TEN typ, z
    ## numerem linii/kolumny w komunikacie), wołający dostaje zawsze ten
    ## sam, jeden typ wyjątku do złapania (dokładnie jak w v0.4).

proc newHclBlock*(name: string): HclBlock =
  HclBlock(name: name, attrs: initTable[string, HclValue](), children: @[])

proc toHclValue(n: HclNode): HclValue =
  ## Konwertuje `HclNode` (wartość zwrócona przez `hcl_nim`) na nasz
  ## okrojony `HclValue`. `config.nim` zna tylko string/int/bool/listę
  ## stringów -- patrz komentarz modułu wyżej.
  case n.kind
  of nkString:
    HclValue(kind: hvString, strVal: n.strVal)
  of nkNumber:
    HclValue(kind: hvInt, intVal: (if n.isInt: int(n.intVal) else: int(n.numVal)))
  of nkBool:
    HclValue(kind: hvBool, boolVal: n.boolVal)
  of nkNull:
    HclValue(kind: hvString, strVal: "")
  of nkHeredoc:
    HclValue(kind: hvString, strVal: n.heredocText)
  of nkExpr:
    ## Wyrażenie HCL2 (referencja/funkcja/warunek/for/...) -- config.hcl
    ## zpm-a go nie używa; zachowujemy surowy tekst źródłowy zamiast
    ## po cichu go tracić.
    HclValue(kind: hvString, strVal: n.exprSrc)
  of nkList:
    var items: seq[string] = @[]
    for it in n.items:
      items.add it.asString
    HclValue(kind: hvList, listVal: items)
  of nkObject:
    ## Inline-obiekt jako WARTOŚĆ atrybutu (`x = { a = 1 }`) -- config.hcl
    ## zpm-a tego nie używa (zagnieżdżone ustawienia idą jako BLOKI, patrz
    ## `native { distro_images { ... } }`); sprowadzamy do listy kluczy
    ## zamiast po cichu gubić dane.
    var items: seq[string] = @[]
    for (k, _) in n.fields:
      items.add k
    HclValue(kind: hvList, listVal: items)
  else:
    HclValue(kind: hvString, strVal: "")

proc convertBlock(node: HclNode, name: string): HclBlock =
  result = newHclBlock(name)
  let items =
    case node.kind
    of nkDocument: node.body
    of nkBlock: node.blockBody
    else: @[]
  for item in items:
    case item.kind
    of nkAttribute:
      result.attrs[item.name] = toHclValue(item.value)
    of nkBlock:
      ## Bloki z etykietą (`typ "etykieta" { ... }`) -- config.hcl zpm-a
      ## ich nie używa, ale gdyby się pojawiły, pierwsza etykieta staje
      ## się nazwą bloku (dokładnie zachowanie starego, ręcznego parsera:
      ## `findBlock("etykieta")`); bez etykiety nazwą jest sam typ bloku
      ## (`core { ... }` -> "core").
      let childName = if item.labels.len > 0: item.labels[0] else: item.blockType
      result.children.add convertBlock(item, childName)
    else:
      discard

proc parseHcl*(source: string): HclBlock =
  ## Parsuje CAŁY dokument HCL przez `hcl_nim` (dialekt HCL2 -- nadzbiór
  ## składniowy HCL1, jedyny którego config.hcl zpm-a i tak używa: bloki
  ## bez etykiet, atrybuty, stringi, liczby, bool, listy) i konwertuje
  ## wynik do naszego `HclBlock` ("wirtualny" root, tak jak poprzednio --
  ## `children` to bloki najwyższego poziomu, `attrs` atrybuty poza
  ## blokami). Błędy leksera/parsera `hcl_nim` są opakowywane w NASZ
  ## `HclParseError`, żeby config.nim nie musiało wiedzieć nic o `hcl_nim`
  ## jako konkretnej implementacji parsera.
  let doc =
    try:
      hclnim.parseHcl(source, hclnim.hcl2)
    except hclnim.HclLexError as e:
      raise newException(HclParseError, &"linia {e.line}, kolumna {e.col}: {e.msg}")
    except hclnim.HclParseError as e:
      raise newException(HclParseError, &"linia {e.line}, kolumna {e.col}: {e.msg}")
    except hclnim.HclError as e:
      raise newException(HclParseError, e.msg)
  convertBlock(doc, "root")

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
