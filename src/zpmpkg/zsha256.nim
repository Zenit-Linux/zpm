import std/[streams, strutils]

type
  Sha256State* = object
    h: array[8, uint32]
    buf: array[64, uint8]
    bufLen: int
    totalLen: uint64

const K: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32
]

proc rotr(x: uint32, n: int): uint32 {.inline.} =
  (x shr n) or (x shl (32 - n))

proc initSha256*(): Sha256State =
  result.h = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32
  ]
  result.bufLen = 0
  result.totalLen = 0

proc processBlock(s: var Sha256State, blk: openArray[uint8]) =
  var w: array[64, uint32]
  for i in 0 ..< 16:
    w[i] = (uint32(blk[i*4]) shl 24) or (uint32(blk[i*4+1]) shl 16) or
           (uint32(blk[i*4+2]) shl 8) or uint32(blk[i*4+3])
  for i in 16 ..< 64:
    let s0 = rotr(w[i-15], 7) xor rotr(w[i-15], 18) xor (w[i-15] shr 3)
    let s1 = rotr(w[i-2], 17) xor rotr(w[i-2], 19) xor (w[i-2] shr 10)
    w[i] = w[i-16] + s0 + w[i-7] + s1

  var a = s.h[0]; var b = s.h[1]; var c = s.h[2]; var d = s.h[3]
  var e = s.h[4]; var f = s.h[5]; var g = s.h[6]; var h = s.h[7]

  for i in 0 ..< 64:
    let s1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
    let choice = (e and f) xor ((not e) and g)
    let temp1 = h + s1 + choice + K[i] + w[i]
    let s0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
    let majority = (a and b) xor (a and c) xor (b and c)
    let temp2 = s0 + majority
    h = g; g = f; f = e; e = d + temp1
    d = c; c = b; b = a; a = temp1 + temp2

  s.h[0] += a; s.h[1] += b; s.h[2] += c; s.h[3] += d
  s.h[4] += e; s.h[5] += f; s.h[6] += g; s.h[7] += h

proc update*(s: var Sha256State, data: openArray[uint8]) =
  s.totalLen += uint64(data.len)
  var offset = 0
  if s.bufLen > 0:
    let need = 64 - s.bufLen
    let take = min(need, data.len)
    for i in 0 ..< take: s.buf[s.bufLen + i] = data[i]
    s.bufLen += take
    offset += take
    if s.bufLen == 64:
      s.processBlock(s.buf)
      s.bufLen = 0
  while offset + 64 <= data.len:
    var blk: array[64, uint8]
    for i in 0 ..< 64: blk[i] = data[offset + i]
    s.processBlock(blk)
    offset += 64
  while offset < data.len:
    s.buf[s.bufLen] = data[offset]
    inc s.bufLen
    inc offset

proc update*(s: var Sha256State, data: string) =
  if data.len > 0:
    s.update(toOpenArrayByte(data, 0, data.high))

proc finalHex*(s: var Sha256State): string =
  let bitLen = s.totalLen * 8
  var pad: seq[uint8] = @[0x80'u8]
  var padLen = (56 - (s.bufLen + 1) mod 64 + 64) mod 64
  for _ in 0 ..< padLen: pad.add 0x00'u8
  for i in countdown(7, 0):
    pad.add uint8((bitLen shr (i * 8)) and 0xff)
  s.update(pad)
  result = newStringOfCap(64)
  for word in s.h:
    result.add toHex(word).toLowerAscii()

proc sha256Hex*(data: string): string =
  ## sha256 całego stringa (w pamięci) jako hex (64 znaki, małe litery).
  var s = initSha256()
  s.update(data)
  s.finalHex()

proc sha256HexOfFile*(path: string): string =
  ## sha256 pliku, czytanego strumieniowo blokami 64 KiB -- stałe zużycie
  ## pamięci niezależnie od rozmiaru pliku (bez wczytywania całości naraz).
  var strm = newFileStream(path, fmRead)
  if strm == nil:
    raise newException(IOError, "nie można otworzyć pliku: " & path)
  defer: strm.close()
  var s = initSha256()
  var chunk = newString(65536)
  while true:
    let n = strm.readData(chunk[0].addr, chunk.len)
    if n <= 0: break
    s.update(toOpenArrayByte(chunk, 0, n - 1))
  s.finalHex()
