const MaxCodeLen* = 24  ## bezpieczny sufit; przekroczenie -> wołający ma zrezygnować z Huffmana dla tego bloku

type HuffNode = object
  freq: int
  symbol: int    # -1 dla węzła wewnętrznego
  left, right: int  # indeksy w tablicy węzłów, -1 = brak
  order: int     # kolejność wstawienia -- do deterministycznego tie-break

proc buildCodeLengths*(freqs: seq[int]): seq[int] =
  ## Zwraca długość kodu (w bitach) dla każdego symbolu (0 = symbol
  ## nieużywany, freqs[i]==0). Przypadek 1 symbolu o freq>0: długość 1
  ## (kanoniczny Huffman wymaga >=1 bitu na symbol, nawet gdy jest tylko
  ## jeden -- inaczej dekoder nie wie, ile bitów przeczytać).
  let n = freqs.len
  result = newSeq[int](n)
  var used = 0
  for f in freqs:
    if f > 0: inc used
  if used == 0: return result
  if used == 1:
    for i in 0 ..< n:
      if freqs[i] > 0: result[i] = 1
    return result

  var nodes: seq[HuffNode] = @[]
  var active: seq[int] = @[]  # indeksy węzłów wciąż "w grze"
  var orderCtr = 0
  for i in 0 ..< n:
    if freqs[i] > 0:
      nodes.add HuffNode(freq: freqs[i], symbol: i, left: -1, right: -1, order: orderCtr)
      active.add nodes.len - 1
      inc orderCtr

  while active.len > 1:
    # znajdz dwa wezly o najmniejszej czestosci (tie-break: wczesniejszy `order`)
    var i1 = 0
    for k in 1 ..< active.len:
      let a = nodes[active[k]]; let b = nodes[active[i1]]
      if a.freq < b.freq or (a.freq == b.freq and a.order < b.order): i1 = k
    let idx1 = active[i1]
    active.delete(i1)
    var i2 = 0
    for k in 1 ..< active.len:
      let a = nodes[active[k]]; let b = nodes[active[i2]]
      if a.freq < b.freq or (a.freq == b.freq and a.order < b.order): i2 = k
    let idx2 = active[i2]
    active.delete(i2)

    nodes.add HuffNode(freq: nodes[idx1].freq + nodes[idx2].freq, symbol: -1,
                        left: idx1, right: idx2, order: orderCtr)
    inc orderCtr
    active.add nodes.len - 1

  # przejscie drzewa: policz glebokosc kazdego lisc
  let rootIdx = active[0]
  var stack: seq[tuple[idx, depth: int]] = @[(rootIdx, 0)]
  while stack.len > 0:
    let (idx, depth) = stack.pop()
    let node = nodes[idx]
    if node.symbol >= 0:
      result[node.symbol] = max(1, depth)
    else:
      stack.add (node.left, depth + 1)
      stack.add (node.right, depth + 1)

proc canonicalCodes*(lengths: seq[int]): seq[uint32] =
  ## Standardowy algorytm kodów kanonicznych: symbole posortowane wg
  ## (długość, numer symbolu) dostają kolejne kody rosnąco -- dekoder
  ## odtwarza to samo mając tylko `lengths`.
  let n = lengths.len
  result = newSeq[uint32](n)
  let maxLen = max(1, (block:
    var m = 0
    for l in lengths:
      if l > m: m = l
    m))
  var countPerLen = newSeq[int](maxLen + 1)
  for l in lengths:
    if l > 0: inc countPerLen[l]
  var code: uint32 = 0
  var firstCodeOfLen = newSeq[uint32](maxLen + 2)
  for l in 1 .. maxLen:
    firstCodeOfLen[l] = code
    code = (code + uint32(countPerLen[l])) shl 1
  var nextCode = firstCodeOfLen
  for sym in 0 ..< n:
    let l = lengths[sym]
    if l > 0:
      result[sym] = nextCode[l]
      inc nextCode[l]

type HuffDecoder* = object
  ## Dekodowanie oparte na strukturze kodów kanonicznych: dla danej
  ## długości L kody są kolejnymi liczbami całkowitymi zaczynającymi się
  ## od `firstCode[L]`, przypisanymi symbolom w kolejności
  ## (długość, numer symbolu) -- więc odczytany (L, kod) da się
  ## natychmiast zamienić na indeks w `sortedSymbols` przez odjęcie,
  ## bez przeszukiwania całego alfabetu przy każdym bicie (ważne przy
  ## blokach z dziesiątkami tysięcy tokenów).
  sortedSymbols: seq[int]     ## symbole posortowane wg (dlugosc, symbol)
  groupStart: seq[int]        ## groupStart[L] = indeks w sortedSymbols pierwszego symbolu o dlugosci L
  firstCode: seq[uint32]      ## firstCode[L] wg standardowego algorytmu kanonicznego
  maxLen: int

proc initHuffDecoder*(lengths: seq[int]): HuffDecoder =
  var maxLen = 0
  for l in lengths:
    if l > maxLen: maxLen = l
  result.maxLen = maxLen
  result.groupStart = newSeq[int](maxLen + 2)
  result.firstCode = newSeq[uint32](maxLen + 2)
  if maxLen == 0:
    result.sortedSymbols = @[]
    return

  var countPerLen = newSeq[int](maxLen + 1)
  for l in lengths:
    if l > 0: inc countPerLen[l]
  var code: uint32 = 0
  for l in 1 .. maxLen:
    result.firstCode[l] = code
    code = (code + uint32(countPerLen[l])) shl 1

  result.sortedSymbols = newSeq[int](lengths.len)  # nadpisane ponizej do dokladnego rozmiaru
  var idx = 0
  var starts = newSeq[int](maxLen + 2)
  for l in 1 .. maxLen:
    starts[l] = idx
    result.groupStart[l] = idx
    idx += countPerLen[l]
  result.sortedSymbols.setLen(idx)
  var cursor = starts
  for sym in 0 ..< lengths.len:
    let l = lengths[sym]
    if l > 0:
      result.sortedSymbols[cursor[l]] = sym
      inc cursor[l]

proc decodeOne*(dec: HuffDecoder, readBitProc: proc(): int): int =
  var code: uint32 = 0
  var length = 0
  while length < dec.maxLen:
    code = (code shl 1) or uint32(readBitProc())
    inc length
    if length > dec.maxLen: break
    let countAtLen = (if length < dec.maxLen: dec.groupStart[length+1] else: dec.sortedSymbols.len) - dec.groupStart[length]
    let offset = code - dec.firstCode[length]
    if offset < uint32(countAtLen):
      return dec.sortedSymbols[dec.groupStart[length] + int(offset)]
  raise newException(ValueError, "huffman: nie rozpoznano kodu (uszkodzony strumień)")
