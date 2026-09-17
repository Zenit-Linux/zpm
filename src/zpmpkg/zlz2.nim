import ./huffman
import ./bitio

const
  DefaultBlockSize* = 1 shl 20  # 1 MiB
  MinMatch = 4
  MaxMatchPerToken = 4 + 255    # 259
  LitLenAlphabet = 257          # 0..255 literal, 256 = dopasowanie
  LenAlphabet = 256
  DistAlphabet = 32             # klasy odleglosci 0..31 (2^31 okno -- z zapasem)
  HashBits = 15
  HashSize = 1 shl HashBits
  MaxChainDepth = 64

proc hash4(data: openArray[uint8], p, limit: int): uint32 {.inline.} =
  if p + 4 > limit: return 0
  let v = (uint32(data[p]) shl 24) or (uint32(data[p+1]) shl 16) or
          (uint32(data[p+2]) shl 8) or uint32(data[p+3])
  (v * 2654435761'u32) shr (32 - HashBits)

proc matchLenAt(data: openArray[uint8], a, b, limit: int): int {.inline.} =
  var n = 0
  while b + n < limit and data[a + n] == data[b + n]:
    inc n
  n

proc distClass(d: int): tuple[class, extraBits, extraVal: int] {.inline.} =
  var e = 0
  var v = d
  while v > 1:
    v = v shr 1
    inc e
  let base = 1 shl e
  (e, e, d - base)

proc writeLengths(w: var BitWriter, lengths: seq[int]) =
  var maxLen = 0
  for l in lengths:
    if l > maxLen: maxLen = l
  w.data.add char(uint8(maxLen))
  for l in lengths:
    w.data.add char(uint8(l))

proc readLengths(data: string, pos: var int, count: int): seq[int] =
  inc pos  # maxLen -- niepotrzebny do odczytu (odczytujemy wprost z tablicy)
  result = newSeq[int](count)
  for i in 0 ..< count:
    result[i] = int(uint8(data[pos + i]))
  pos += count

type Token = object
  isMatch: bool
  lit: uint8
  length: int   # tylko gdy isMatch
  dist: int     # tylko gdy isMatch

proc tokenizeBlock(data: openArray[uint8]): seq[Token] =
  let n = data.len
  result = @[]
  var head = newSeq[int32](HashSize)
  for i in 0 ..< HashSize: head[i] = -1
  var prevChain = newSeq[int32](max(1, n))
  var p = 0
  while p < n:
    var bestLen = 0
    var bestDist = 0
    if p + MinMatch <= n:
      let h = hash4(data, p, n)
      var cand = head[h]
      var depth = 0
      while cand >= 0 and depth < MaxChainDepth:
        let c = int(cand)
        let l = matchLenAt(data, c, p, n)
        if l > bestLen:
          bestLen = l
          bestDist = p - c
        cand = prevChain[c]
        inc depth
    if bestLen >= MinMatch:
      var remaining = bestLen
      var pos = p
      while remaining >= MinMatch:
        let take = min(remaining, MaxMatchPerToken)
        let actualTake = if remaining - take in 1 ..< MinMatch: remaining - MinMatch else: take
        result.add Token(isMatch: true, length: actualTake, dist: bestDist)
        remaining -= actualTake
        pos += actualTake
      var i = p
      let stop = p + bestLen
      while i < n - MinMatch + 1 and i < stop:
        let h2 = hash4(data, i, n)
        prevChain[i] = head[h2]
        head[h2] = int32(i)
        inc i
      p += bestLen
    else:
      result.add Token(isMatch: false, lit: data[p])
      if p + MinMatch <= n:
        let h = hash4(data, p, n)
        prevChain[p] = head[h]
        head[h] = int32(p)
      inc p

proc compressBlock*(data: openArray[uint8]): string =
  let tokens = tokenizeBlock(data)
  var litlenFreq = newSeq[int](LitLenAlphabet)
  var lenFreq = newSeq[int](LenAlphabet)
  var distFreq = newSeq[int](DistAlphabet)
  for t in tokens:
    if t.isMatch:
      inc litlenFreq[256]
      inc lenFreq[t.length - MinMatch]
      let (cls, _, _) = distClass(t.dist)
      inc distFreq[cls]
    else:
      inc litlenFreq[int(t.lit)]

  let litlenLen = buildCodeLengths(litlenFreq)
  let lenLen = buildCodeLengths(lenFreq)
  let distLen = buildCodeLengths(distFreq)
  let litlenCodes = canonicalCodes(litlenLen)
  let lenCodes = canonicalCodes(lenLen)
  let distCodes = canonicalCodes(distLen)

  var w = initBitWriter()
  writeLengths(w, litlenLen)
  writeLengths(w, lenLen)
  writeLengths(w, distLen)

  for t in tokens:
    if t.isMatch:
      w.writeHuffCode(litlenCodes[256], litlenLen[256])
      let lsym = t.length - MinMatch
      w.writeHuffCode(lenCodes[lsym], lenLen[lsym])
      let (cls, extraBits, extraVal) = distClass(t.dist)
      w.writeHuffCode(distCodes[cls], distLen[cls])
      if extraBits > 0:
        w.writeBits(uint32(extraVal), extraBits)
    else:
      w.writeHuffCode(litlenCodes[int(t.lit)], litlenLen[int(t.lit)])
  w.flush()

  var res = newStringOfCap(4 + w.data.len)
  for i in 0 ..< 4: res.add char(uint32(data.len) shr (i*8) and 0xff)
  res.add w.data
  res

proc decompressBlock*(blob: string, pos: var int): string =
  var rawLen: uint32 = 0
  for i in 0 ..< 4: rawLen = rawLen or (uint32(uint8(blob[pos + i])) shl (i*8))
  pos += 4
  let litlenLen = readLengths(blob, pos, LitLenAlphabet)
  let lenLen = readLengths(blob, pos, LenAlphabet)
  let distLen = readLengths(blob, pos, DistAlphabet)
  let litlenDec = initHuffDecoder(litlenLen)
  let lenDec = initHuffDecoder(lenLen)
  let distDec = initHuffDecoder(distLen)

  var r = initBitReader(blob)
  r.pos = pos
  proc rb(): int = r.readBit()

  var outp = newSeq[uint8]()
  outp.setLen(0)
  var produced = 0
  let target = int(rawLen)
  while produced < target:
    let sym = litlenDec.decodeOne(rb)
    if sym < 256:
      outp.add uint8(sym)
      inc produced
    else:
      let lsym = lenDec.decodeOne(rb)
      let length = lsym + MinMatch
      let cls = distDec.decodeOne(rb)
      var extraVal = 0
      if cls > 0:
        extraVal = int(r.readBits(cls))
      let dist = (1 shl cls) + extraVal
      let start = outp.len - dist
      if start < 0:
        raise newException(ValueError, "zlz2: uszkodzony strumień (nieprawidłowy offset dopasowania)")
      for k in 0 ..< length:
        outp.add outp[start + k]
      produced += length

  # `pos` po pętli to już poprawna, zaokrąglona w górę do pełnego bajtu
  # pozycja końca tego bloku w `blob` -- `BitReader.pos` wskazuje zawsze
  # na NASTĘPNY nieprzeczytany bajt (bajt, z którego aktualnie czytane
  # bity zostały już wczytane do `cur`), dokładnie tak samo jak
  # `BitWriter.flush()` zaokrągla zapis w górę do pełnego bajtu -- więc
  # obie strony zgadzają się co do granicy bloku bez dodatkowej księgowości.
  pos = r.pos

  result = newString(outp.len)
  for i in 0 ..< outp.len: result[i] = char(outp[i])
