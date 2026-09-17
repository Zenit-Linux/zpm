type
  Sha512State* = object
    h: array[8, uint64]
    buf: array[128, uint8]
    bufLen: int
    totalLen: uint64  # w bajtach; wystarcza (< 2^61 bajtów danych)

const K: array[80, uint64] = [
  0x428a2f98d728ae22'u64, 0x7137449123ef65cd'u64, 0xb5c0fbcfec4d3b2f'u64, 0xe9b5dba58189dbbc'u64,
  0x3956c25bf348b538'u64, 0x59f111f1b605d019'u64, 0x923f82a4af194f9b'u64, 0xab1c5ed5da6d8118'u64,
  0xd807aa98a3030242'u64, 0x12835b0145706fbe'u64, 0x243185be4ee4b28c'u64, 0x550c7dc3d5ffb4e2'u64,
  0x72be5d74f27b896f'u64, 0x80deb1fe3b1696b1'u64, 0x9bdc06a725c71235'u64, 0xc19bf174cf692694'u64,
  0xe49b69c19ef14ad2'u64, 0xefbe4786384f25e3'u64, 0x0fc19dc68b8cd5b5'u64, 0x240ca1cc77ac9c65'u64,
  0x2de92c6f592b0275'u64, 0x4a7484aa6ea6e483'u64, 0x5cb0a9dcbd41fbd4'u64, 0x76f988da831153b5'u64,
  0x983e5152ee66dfab'u64, 0xa831c66d2db43210'u64, 0xb00327c898fb213f'u64, 0xbf597fc7beef0ee4'u64,
  0xc6e00bf33da88fc2'u64, 0xd5a79147930aa725'u64, 0x06ca6351e003826f'u64, 0x142929670a0e6e70'u64,
  0x27b70a8546d22ffc'u64, 0x2e1b21385c26c926'u64, 0x4d2c6dfc5ac42aed'u64, 0x53380d139d95b3df'u64,
  0x650a73548baf63de'u64, 0x766a0abb3c77b2a8'u64, 0x81c2c92e47edaee6'u64, 0x92722c851482353b'u64,
  0xa2bfe8a14cf10364'u64, 0xa81a664bbc423001'u64, 0xc24b8b70d0f89791'u64, 0xc76c51a30654be30'u64,
  0xd192e819d6ef5218'u64, 0xd69906245565a910'u64, 0xf40e35855771202a'u64, 0x106aa07032bbd1b8'u64,
  0x19a4c116b8d2d0c8'u64, 0x1e376c085141ab53'u64, 0x2748774cdf8eeb99'u64, 0x34b0bcb5e19b48a8'u64,
  0x391c0cb3c5c95a63'u64, 0x4ed8aa4ae3418acb'u64, 0x5b9cca4f7763e373'u64, 0x682e6ff3d6b2b8a3'u64,
  0x748f82ee5defb2fc'u64, 0x78a5636f43172f60'u64, 0x84c87814a1f0ab72'u64, 0x8cc702081a6439ec'u64,
  0x90befffa23631e28'u64, 0xa4506cebde82bde9'u64, 0xbef9a3f7b2c67915'u64, 0xc67178f2e372532b'u64,
  0xca273eceea26619c'u64, 0xd186b8c721c0c207'u64, 0xeada7dd6cde0eb1e'u64, 0xf57d4f7fee6ed178'u64,
  0x06f067aa72176fba'u64, 0x0a637dc5a2c898a6'u64, 0x113f9804bef90dae'u64, 0x1b710b35131c471b'u64,
  0x28db77f523047d84'u64, 0x32caab7b40c72493'u64, 0x3c9ebe0a15c9bebc'u64, 0x431d67c49c100d4c'u64,
  0x4cc5d4becb3e42b6'u64, 0x597f299cfc657e2a'u64, 0x5fcb6fab3ad6faec'u64, 0x6c44198c4a475817'u64
]

proc rotr64(x: uint64, n: int): uint64 {.inline.} =
  (x shr n) or (x shl (64 - n))

proc initSha512*(): Sha512State =
  result.h = [
    0x6a09e667f3bcc908'u64, 0xbb67ae8584caa73b'u64, 0x3c6ef372fe94f82b'u64, 0xa54ff53a5f1d36f1'u64,
    0x510e527fade682d1'u64, 0x9b05688c2b3e6c1f'u64, 0x1f83d9abfb41bd6b'u64, 0x5be0cd19137e2179'u64
  ]
  result.bufLen = 0
  result.totalLen = 0

