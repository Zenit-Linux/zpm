import std/[os, streams, algorithm, strutils]
import ./zsha256
import ./zlz
import ./zlz2

const
  ZpkaMagic = "ZPKA"
  ZpkaVersion = 2'u8
  ZpkaFooterMagic = "ZEND"
  FooterSize = 4 + 4 + 8  # magic + entryCount(u32) + tocOffset(u64)
  FlagCompressed = 0x01'u8      # ZLZ1 (caly plik naraz)
  FlagCompressedZlz2 = 0x02'u8  # ZLZ2 (blokowo + Huffman)
  StreamThreshold* = 4 * 1024 * 1024  # 4 MiB -- powyzej: streaming ZLZ2

type
  ArchiveError* = object of CatchableError

  ArchiveEntry* = object
    path*: string
    flags*: uint8
    dataOffset*: uint64
    compSize*: uint64
    rawSize*: uint64
    sha256*: array[32, uint8]

  ArchiveIndex* = object
    path*: string          # ścieżka do samego pliku .zpk/.zpm
    entries*: seq[ArchiveEntry]

proc sha256HexOf(a: array[32, uint8]): string =
  const hexChars = "0123456789abcdef"
  result = newStringOfCap(64)
  for b in a:
    result.add hexChars[int(b) shr 4]
    result.add hexChars[int(b) and 0x0f]

proc sha256BytesOfString(s: string): array[32, uint8] =
  let hex = sha256Hex(s)
  for i in 0 ..< 32:
    result[i] = uint8(parseHexInt(hex[i*2 .. i*2+1]))

proc sha256BytesOfState(s: var zsha256.Sha256State): array[32, uint8] =
  let hex = s.finalHex()
  for i in 0 ..< 32:
    result[i] = uint8(parseHexInt(hex[i*2 .. i*2+1]))

proc putU16(s: var string, v: uint16) =
  s.add char(v and 0xff); s.add char((v shr 8) and 0xff)
proc putU32(s: var string, v: uint32) =
  for i in 0 ..< 4: s.add char((v shr (i*8)) and 0xff)
proc putU64(s: var string, v: uint64) =
  for i in 0 ..< 8: s.add char((v shr (i*8)) and 0xff)

proc readU16(s: Stream): uint16 =
  var b0, b1: uint8
  b0 = uint8(s.readChar()); b1 = uint8(s.readChar())
  uint16(b0) or (uint16(b1) shl 8)
proc readU32(s: Stream): uint32 =
  var v: uint32 = 0
  for i in 0 ..< 4: v = v or (uint32(uint8(s.readChar())) shl (i*8))
  v
proc readU64(s: Stream): uint64 =
  var v: uint64 = 0
  for i in 0 ..< 8: v = v or (uint64(uint8(s.readChar())) shl (i*8))
  v

proc isZpkaFile*(path: string): bool =
  ## Wykrywa NOWY format (magic "ZPKA" na początku pliku) -- używane do
  ## rozróżnienia od starszych archiwów `.zpk` opartych o `tar` (patrz
  ## `zpk migrate`/`zpm`'s odpowiednik do jednorazowego przepakowania).
  if not fileExists(path): return false
  var f: File
  if not open(f, path, fmRead): return false
  defer: close(f)
  var hdr: array[4, char]
  let n = readBuffer(f, hdr[0].addr, 4)
  n == 4 and hdr[0] == 'Z' and hdr[1] == 'P' and hdr[2] == 'K' and hdr[3] == 'A'

type PendingFile* = object
  relPath*: string     ## ścieżka względna w archiwum (np. "usr/bin/foo")
  absPath*: string      ## ścieżka źródłowa na dysku, z której czytamy bajty

proc compressSmallBest(raw: string): tuple[flags: uint8, payload: string] =
  ## Dla plików <= StreamThreshold: próbuje SUROWO/ZLZ1/ZLZ2 i wybiera
  ## najmniejszy wynik.
  var bestFlags = 0'u8
  var best = raw
  let z1 = zlz.compress(raw)
  if z1.len < best.len:
    best = z1
    bestFlags = FlagCompressed
  var rawBytes = newSeq[uint8](raw.len)
  for i in 0 ..< raw.len: rawBytes[i] = uint8(raw[i])
  let z2 = zlz2.compressBlock(rawBytes)
  if z2.len < best.len:
    best = z2
    bestFlags = FlagCompressedZlz2
  (bestFlags, best)

