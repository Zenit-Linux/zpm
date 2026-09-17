type BigUint* = seq[uint32]  ## little-endian, każdy element < 2^16 (po normalize)

const LimbBits = 16
const LimbMask = 0xffff'u32

proc normalize(a: var BigUint) =
  while a.len > 1 and a[^1] == 0: a.setLen(a.len - 1)
  if a.len == 0: a.add 0'u32

proc trimmed(a: BigUint): BigUint =
  result = a
  normalize(result)

proc isZero*(a: BigUint): bool =
  for limb in a:
    if limb != 0: return false
  true

proc bigFromUint*(x: uint64): BigUint =
  var v = x
  result = @[]
  if v == 0: return @[0'u32]
  while v > 0:
    result.add uint32(v and 0xffff'u64)
    v = v shr LimbBits

proc bigFromBytesLE*(data: openArray[uint8]): BigUint =
  ## Interpretuje `data` jako liczbę little-endian (bajt 0 = najmniej
  ## znaczący).
  result = @[]
  var i = 0
  while i < data.len:
    var limb: uint32 = uint32(data[i])
    if i + 1 < data.len: limb = limb or (uint32(data[i+1]) shl 8)
    result.add limb
    i += 2
  normalize(result)

proc toBytesLE*(a: BigUint, outLen: int): seq[uint8] =
  ## Zwraca `outLen` bajtów little-endian. Rzuca, jeśli `a` się nie
  ## mieści (chroni przed cichym obcięciem klucza/podpisu).
  result = newSeq[uint8](outLen)
  for i in 0 ..< a.len:
    let lo = uint8(a[i] and 0xff)
    let hi = uint8((a[i] shr 8) and 0xff)
    let bytePos = i * 2
    if bytePos < outLen: result[bytePos] = lo
    elif lo != 0: raise newException(ValueError, "bignum.toBytesLE: liczba za duża na " & $outLen & " bajtów")
    if bytePos + 1 < outLen: result[bytePos + 1] = hi
    elif hi != 0: raise newException(ValueError, "bignum.toBytesLE: liczba za duża na " & $outLen & " bajtów")

proc cmpBig*(aIn, bIn: BigUint): int =
  let a = trimmed(aIn)
  let b = trimmed(bIn)
  if a.len != b.len: return (if a.len < b.len: -1 else: 1)
  for i in countdown(a.len - 1, 0):
    if a[i] != b[i]: return (if a[i] < b[i]: -1 else: 1)
  0

proc `<`*(a, b: BigUint): bool = cmpBig(a, b) < 0
proc `<=`*(a, b: BigUint): bool = cmpBig(a, b) <= 0
proc `==`*(a, b: BigUint): bool = cmpBig(a, b) == 0
proc `>=`*(a, b: BigUint): bool = cmpBig(a, b) >= 0
proc `>`*(a, b: BigUint): bool = cmpBig(a, b) > 0

proc addBig*(a, b: BigUint): BigUint =
  let n = max(a.len, b.len)
  result = newSeq[uint32](n + 1)
  var carry: uint32 = 0
  for i in 0 ..< n:
    let av = if i < a.len: a[i] else: 0'u32
    let bv = if i < b.len: b[i] else: 0'u32
    let s = av + bv + carry
    result[i] = s and LimbMask
    carry = s shr LimbBits
  result[n] = carry
  normalize(result)

proc subBig*(a, b: BigUint): BigUint =
  ## Zakłada a >= b (inaczej rzuca -- w tym module NIE MA liczb ujemnych,
  ## całe wyższe warstwy [pole/skalar] są napisane tak, by nigdy nie
  ## odejmować większej od mniejszej).
  if a < b: raise newException(ValueError, "bignum.subBig: a < b (odjemna mniejsza od odjemnika)")
  result = newSeq[uint32](a.len)
  var borrow: int32 = 0
  for i in 0 ..< a.len:
    let bv = if i < b.len: int32(b[i]) else: 0'i32
    var d = int32(a[i]) - bv - borrow
    if d < 0:
      d += int32(LimbMask) + 1
      borrow = 1
    else:
      borrow = 0
    result[i] = uint32(d)
  normalize(result)

proc mulBig*(a, b: BigUint): BigUint =
  let ta = trimmed(a)
  let tb = trimmed(b)
  if ta.isZero or tb.isZero: return @[0'u32]
  result = newSeq[uint32](ta.len + tb.len)
  for i in 0 ..< ta.len:
    var carry: uint64 = 0
    let av = uint64(ta[i])
    for j in 0 ..< tb.len:
      let t = uint64(result[i+j]) + av * uint64(tb[j]) + carry
      result[i+j] = uint32(t and 0xffff'u64)
      carry = t shr LimbBits
    var k = i + tb.len
    while carry > 0:
      let t = uint64(result[k]) + carry
      result[k] = uint32(t and 0xffff'u64)
      carry = t shr LimbBits
      inc k
  normalize(result)

proc bitLength*(aIn: BigUint): int =
  let a = trimmed(aIn)
  if a.isZero: return 0
  var top = a[^1]
  var bits = (a.len - 1) * LimbBits
  while top > 0:
    inc bits
    top = top shr 1
  bits

proc getBit*(a: BigUint, i: int): int =
  let limbIdx = i div LimbBits
  if limbIdx >= a.len: return 0
  int((a[limbIdx] shr (i mod LimbBits)) and 1'u32)

proc shrBits*(a: BigUint, n: int): BigUint =
  if n <= 0: return a
  let limbShift = n div LimbBits
  let bitShift = n mod LimbBits
  if limbShift >= a.len: return @[0'u32]
  var tmp = newSeq[uint32](a.len - limbShift)
  for i in 0 ..< tmp.len: tmp[i] = a[i + limbShift]
  if bitShift > 0:
    for i in 0 ..< tmp.len:
      let lo = tmp[i] shr bitShift
      let hiSrc = if i + 1 < tmp.len: tmp[i+1] else: 0'u32
      let hi = (hiSrc shl (LimbBits - bitShift)) and LimbMask
      tmp[i] = (lo or hi) and LimbMask
  normalize(tmp)
  tmp

proc shlBits*(a: BigUint, n: int): BigUint =
  if n <= 0: return trimmed(a)
  let limbShift = n div LimbBits
  let bitShift = n mod LimbBits
  var tmp = newSeq[uint32](a.len + limbShift + 1)
  for i in 0 ..< a.len:
    tmp[i + limbShift] = a[i]
  if bitShift > 0:
    var carry: uint32 = 0
    for i in limbShift ..< tmp.len:
      let v = tmp[i]
      tmp[i] = ((v shl bitShift) or carry) and LimbMask
      carry = v shr (LimbBits - bitShift)
  normalize(tmp)
  tmp

proc maskLowBits*(a: BigUint, n: int): BigUint =
  ## Zwraca a mod 2^n (najniższe n bitów).
  if n <= 0: return @[0'u32]
  let fullLimbs = n div LimbBits
  let extraBits = n mod LimbBits
  var tmp: BigUint = @[]
  for i in 0 ..< fullLimbs:
    tmp.add (if i < a.len: a[i] else: 0'u32)
  if extraBits > 0:
    let topLimb = if fullLimbs < a.len: a[fullLimbs] else: 0'u32
    tmp.add topLimb and ((1'u32 shl extraBits) - 1)
  if tmp.len == 0: tmp.add 0'u32
  normalize(tmp)
  tmp

proc divModBig*(aIn, bIn: BigUint): tuple[q, r: BigUint] =
  ## Dzielenie długie bit po bicie (proste, oczywiście poprawne; liczby w
  ## naszym zastosowaniu mają co najwyżej ~1000 bitów, więc to i tak
  ## ułamek milisekundy). Rzuca przy dzieleniu przez zero.
  let b = trimmed(bIn)
  if b.isZero: raise newException(ValueError, "bignum.divModBig: dzielenie przez zero")
  let a = trimmed(aIn)
  var quotient: BigUint = @[0'u32]
  var remainder: BigUint = @[0'u32]
  let nbits = bitLength(a)
  for i in countdown(nbits - 1, 0):
    remainder = shlBits(remainder, 1)
    if getBit(a, i) == 1:
      remainder = addBig(remainder, @[1'u32])
    if remainder >= b:
      remainder = subBig(remainder, b)
      quotient = addBig(shlBits(quotient, 1), @[1'u32])
    else:
      quotient = shlBits(quotient, 1)
  normalize(quotient)
  normalize(remainder)
  (quotient, remainder)

proc modBig*(a, m: BigUint): BigUint =
  divModBig(a, m).r
