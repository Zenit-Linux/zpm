type
  BitWriter* = object
    data*: string
    cur: uint8
    nbits: int

  BitReader* = object
    data: string
    pos*: int      ## pozycja w BAJTACH (następny nieprzeczytany bajt w `data`)
    cur: uint8
    nbits: int    ## ile bitów `cur` zostało jeszcze nieprzeczytanych

proc initBitWriter*(): BitWriter = BitWriter(data: "", cur: 0, nbits: 0)

proc writeBit*(w: var BitWriter, bit: int) =
  w.cur = w.cur or (uint8(bit and 1) shl w.nbits)
  inc w.nbits
  if w.nbits == 8:
    w.data.add char(w.cur)
    w.cur = 0
    w.nbits = 0

proc writeBits*(w: var BitWriter, value: uint32, count: int) =
  ## Zapisuje `count` najmłodszych bitów `value`, od najmłodszego (LSB
  ## first) -- do pól o stałej szerokości (np. surowe długości/odległości).
  for i in 0 ..< count:
    w.writeBit(int((value shr i) and 1'u32))

proc writeHuffCode*(w: var BitWriter, code: uint32, length: int) =
  ## Zapisuje KOD HUFFMANA -- MSB-first (od najstarszego bitu kodu), jak
  ## wymaga standardowa interpretacja kodów kanonicznych (krótsze kody
  ## muszą być jednoznacznym prefiksem dłuższych TYLKO przy takiej
  ## kolejności transmisji; to samo robi DEFLATE). To CELOWA różnica
  ## względem `writeBits` (pola o stałej szerokości, LSB-first) -- dwa
  ## różne zastosowania bitowego zapisu w tym samym module.
  for i in countdown(length - 1, 0):
    w.writeBit(int((code shr i) and 1'u32))

proc flush*(w: var BitWriter) =
  if w.nbits > 0:
    w.data.add char(w.cur)
    w.cur = 0
    w.nbits = 0

proc initBitReader*(data: string): BitReader = BitReader(data: data, pos: 0, cur: 0, nbits: 0)

proc readBit*(r: var BitReader): int =
  if r.nbits == 0:
    if r.pos >= r.data.len:
      raise newException(ValueError, "bitio: nieoczekiwany koniec strumienia bitów")
    r.cur = uint8(r.data[r.pos])
    inc r.pos
    r.nbits = 8
  result = int(r.cur and 1)
  r.cur = r.cur shr 1
  dec r.nbits

proc readBits*(r: var BitReader, count: int): uint32 =
  result = 0
  for i in 0 ..< count:
    result = result or (uint32(r.readBit()) shl i)