proc writeArchive*(outPath: string, files: seq[PendingFile]): seq[tuple[path, sha256: string]] =
  ## Buduje archiwum ZPKA w `outPath` z podanych plików. Zwraca listę
  ## (ścieżka, sha256 hex) w kolejności WEJŚCIOWEJ -- do zbudowania
  ## manifestu przez wołającego.
  var sorted = files
  sorted.sort(proc(a, b: PendingFile): int = cmp(a.relPath, b.relPath))

  var fh: File
  if not open(fh, outPath, fmWrite):
    raise newException(ArchiveError, "nie można utworzyć " & outPath)
  defer: close(fh)

  var header = ZpkaMagic
  header.add char(ZpkaVersion)
  header.add char(0'u8)  # flagi globalne
  discard writeBuffer(fh, header[0].addr, header.len)

  var offset = uint64(header.len)
  var entries: seq[ArchiveEntry] = @[]
  result = @[]

  for f in sorted:
    let srcSize = getFileSize(f.absPath)
    var entry = ArchiveEntry(path: f.relPath, dataOffset: offset)

    if srcSize <= StreamThreshold:
      let raw = readFile(f.absPath)
      let digestHex = sha256Hex(raw)
      result.add (f.relPath, digestHex)
      let (flags, payload) = compressSmallBest(raw)
      entry.flags = flags
      entry.compSize = uint64(payload.len)
      entry.rawSize = uint64(raw.len)
      entry.sha256 = sha256BytesOfString(raw)
      if payload.len > 0:
        discard writeBuffer(fh, payload[0].unsafeAddr, payload.len)
      offset += uint64(payload.len)
    else:
      # STRUMIENIOWO: czytamy i kompresujemy blokami zlz2.DefaultBlockSize
      # -- w pamięci trzymamy naraz tylko JEDEN blok, nie cały plik.
      var src: File
      if not open(src, f.absPath, fmRead):
        raise newException(ArchiveError, "nie można otworzyć źródła " & f.absPath)
      defer: close(src)
      var hashState = zsha256.initSha256()
      var totalRaw: uint64 = 0
      var totalComp: uint64 = 0
      var chunk = newString(zlz2.DefaultBlockSize)
      while true:
        let n = readBuffer(src, chunk[0].addr, chunk.len)
        if n <= 0: break
        hashState.update(toOpenArrayByte(chunk, 0, n - 1))
        let compressed = zlz2.compressBlock(toOpenArrayByte(chunk, 0, n - 1))
        discard writeBuffer(fh, compressed[0].unsafeAddr, compressed.len)
        totalRaw += uint64(n)
        totalComp += uint64(compressed.len)
        if n < chunk.len: break
      entry.flags = FlagCompressedZlz2
      entry.compSize = totalComp
      entry.rawSize = totalRaw
      entry.sha256 = sha256BytesOfState(hashState)
      result.add (f.relPath, sha256HexOf(entry.sha256))
      offset += totalComp

    entries.add entry

  # TOC
  let tocOffset = offset
  var toc = newStringOfCap(entries.len * 64)
  for e in entries:
    putU16(toc, uint16(e.path.len))
    toc.add e.path
    toc.add char(e.flags)
    putU64(toc, e.dataOffset)
    putU64(toc, e.compSize)
    putU64(toc, e.rawSize)
    for b in e.sha256: toc.add char(b)
  if toc.len > 0:
    discard writeBuffer(fh, toc[0].unsafeAddr, toc.len)

  var footer = ZpkaFooterMagic
  putU32(footer, uint32(entries.len))
  putU64(footer, tocOffset)
  discard writeBuffer(fh, footer[0].unsafeAddr, footer.len)

proc readIndex*(path: string): ArchiveIndex =
  ## Wczytuje WYŁĄCZNIE stopkę + TOC (nie dotyka bloków danych) -- lekka
  ## operacja niezależna od rozmiaru ładunku archiwum.
  if not fileExists(path):
    raise newException(ArchiveError, "nie znaleziono " & path)
  let fileSize = getFileSize(path)
  if fileSize < int64(6 + FooterSize):
    raise newException(ArchiveError, path & " jest za mały, by być poprawnym archiwum ZPKA")
  var s = newFileStream(path, fmRead)
  if s == nil:
    raise newException(ArchiveError, "nie można otworzyć " & path)
  defer: s.close()

  var hdr: array[4, char]
  discard s.readData(hdr[0].addr, 4)
  if hdr[0] != 'Z' or hdr[1] != 'P' or hdr[2] != 'K' or hdr[3] != 'A':
    raise newException(ArchiveError, path & " nie jest archiwum ZPKA (zły magic nagłówka)")
  discard s.readUint8()  # wersja -- na razie ignorowana (jedna wersja)
  discard s.readUint8()  # flagi globalne

  s.setPosition(int(fileSize - FooterSize))
  var fmagic: array[4, char]
  discard s.readData(fmagic[0].addr, 4)
  if fmagic[0] != 'Z' or fmagic[1] != 'E' or fmagic[2] != 'N' or fmagic[3] != 'D':
    raise newException(ArchiveError, path & ": brak poprawnej stopki (uszkodzone/nie-ZPKA archiwum)")
  let entryCount = readU32(s)
  let tocOffset = readU64(s)
  if tocOffset >= uint64(fileSize):
    raise newException(ArchiveError, path & ": nieprawidłowy offset TOC w stopce")

  s.setPosition(int(tocOffset))
  result.path = path
  result.entries = @[]
  for _ in 0 ..< entryCount:
    let plen = readU16(s)
    var pathBuf = newString(int(plen))
    if plen > 0:
      discard s.readData(pathBuf[0].addr, int(plen))
    let flags = uint8(s.readChar())
    let dataOffset = readU64(s)
    let compSize = readU64(s)
    let rawSize = readU64(s)
    var digest: array[32, uint8]
    for i in 0 ..< 32: digest[i] = uint8(s.readChar())
    result.entries.add ArchiveEntry(
      path: pathBuf, flags: flags, dataOffset: dataOffset,
      compSize: compSize, rawSize: rawSize, sha256: digest
    )

proc findEntry*(idx: ArchiveIndex, path: string): int =
  ## Zwraca indeks wpisu o danej ścieżce w `idx.entries`, albo -1.
  for i, e in idx.entries:
    if e.path == path: return i
  -1

proc readRawPayload(idx: ArchiveIndex, entry: ArchiveEntry): string =
  var f: File
  if not open(f, idx.path, fmRead):
    raise newException(ArchiveError, "nie można otworzyć " & idx.path)
  defer: close(f)
  setFilePos(f, int64(entry.dataOffset))
  result = newString(int(entry.compSize))
  if entry.compSize > 0:
    let n = readBuffer(f, result[0].addr, result.len)
    if n != result.len:
      raise newException(ArchiveError, idx.path & ": nieoczekiwany koniec pliku przy czytaniu '" & entry.path & "'")

proc decompressPayload(raw: string, entry: ArchiveEntry, idx: ArchiveIndex): string =
  if (entry.flags and FlagCompressedZlz2) != 0:
    result = newStringOfCap(int(entry.rawSize))
    var pos = 0
    while pos < raw.len:
      result.add zlz2.decompressBlock(raw, pos)
  elif (entry.flags and FlagCompressed) != 0:
    result = zlz.decompress(raw, int(entry.rawSize))
  else:
    result = raw
  if uint64(result.len) != entry.rawSize:
    raise newException(ArchiveError, idx.path & ": rozmiar po dekompresji '" & entry.path &
      "' nie zgadza się z TOC (uszkodzone archiwum)")

proc extractEntry*(idx: ArchiveIndex, entry: ArchiveEntry, verifyChecksum: bool = true): string =
  ## Zwraca ZDEKOMPRESOWANĄ zawartość JEDNEGO wpisu, bez dotykania
  ## pozostałych bloków danych w archiwum. Dla bardzo dużych plików
  ## (ZLZ2, > StreamThreshold przy budowaniu) woli `extractEntryToFile`
  ## -- ta funkcja trzyma całą zdekompresowaną zawartość w pamięci.
  let raw = readRawPayload(idx, entry)
  result = decompressPayload(raw, entry, idx)
  if verifyChecksum:
    let actual = sha256BytesOfString(result)
    if actual != entry.sha256:
      raise newException(ArchiveError, idx.path & ": suma sha256 wpisu '" & entry.path &
        "' nie zgadza się z TOC (uszkodzone archiwum)")

proc extractEntryToFile*(idx: ArchiveIndex, entry: ArchiveEntry, destPath: string, verifyChecksum: bool = true) =
  ## Jak `extractEntry`, ale pisze WPROST do pliku `destPath`. Dla wpisów
  ## ZLZ2 (pliki > StreamThreshold przy budowaniu) dekompresuje i pisze
  ## BLOK PO BLOKU (z bieżąco liczoną sumą sha256), więc szczytowe
  ## zużycie pamięci to skompresowany rozmiar wpisu + jeden blok
  ## (`zlz2.DefaultBlockSize`, domyślnie 1 MiB) -- NIE cały rozpakowany
  ## plik. Dla wpisów surowych/ZLZ1 (małe pliki z definicji, patrz
  ## `StreamThreshold`) po prostu deleguje do `extractEntry` + zapis --
  ## te formaty nie mają struktury blokowej, więc i tak trzeba mieć
  ## całość w pamięci; to celowo akceptowalne, bo dotyczy tylko plików
  ## <= StreamThreshold.
  createDir(parentDir(destPath))
  if (entry.flags and FlagCompressedZlz2) != 0:
    let raw = readRawPayload(idx, entry)
    var destFile: File
    if not open(destFile, destPath, fmWrite):
      raise newException(ArchiveError, "nie można utworzyć " & destPath)
    defer: close(destFile)
    var hashState = zsha256.initSha256()
    var pos = 0
    var produced: uint64 = 0
    while pos < raw.len:
      let chunk = zlz2.decompressBlock(raw, pos)
      if chunk.len > 0:
        discard writeBuffer(destFile, chunk[0].unsafeAddr, chunk.len)
        hashState.update(chunk)
      produced += uint64(chunk.len)
    if produced != entry.rawSize:
      raise newException(ArchiveError, idx.path & ": rozmiar po dekompresji '" & entry.path &
        "' nie zgadza się z TOC (uszkodzone archiwum)")
    if verifyChecksum:
      let actual = sha256BytesOfState(hashState)
      if actual != entry.sha256:
        raise newException(ArchiveError, idx.path & ": suma sha256 wpisu '" & entry.path &
          "' nie zgadza się z TOC (uszkodzone archiwum)")
  else:
    let content = extractEntry(idx, entry, verifyChecksum)
    writeFile(destPath, content)

proc extractMember*(path, memberPath: string): tuple[ok: bool, content: string, err: string] =
  ## Odpowiednik starego `tar -xOf plik.zpk manifest.json` -- czyta i
  ## dekompresuje TYLKO jeden, konkretny człon, bez dotykania reszty
  ## archiwum (w praktyce: bez rozpakowywania niczego innego na dysk).
  try:
    let idx = readIndex(path)
    let i = findEntry(idx, memberPath)
    if i < 0:
      return (false, "", "'" & memberPath & "' nie istnieje w archiwum " & path)
    (true, extractEntry(idx, idx.entries[i]), "")
  except ArchiveError as e:
    (false, "", e.msg)
  except CatchableError as e:
    (false, "", "błąd odczytu " & path & ": " & e.msg)

proc listMembers*(path: string): tuple[ok: bool, members: seq[string], err: string] =
  try:
    let idx = readIndex(path)
    var members: seq[string] = @[]
    for e in idx.entries: members.add e.path
    (true, members, "")
  except ArchiveError as e:
    (false, @[], e.msg)
  except CatchableError as e:
    (false, @[], "błąd odczytu " & path & ": " & e.msg)

proc extractSelected*(path, destDir: string, members: seq[string]): tuple[ok: bool, err: string] =
  ## Rozpakowuje WYŁĄCZNIE ścieżki z `members` (allowlist) do `destDir` --
  ## odpowiednik `tar -xf plik -C dest -- p1 p2 ...`. Kluczowe dla
  ## bezpieczeństwa instalacji: nawet jeśli archiwum fizycznie zawiera
  ## dodatkowe przemycone pliki, TYLKO wpisy z `members` (allowlista z
  ## manifestu) trafiają na dysk. Duże pliki (ZLZ2) rozpakowywane
  ## strumieniowo przez `extractEntryToFile` -- patrz tam.
  try:
    let idx = readIndex(path)
    for m in members:
      let i = findEntry(idx, m)
      if i < 0:
        return (false, "brak w archiwum wymaganego pliku: " & m)
      extractEntryToFile(idx, idx.entries[i], destDir / m)
    (true, "")
  except ArchiveError as e:
    (false, e.msg)
  except CatchableError as e:
    (false, "błąd rozpakowywania " & path & ": " & e.msg)

proc extractAll*(path, destDir: string): tuple[ok: bool, err: string] =
  try:
    let idx = readIndex(path)
    var members: seq[string] = @[]
    for e in idx.entries: members.add e.path
    extractSelected(path, destDir, members)
  except ArchiveError as e:
    (false, e.msg)
  except CatchableError as e:
    (false, "błąd rozpakowywania " & path & ": " & e.msg)

# ---------------------------------------------------------------------------
# zpk inspect -- podgląd zawartości archiwum (lista/rozmiary/współczynnik
# kompresji) BEZ instalacji, wyłącznie z TOC.
# ---------------------------------------------------------------------------

type
  InspectEntry* = object
    path*: string
    rawSize*: uint64
    compSize*: uint64
    isDir*: bool  # zarezerwowane -- ZPKA nie ma osobnych wpisów katalogów
    methodName*: string  # "surowo" / "ZLZ1" / "ZLZ2"

  InspectReport* = object
    path*: string
    entries*: seq[InspectEntry]
    totalRaw*: uint64
    totalComp*: uint64

proc methodNameOf(flags: uint8): string =
  if (flags and FlagCompressedZlz2) != 0: "ZLZ2"
  elif (flags and FlagCompressed) != 0: "ZLZ1"
  else: "surowo"

proc inspectArchive*(path: string): tuple[ok: bool, report: InspectReport, err: string] =
  ## Czyta WYŁĄCZNIE TOC (jak `listMembers`) -- nie dotyka ładunku, więc
  ## działa błyskawicznie nawet dla wielkich archiwów.
  try:
    let idx = readIndex(path)
    var report = InspectReport(path: path)
    for e in idx.entries:
      report.entries.add InspectEntry(
        path: e.path, rawSize: e.rawSize, compSize: e.compSize,
        isDir: false, methodName: methodNameOf(e.flags))
      report.totalRaw += e.rawSize
      report.totalComp += e.compSize
    (true, report, "")
  except ArchiveError as e:
    (false, InspectReport(), e.msg)
  except CatchableError as e:
    (false, InspectReport(), "błąd odczytu " & path & ": " & e.msg)

# ---------------------------------------------------------------------------
# zpk diff -- różnice między dwoma wersjami pakietu, WYŁĄCZNIE z TOC
# (ścieżka + sha256 + rozmiar), bez ekstrakcji ani jednego bajtu ładunku.
# ---------------------------------------------------------------------------

type
  DiffKind* = enum dkAdded, dkRemoved, dkChanged, dkUnchanged
  DiffEntry* = object
    path*: string
    kind*: DiffKind
    oldSize*, newSize*: uint64
    oldSha*, newSha*: string

  DiffReport* = object
    pathA*, pathB*: string
    entries*: seq[DiffEntry]  # tylko dkAdded/dkRemoved/dkChanged (unchanged pominiete domyslnie)
    unchangedCount*: int

proc diffArchives*(pathA, pathB: string; includeUnchanged = false): tuple[ok: bool, report: DiffReport, err: string] =
  try:
    let idxA = readIndex(pathA)
    let idxB = readIndex(pathB)
    var mapA: seq[tuple[path: string, e: ArchiveEntry]] = @[]
    for e in idxA.entries: mapA.add (e.path, e)
    var mapB: seq[tuple[path: string, e: ArchiveEntry]] = @[]
    for e in idxB.entries: mapB.add (e.path, e)

    var report = DiffReport(pathA: pathA, pathB: pathB)
    var seenInB: seq[bool] = newSeq[bool](mapB.len)

    for (pa, ea) in mapA:
      var foundIdx = -1
      for i, (pb, eb) in mapB:
        if pb == pa: foundIdx = i; break
      if foundIdx < 0:
        report.entries.add DiffEntry(path: pa, kind: dkRemoved, oldSize: ea.rawSize, oldSha: sha256HexOf(ea.sha256))
      else:
        seenInB[foundIdx] = true
        let eb = mapB[foundIdx].e
        let shaA = sha256HexOf(ea.sha256)
        let shaB = sha256HexOf(eb.sha256)
        if shaA == shaB:
          inc report.unchangedCount
          if includeUnchanged:
            report.entries.add DiffEntry(path: pa, kind: dkUnchanged, oldSize: ea.rawSize, newSize: eb.rawSize, oldSha: shaA, newSha: shaB)
        else:
          report.entries.add DiffEntry(path: pa, kind: dkChanged, oldSize: ea.rawSize, newSize: eb.rawSize, oldSha: shaA, newSha: shaB)

    for i, (pb, eb) in mapB:
      if not seenInB[i]:
        report.entries.add DiffEntry(path: pb, kind: dkAdded, newSize: eb.rawSize, newSha: sha256HexOf(eb.sha256))

    (true, report, "")
  except ArchiveError as e:
    (false, DiffReport(), e.msg)
  except CatchableError as e:
    (false, DiffReport(), "błąd porównywania: " & e.msg)

# ---------------------------------------------------------------------------
# Delta / deduplikacja między wersjami ("ZPKD") -- przy aktualizacji
# pakietu większość plików zwykle się NIE zmienia; zamiast pobierać/
# przechowywać całe nowe archiwum, `buildDelta` produkuje mały plik
# zawierający TYLKO payload plików, których zawartość (sha256) nie
# istnieje jeszcze w starym archiwum -- reszta to 5-bajtowe odniesienie
# "weź to z old.zpk". `applyDelta` odtwarza pełne, bajt-w-bajt identyczne
## nowe archiwum ZPKA z (stare_archiwum + delta), KOPIUJĄC już
## skompresowane bajty (bez ponownej kompresji/dekompresji) tam, gdzie to
## możliwe -- szybkie i tanie pamięciowo.
##
## Dopasowanie po TREŚCI (sha256), nie po ścieżce -- plik przeniesiony
## lub zmieniony tylko nazwą wciąż korzysta z reużycia.
# ---------------------------------------------------------------------------

const
  ZpkdMagic = "ZPKD"
  ZpkdVersion = 1'u8
  DeltaKindRef = 0'u8    ## payload identyczny z plikiem w starym archiwum (wg sha256)
  DeltaKindInline = 1'u8 ## payload dołączony wprost w pliku delty

proc buildDelta*(oldPath, newPath, deltaPath: string): tuple[ok: bool, err: string] =
  try:
    let oldIdx = readIndex(oldPath)
    let newIdx = readIndex(newPath)
    var oldBySha: seq[tuple[sha: array[32, uint8], entry: ArchiveEntry]] = @[]
    for e in oldIdx.entries: oldBySha.add (e.sha256, e)

    var fh: File
    if not open(fh, deltaPath, fmWrite):
      return (false, "nie można utworzyć " & deltaPath)
    defer: close(fh)
    var header = ZpkdMagic
    header.add char(ZpkdVersion)
    putU32(header, uint32(newIdx.entries.len))
    discard writeBuffer(fh, header[0].unsafeAddr, header.len)

    var reused = 0
    var inlined = 0
    for e in newIdx.entries:
      var rec = ""
      putU16(rec, uint16(e.path.len))
      rec.add e.path
      for b in e.sha256: rec.add char(b)
      putU64(rec, e.rawSize)

      var refIdx = -1
      for i, (sha, _) in oldBySha:
        if sha == e.sha256: refIdx = i; break

      if refIdx >= 0:
        rec.add char(DeltaKindRef)
        rec.add char(oldBySha[refIdx].entry.flags)
        inc reused
        discard writeBuffer(fh, rec[0].unsafeAddr, rec.len)
      else:
        rec.add char(DeltaKindInline)
        rec.add char(e.flags)
        let payload = readRawPayload(newIdx, e)
        putU64(rec, uint64(payload.len))
        discard writeBuffer(fh, rec[0].unsafeAddr, rec.len)
        if payload.len > 0:
          discard writeBuffer(fh, payload[0].unsafeAddr, payload.len)
        inc inlined

    (true, "ok: " & $reused & " plików reużytych ze starego archiwum, " & $inlined & " nowych/zmienionych")
  except ArchiveError as e:
    (false, e.msg)
  except CatchableError as e:
    (false, "błąd budowania delty: " & e.msg)

proc applyDelta*(oldPath, deltaPath, outPath: string): tuple[ok: bool, err: string] =
  try:
    let oldIdx = readIndex(oldPath)
    var oldBySha: seq[tuple[sha: array[32, uint8], entry: ArchiveEntry]] = @[]
    for e in oldIdx.entries: oldBySha.add (e.sha256, e)

    var ds = newFileStream(deltaPath, fmRead)
    if ds == nil: return (false, "nie można otworzyć " & deltaPath)
    defer: ds.close()
    var magic: array[4, char]
    discard ds.readData(magic[0].addr, 4)
    if magic[0] != 'Z' or magic[1] != 'P' or magic[2] != 'K' or magic[3] != 'D':
      return (false, deltaPath & " nie jest plikiem delty ZPKD")
    discard ds.readUint8()  # wersja
    let entryCount = readU32(ds)

    var outFh: File
    if not open(outFh, outPath, fmWrite):
      return (false, "nie można utworzyć " & outPath)
    defer: close(outFh)
    var header = ZpkaMagic
    header.add char(ZpkaVersion)
    header.add char(0'u8)
    discard writeBuffer(outFh, header[0].unsafeAddr, header.len)
    var offset = uint64(header.len)

    var outEntries: seq[ArchiveEntry] = @[]
    for _ in 0 ..< entryCount:
      let plen = readU16(ds)
      var path = newString(int(plen))
      if plen > 0: discard ds.readData(path[0].addr, int(plen))
      var sha: array[32, uint8]
      for i in 0 ..< 32: sha[i] = uint8(ds.readChar())
      let rawSize = readU64(ds)
      let kind = uint8(ds.readChar())
      let flags = uint8(ds.readChar())

      var payload: string
      if kind == DeltaKindRef:
        var refIdx = -1
        for i, (s2, _) in oldBySha:
          if s2 == sha: refIdx = i; break
        if refIdx < 0:
          return (false, "delta odwołuje się do pliku '" & path &
            "' którego nie ma w starym archiwum " & oldPath & " (delta niezgodna z tym archiwum bazowym)")
        payload = readRawPayload(oldIdx, oldBySha[refIdx].entry)
      else:
        let plen2 = readU64(ds)
        payload = newString(int(plen2))
        if plen2 > 0: discard ds.readData(payload[0].addr, int(plen2))

      var entry = ArchiveEntry(path: path, flags: flags, dataOffset: offset,
                                compSize: uint64(payload.len), rawSize: rawSize, sha256: sha)
      outEntries.add entry
      if payload.len > 0:
        discard writeBuffer(outFh, payload[0].unsafeAddr, payload.len)
      offset += uint64(payload.len)

    let tocOffset = offset
    var toc = newStringOfCap(outEntries.len * 64)
    for e in outEntries:
      putU16(toc, uint16(e.path.len))
      toc.add e.path
      toc.add char(e.flags)
      putU64(toc, e.dataOffset)
      putU64(toc, e.compSize)
      putU64(toc, e.rawSize)
      for b in e.sha256: toc.add char(b)
    if toc.len > 0:
      discard writeBuffer(outFh, toc[0].unsafeAddr, toc.len)
    var footer = ZpkaFooterMagic
    putU32(footer, uint32(outEntries.len))
    putU64(footer, tocOffset)
    discard writeBuffer(outFh, footer[0].unsafeAddr, footer.len)

    (true, "")
  except CatchableError as e:
    (false, "błąd stosowania delty: " & e.msg)

export sha256HexOf