proc processBlock(s: var Sha512State, blk: openArray[uint8]) =
  var w: array[80, uint64]
  for i in 0 ..< 16:
    var v: uint64 = 0
    for k in 0 ..< 8: v = (v shl 8) or uint64(blk[i*8 + k])
    w[i] = v
  for i in 16 ..< 80:
    let s0 = rotr64(w[i-15], 1) xor rotr64(w[i-15], 8) xor (w[i-15] shr 7)
    let s1 = rotr64(w[i-2], 19) xor rotr64(w[i-2], 61) xor (w[i-2] shr 6)
    w[i] = w[i-16] + s0 + w[i-7] + s1

  var a = s.h[0]; var b = s.h[1]; var c = s.h[2]; var d = s.h[3]
  var e = s.h[4]; var f = s.h[5]; var g = s.h[6]; var h = s.h[7]

  for i in 0 ..< 80:
    let s1 = rotr64(e, 14) xor rotr64(e, 18) xor rotr64(e, 41)
    let choice = (e and f) xor ((not e) and g)
    let temp1 = h + s1 + choice + K[i] + w[i]
    let s0 = rotr64(a, 28) xor rotr64(a, 34) xor rotr64(a, 39)
    let majority = (a and b) xor (a and c) xor (b and c)
    let temp2 = s0 + majority
    h = g; g = f; f = e; e = d + temp1
    d = c; c = b; b = a; a = temp1 + temp2

  s.h[0] += a; s.h[1] += b; s.h[2] += c; s.h[3] += d
  s.h[4] += e; s.h[5] += f; s.h[6] += g; s.h[7] += h

proc update*(s: var Sha512State, data: openArray[uint8]) =
  s.totalLen += uint64(data.len)
  var offset = 0
  if s.bufLen > 0:
    let need = 128 - s.bufLen
    let take = min(need, data.len)
    for i in 0 ..< take: s.buf[s.bufLen + i] = data[i]
    s.bufLen += take
    offset += take
    if s.bufLen == 128:
      s.processBlock(s.buf)
      s.bufLen = 0
  while offset + 128 <= data.len:
    var blk: array[128, uint8]
    for i in 0 ..< 128: blk[i] = data[offset + i]
    s.processBlock(blk)
    offset += 128
  while offset < data.len:
    s.buf[s.bufLen] = data[offset]
    inc s.bufLen
    inc offset

proc update*(s: var Sha512State, data: string) =
  if data.len > 0:
    s.update(toOpenArrayByte(data, 0, data.high))

proc finalBytes*(s: var Sha512State): array[64, uint8] =
  ## SHA-512 -- długość wiadomości w bitach jako 128-bitowa liczba (my
  ## wspieramy tylko dolne 64 bity, górne 64 zawsze 0 -- wystarcza dla
  ## danych < 2^61 bajtów, co pokrywa dowolny realistyczny plik/pakiet).
  let bitLen = s.totalLen * 8
  var pad: seq[uint8] = @[0x80'u8]
  var padLen = (112 - (s.bufLen + 1) mod 128 + 128) mod 128
  for _ in 0 ..< padLen: pad.add 0x00'u8
  for _ in 0 ..< 8: pad.add 0x00'u8  # górne 64 bity długości = 0
  for i in countdown(7, 0):
    pad.add uint8((bitLen shr (i * 8)) and 0xff)
  s.update(pad)
  for wi in 0 ..< 8:
    let word = s.h[wi]
    for bi in 0 ..< 8:
      result[wi*8 + bi] = uint8((word shr ((7 - bi) * 8)) and 0xff)

proc sha512Bytes*(data: string): array[64, uint8] =
  var s = initSha512()
  s.update(data)
  s.finalBytes()

proc sha512Bytes*(data: openArray[uint8]): array[64, uint8] =
  var s = initSha512()
  s.update(data)
  s.finalBytes()

proc sha512Hex*(data: string): string =
  const hexChars = "0123456789abcdef"
  let d = sha512Bytes(data)
  result = newStringOfCap(128)
  for b in d:
    result.add hexChars[int(b) shr 4]
    result.add hexChars[int(b) and 0x0f]
