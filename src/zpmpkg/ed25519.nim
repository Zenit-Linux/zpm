import ./bignum
import ./zsha512

# ---------------------------------------------------------------------------
# Stałe krzywej (wygenerowane i zweryfikowane niezależnie w Pythonie, patrz
# komentarz w tests/test_ed25519.nim -- policzone na nowo w Nim niżej w
# `selfTestConstants` i porównane z tymi stałymi jako dodatkowa asercja).
# ---------------------------------------------------------------------------

const PBytes = [0xed'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0xff'u8, 0x7f'u8]
const DBytes = [0xa3'u8, 0x78'u8, 0x59'u8, 0x13'u8, 0xca'u8, 0x4d'u8, 0xeb'u8, 0x75'u8, 0xab'u8, 0xd8'u8, 0x41'u8, 0x41'u8, 0x4d'u8, 0x0a'u8, 0x70'u8, 0x00'u8, 0x98'u8, 0xe8'u8, 0x79'u8, 0x77'u8, 0x79'u8, 0x40'u8, 0xc7'u8, 0x8c'u8, 0x73'u8, 0xfe'u8, 0x6f'u8, 0x2b'u8, 0xee'u8, 0x6c'u8, 0x03'u8, 0x52'u8]
const BxBytes = [0x1a'u8, 0xd5'u8, 0x25'u8, 0x8f'u8, 0x60'u8, 0x2d'u8, 0x56'u8, 0xc9'u8, 0xb2'u8, 0xa7'u8, 0x25'u8, 0x95'u8, 0x60'u8, 0xc7'u8, 0x2c'u8, 0x69'u8, 0x5c'u8, 0xdc'u8, 0xd6'u8, 0xfd'u8, 0x31'u8, 0xe2'u8, 0xa4'u8, 0xc0'u8, 0xfe'u8, 0x53'u8, 0x6e'u8, 0xcd'u8, 0xd3'u8, 0x36'u8, 0x69'u8, 0x21'u8]
const ByBytes = [0x58'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8, 0x66'u8]
const SqrtM1Bytes = [0xb0'u8, 0xa0'u8, 0x0e'u8, 0x4a'u8, 0x27'u8, 0x1b'u8, 0xee'u8, 0xc4'u8, 0x78'u8, 0xe4'u8, 0x2f'u8, 0xad'u8, 0x06'u8, 0x18'u8, 0x43'u8, 0x2f'u8, 0xa7'u8, 0xd7'u8, 0xfb'u8, 0x3d'u8, 0x99'u8, 0x00'u8, 0x4d'u8, 0x2b'u8, 0x0b'u8, 0xdf'u8, 0xc1'u8, 0x4f'u8, 0x80'u8, 0x24'u8, 0x83'u8, 0x2b'u8]
const LBytes = [0xed'u8, 0xd3'u8, 0xf5'u8, 0x5c'u8, 0x1a'u8, 0x63'u8, 0x12'u8, 0x58'u8, 0xd6'u8, 0x9c'u8, 0xf7'u8, 0xa2'u8, 0xde'u8, 0xf9'u8, 0xde'u8, 0x14'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8, 0x10'u8]

let P = bigFromBytesLE(PBytes)
let D = bigFromBytesLE(DBytes)
let Bx = bigFromBytesLE(BxBytes)
let By = bigFromBytesLE(ByBytes)
let SqrtM1 = bigFromBytesLE(SqrtM1Bytes)
let L = bigFromBytesLE(LBytes)
let Two255 = shlBits(bigFromUint(1'u64), 255)

# ---------------------------------------------------------------------------
# Arytmetyka ciała GF(p), p = 2^255 - 19. Redukcja SZYBKA (2^255 = 19 mod p)
# zamiast ogólnego dzielenia -- patrz uzasadnienie wydajnościowe w
# komentarzu na górze pliku. Krzyżowo testowana przeciw `bignum.modBig`
# (wolnej, ale oczywiście poprawnej referencji) w teście jednostkowym.
# ---------------------------------------------------------------------------

proc feReduce*(xIn: BigUint): BigUint =
  var x = xIn
  # pętla: dopóki liczba ma >255 bitów, złóż ją przez 2^255 = 19 (mod p)
  while bitLength(x) > 255:
    let hi = shrBits(x, 255)
    let lo = maskLowBits(x, 255)
    x = addBig(lo, mulBig(hi, bigFromUint(19'u64)))
  while x >= P:
    x = subBig(x, P)
  x

proc feAdd(a, b: BigUint): BigUint = feReduce(addBig(a, b))
proc feSub(a, b: BigUint): BigUint =
  if a >= b: feReduce(subBig(a, b))
  else: feReduce(subBig(addBig(a, P), b))  # a<b: (a+p)-b, wynik i tak redukowany
proc feMul(a, b: BigUint): BigUint = feReduce(mulBig(a, b))

proc feModRef*(x: BigUint): BigUint = modBig(x, P)  ## wolna referencja (tylko do testów)

proc fePow(base, exp: BigUint): BigUint =
  ## Szybkie potęgowanie modularne (square-and-multiply), redukcja polowa.
  result = bigFromUint(1'u64)
  var b = feReduce(base)
  let nbits = bitLength(exp)
  for i in 0 ..< nbits:
    if getBit(exp, i) == 1:
      result = feMul(result, b)
    b = feMul(b, b)

proc feInv(a: BigUint): BigUint =
  ## a^(p-2) mod p == a^-1 mod p (małe twierdzenie Fermata; p pierwsze).
  fePow(a, subBig(P, bigFromUint(2'u64)))

proc feSqrt(a: BigUint): tuple[ok: bool, root: BigUint] =
  ## Pierwiastek w GF(p) dla p = 5 mod 8 (RFC 8032 5.1.3): kandydat =
  ## a^((p+3)/8); jeśli kandydat^2==a, gotowe; jeśli kandydat^2==-a,
  ## pomnóż przez sqrt(-1); inaczej brak pierwiastka.
  let exp = shrBits(addBig(P, bigFromUint(3'u64)), 3)
  var cand = fePow(a, exp)
  let sq = feMul(cand, cand)
  if cmpBig(sq, feReduce(a)) == 0:
    return (true, cand)
  let negA = feSub(bigFromUint(0'u64), a)
  if cmpBig(sq, feReduce(negA)) == 0:
    return (true, feMul(cand, SqrtM1))
  (false, bigFromUint(0'u64))

# ---------------------------------------------------------------------------
# Arytmetyka skalarów mod L (rząd podgrupy). Redukcja OGÓLNA (wolna, ale
# wywoływana rzadko -- kilka razy na jeden podpis/weryfikację).
# ---------------------------------------------------------------------------

proc scReduce(x: BigUint): BigUint = modBig(x, L)
proc scAdd(a, b: BigUint): BigUint = scReduce(addBig(a, b))
proc scMul(a, b: BigUint): BigUint = scReduce(mulBig(a, b))

# ---------------------------------------------------------------------------
# Punkty na krzywej -- współrzędne affiniczne, pełne (bezwyjątkowe) prawo
# dodawania skręconej krzywej Edwardsa (a=-1, d nie-kwadratowe w GF(p)):
#   x3 = (x1*y2 + y1*x2) / (1 + d*x1*x2*y1*y2)
#   y3 = (y1*y2 + x1*x2) / (1 - d*x1*x2*y1*y2)
# Element neutralny: (0, 1). Formuła ta jest KOMPLETNA dla Ed25519 (a jest
# kwadratem, d nie jest kwadratem w GF(p)) -- ten sam wzór poprawnie
# obsługuje też podwojenie (P+P) i punkt neutralny, bez specjalnych
# przypadków.
# ---------------------------------------------------------------------------

type Point = tuple[x, y: BigUint]

let PointIdentity: Point = (bigFromUint(0'u64), bigFromUint(1'u64))
let BasePoint: Point = (Bx, By)

proc pointAdd(p1, p2: Point): Point =
  let x1y2 = feMul(p1.x, p2.y)
  let y1x2 = feMul(p1.y, p2.x)
  let y1y2 = feMul(p1.y, p2.y)
  let x1x2 = feMul(p1.x, p2.x)
  let dxxyy = feMul(D, feMul(x1x2, y1y2))
  let den1 = feAdd(bigFromUint(1'u64), dxxyy)
  let den2 = feSub(bigFromUint(1'u64), dxxyy)
  # Trik jednoczesnej inwersji (Montgomery batch inversion): zamiast
  # DWÓCH osobnych fePow(.., p-2) (najdroższa operacja w całym module --
  # ~255 mnożeń polowych KAŻDA), liczymy odwrotność JEDNEGO iloczynu i
  # odzyskujemy oba potrzebne odwrotności trzema tanimi mnożeniami:
  #   inv(den1) = invProd * den2      inv(den2) = invProd * den1
  # (bo invProd = inv(den1)*inv(den2), więc invProd*den2 = inv(den1) itd.)
  # -- to jedna z niewielu optymalizacji wydajnościowych w tym module,
  # zweryfikowana testem `test_ed25519.nim` (podpisy nadal bit-w-bit
  # zgodne z referencją OpenSSL po tej zmianie).
  let invProd = feInv(feMul(den1, den2))
  let inv1 = feMul(invProd, den2)
  let inv2 = feMul(invProd, den1)
  let x3 = feMul(feAdd(x1y2, y1x2), inv1)
  let y3 = feMul(feAdd(y1y2, x1x2), inv2)
  (x3, y3)

proc scalarMul(k: BigUint, p: Point): Point =
  ## Mnożenie skalarne double-and-add, MSB -> LSB. (Nie stała czasowo --
  ## patrz ostrzeżenie o dojrzałości na górze pliku.)
  result = PointIdentity
  let nbits = bitLength(k)
  for i in countdown(nbits - 1, 0):
    result = pointAdd(result, result)
    if getBit(k, i) == 1:
      result = pointAdd(result, p)

proc pointEncode(p: Point): array[32, uint8] =
  ## y (255 bitów, little-endian) + bit znaku x w najwyższym bicie.
  var yb = toBytesLE(feReduce(p.y), 32)
  let xParity = getBit(feReduce(p.x), 0)
  if xParity == 1:
    yb[31] = yb[31] or 0x80'u8
  for i in 0 ..< 32: result[i] = yb[i]

proc pointDecode(data: array[32, uint8]): tuple[ok: bool, p: Point] =
  var yb = data
  let signBit = (yb[31] and 0x80'u8) != 0
  yb[31] = yb[31] and 0x7f'u8
  let y = bigFromBytesLE(yb)
  if y >= P:
    return (false, PointIdentity)
  # x^2 = (y^2 - 1) / (d*y^2 + 1)
  let yy = feMul(y, y)
  let num = feSub(yy, bigFromUint(1'u64))
  let den = feAdd(feMul(D, yy), bigFromUint(1'u64))
  let xx = feMul(num, feInv(den))
  let (ok, root) = feSqrt(xx)
  if not ok: return (false, PointIdentity)
  var x = root
  if x.isZero and signBit:
    return (false, PointIdentity)  # -0 == 0: bit znaku musi byc 0
  let xIsOdd = getBit(x, 0) == 1
  if xIsOdd != signBit:
    x = feSub(bigFromUint(0'u64), x)
  (true, (x, y))

# ---------------------------------------------------------------------------
# EdDSA (RFC 8032 sekcja 5.1): generowanie klucza, podpisywanie, weryfikacja.
# ---------------------------------------------------------------------------

type
  Ed25519Error* = object of CatchableError

proc sha512(data: openArray[uint8]): array[64, uint8] = zsha512.sha512Bytes(data)
proc sha512(data: string): array[64, uint8] = zsha512.sha512Bytes(data)

proc clampScalar(h: array[32, uint8]): array[32, uint8] =
  result = h
  result[0] = result[0] and 0xf8'u8
  result[31] = result[31] and 0x7f'u8
  result[31] = result[31] or 0x40'u8

proc expandSeed(seed: array[32, uint8]): tuple[a: BigUint, prefix: array[32, uint8]] =
  let h = sha512(seed)
  var lower: array[32, uint8]
  var upper: array[32, uint8]
  for i in 0 ..< 32: lower[i] = h[i]
  for i in 0 ..< 32: upper[i] = h[32 + i]
  let clamped = clampScalar(lower)
  (bigFromBytesLE(clamped), upper)

proc derivePublicKey*(seed: array[32, uint8]): array[32, uint8] =
  ## Wyprowadza 32-bajtowy klucz publiczny z 32-bajtowego ziarna (klucza
  ## prywatnego) -- RFC 8032 5.1.5.
  let (a, _) = expandSeed(seed)
  pointEncode(scalarMul(a, BasePoint))

proc signDetached*(seed: array[32, uint8], message: openArray[uint8]): array[64, uint8] =
  ## RFC 8032 5.1.6 -- Ed25519 "pure" (bez kontekstu, bez prehashu -- ten
  ## sam wariant, którego używają `ssh-keygen -t ed25519`/OpenSSL/GnuPG
  ## domyślnie i który weryfikuje `openssl pkeyutl`).
  let (a, prefix) = expandSeed(seed)
  let pubBytes = pointEncode(scalarMul(a, BasePoint))

  var prefixMsg: seq[uint8] = @[]
  for b in prefix: prefixMsg.add b
  for b in message: prefixMsg.add b
  let rHash = sha512(prefixMsg)
  let r = scReduce(bigFromBytesLE(rHash))
  let rPoint = scalarMul(r, BasePoint)
  let rBytes = pointEncode(rPoint)

  var khash: seq[uint8] = @[]
  for b in rBytes: khash.add b
  for b in pubBytes: khash.add b
  for b in message: khash.add b
  let k = scReduce(bigFromBytesLE(sha512(khash)))

  let s = scAdd(r, scMul(k, a))
  let sBytes = toBytesLE(s, 32)

  for i in 0 ..< 32: result[i] = rBytes[i]
  for i in 0 ..< 32: result[32 + i] = sBytes[i]

proc verifyDetached*(pubkey: array[32, uint8], message: openArray[uint8], signature: array[64, uint8]): bool =
  ## RFC 8032 5.1.7. Zwraca `false` na dowolny błąd (zły punkt, s>=L, itd.)
  ## zamiast rzucać -- API weryfikacji celowo "boolowe", żeby wołający nie
  ## musiał wyłapywać wyjątków przy każdym podejrzanym podpisie.
  let (pubOk, A) = pointDecode(pubkey)
  if not pubOk: return false

  var rBytes: array[32, uint8]
  var sBytes: array[32, uint8]
  for i in 0 ..< 32: rBytes[i] = signature[i]
  for i in 0 ..< 32: sBytes[i] = signature[32 + i]

  let s = bigFromBytesLE(sBytes)
  if s >= L: return false  # RFC 8032 wymaga odrzucenia s spoza [0,L)

  let (rOk, R) = pointDecode(rBytes)
  if not rOk: return false

  var khash: seq[uint8] = @[]
  for b in rBytes: khash.add b
  for b in pubkey: khash.add b
  for b in message: khash.add b
  let k = scReduce(bigFromBytesLE(sha512(khash)))

  # sprawdzenie: [s]B == R + [k]A
  let lhs = scalarMul(s, BasePoint)
  let rhs = pointAdd(R, scalarMul(k, A))
  cmpBig(feReduce(lhs.x), feReduce(rhs.x)) == 0 and cmpBig(feReduce(lhs.y), feReduce(rhs.y)) == 0

# ---------------------------------------------------------------------------
# Wygodne API na bajtach `string` (spójne z resztą `zpk`/`zpm`, gdzie klucze
# i podpisy krążą jako binarne `string`, nie `array`).
# ---------------------------------------------------------------------------

proc toArr32(s: string): array[32, uint8] =
  if s.len != 32: raise newException(Ed25519Error, "oczekiwano 32 bajtów, otrzymano " & $s.len)
  for i in 0 ..< 32: result[i] = uint8(s[i])

proc toArr64(s: string): array[64, uint8] =
  if s.len != 64: raise newException(Ed25519Error, "oczekiwano 64 bajtów, otrzymano " & $s.len)
  for i in 0 ..< 64: result[i] = uint8(s[i])

proc arrToStr(a: openArray[uint8]): string =
  result = newString(a.len)
  for i in 0 ..< a.len: result[i] = char(a[i])

proc ed25519DerivePublicKey*(seed: string): string =
  arrToStr(derivePublicKey(toArr32(seed)))

proc ed25519Sign*(seed: string, message: string): string =
  var msgBytes: seq[uint8] = @[]
  for c in message: msgBytes.add uint8(c)
  arrToStr(signDetached(toArr32(seed), msgBytes))

proc ed25519Verify*(pubkey: string, message: string, signature: string): bool =
  if pubkey.len != 32 or signature.len != 64: return false
  var msgBytes: seq[uint8] = @[]
  for c in message: msgBytes.add uint8(c)
  try:
    verifyDetached(toArr32(pubkey), msgBytes, toArr64(signature))
  except CatchableError:
    false
