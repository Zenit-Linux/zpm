const
  MinMatch = 4
  MaxMatchPerToken = 4 + 127  # 131
  MaxOffset = (1 shl 24) - 1  # 3 bajty little-endian
  HashBits = 16
  HashSize = 1 shl HashBits
  MaxChainDepth = 48          # ograniczenie głębokości łańcucha -> szybkość

proc hash4(data: openArray[uint8], p: int): uint32 {.inline.} =
  let v = (uint32(data[p]) shl 24) or (uint32(data[p+1]) shl 16) or
          (uint32(data[p+2]) shl 8) or uint32(data[p+3])
  (v * 2654435761'u32) shr (32 - HashBits)

proc matchLen(data: openArray[uint8], a, b, limit: int): int {.inline.} =
  var n = 0
  while b + n < limit and data[a + n] == data[b + n]:
    inc n
  n

proc compress*(input: string): string =
  ## Kompresuje `input` do strumienia ZLZ1. Zwraca string (bajty binarne).
  let n = input.len
  if n == 0: return ""
  var data = newSeq[uint8](n)
  for i in 0 ..< n: data[i] = uint8(input[i])

  var head = newSeq[int32](HashSize)
  for i in 0 ..< HashSize: head[i] = -1
  var prevChain = newSeq[int32](n)

  var outp = newStringOfCap(n div 2 + 64)
  var litStart = 0
  var p = 0

  proc flushLiterals(upto: int) =
    var i = litStart
    while i < upto:
      let chunk = min(127, upto - i)
      outp.add char(chunk)  # bit7=0
      for k in 0 ..< chunk: outp.add char(data[i + k])
      i += chunk

  while p < n:
    var bestLen = 0
    var bestDist = 0
    if p + MinMatch <= n:
      let h = hash4(data, p)
      var cand = head[h]
      var depth = 0
      while cand >= 0 and depth < MaxChainDepth:
        let c = int(cand)
        if p - c <= MaxOffset:
          let l = matchLen(data, c, p, n)
          if l > bestLen:
            bestLen = l
            bestDist = p - c
            if bestLen >= 4096: break  # wystarczająco długie, przestań szukać
        cand = prevChain[c]
        inc depth

    if bestLen >= MinMatch:
      flushLiterals(p)
      var remaining = bestLen
      var dist = bestDist
      var srcPos = p - bestDist
      while remaining >= MinMatch:
        let take = min(remaining, MaxMatchPerToken)
        # nie dziel poniżej MinMatch przy ostatnim kawałku
        let actualTake = if remaining - take in 1 ..< MinMatch: remaining - MinMatch else: take
        outp.add char(0x80 or (actualTake - MinMatch))
        outp.add char(dist and 0xff)
        outp.add char((dist shr 8) and 0xff)
        outp.add char((dist shr 16) and 0xff)
        remaining -= actualTake
        srcPos += actualTake
        # dystans pozostaje ten sam (odnosi się zawsze do tej samej
        # pozycji źródłowej w JUŻ zdekomprymowanym strumieniu, który po
        # dekompresji pierwszego kawałka już zawiera te bajty)
        dist = bestDist
      # zarejestruj pozycje w tabeli hashy dla CAŁEGO dopasowania (dla
      # przyszłych, jeszcze lepszych dopasowań) -- co 1 pozycję dla
      # jakości kompresji (koszt: nieco wolniejszy koder)
      var i = p
      let stop = p + bestLen
      while i < n - MinMatch + 1 and i < stop:
        let h2 = hash4(data, i)
        prevChain[i] = head[h2]
        head[h2] = int32(i)
        inc i
      p += bestLen
      litStart = p
    else:
      if p + MinMatch <= n:
        let h = hash4(data, p)
        prevChain[p] = head[h]
        head[h] = int32(p)
      inc p

  flushLiterals(n)
  outp

proc decompress*(input: string, expectedSize: int = -1): string =
  ## Dekompresuje strumień ZLZ1. `expectedSize`, jeśli podany (>=0),
  ## rezerwuje pojemność z góry (rozmiar znany z manifestu/TOC archiwum).
  if input.len == 0: return ""
  var res: seq[uint8]
  if expectedSize >= 0: res = newSeqOfCap[uint8](expectedSize)
  else: res = newSeq[uint8]()
  var i = 0
  let inN = input.len
  while i < inN:
    let ctrl = uint8(input[i])
    inc i
    if (ctrl and 0x80) == 0:
      let count = int(ctrl and 0x7f)
      for k in 0 ..< count:
        res.add uint8(input[i + k])
      i += count
    else:
      let length = int(ctrl and 0x7f) + MinMatch
      let dist = int(uint8(input[i])) or (int(uint8(input[i+1])) shl 8) or (int(uint8(input[i+2])) shl 16)
      i += 3
      let start = res.len - dist
      if start < 0:
        raise newException(ValueError, "uszkodzony strumień ZLZ1: nieprawidłowy offset dopasowania")
      for k in 0 ..< length:
        res.add res[start + k]  # kopiowanie bajt po bajcie -- poprawne też dla dist < length (nakładanie)
  result = newString(res.len)
  for idx in 0 ..< res.len: result[idx] = char(res[idx])
