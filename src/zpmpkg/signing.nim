import std/[os, osproc, base64, strformat, strutils]
import ./ed25519

## Weryfikacja podpisów kryptograficznych pakietów `.zpk`.
##
## `zpk` (osobne repo, `zpkpkg/signing.nim`) umie PODPISYWAĆ zbudowane
## `.zpk` -- natywnym Ed25519 (czysty Nim, `zpk genkey`) albo kluczem PEM
## (RSA/EC/Ed25519 przez `openssl`) -- i niesie ten podpis w polu
## `signature` manifestu (W ŚRODKU archiwum, patrz `zpmpkg/zpk.nim`).
## `zpm` samo NIGDY nie podpisuje (to zadanie `zpk build --sign-key=...`)
## -- ten moduł jest CELOWO ograniczony do weryfikacji.
##
## v0.6 -- **natywny Ed25519 (czysty Nim, `ed25519.nim`) obok PEM przez
## `openssl`.** Klucz publiczny zaczynający się od "-----BEGIN ZPK NATIVE
## ED25519 PUBLIC KEY-----" jest weryfikowany w 100% w Nim, ZERO
## zależności od `openssl` -- to domyślna, zalecana droga od v0.6, bo
## zamyka ostatnią lukę zależności zewnętrznej w `zpm`. Klucze PEM
## (RSA/EC/OpenSSL-Ed25519) nadal działają jak wcześniej, przez
## `openssl pkeyutl`/`openssl dgst` -- dla zgodności z istniejącymi
## kluczami/łańcuchami zaufania.

type VerifyKeyKind = enum
  vkRsaOrEc
  vkEd25519Pem
  vkEd25519Native

const
  NativePublicHeader = "-----BEGIN ZPK NATIVE ED25519 PUBLIC KEY-----"
  NativePublicFooter = "-----END ZPK NATIVE ED25519 PUBLIC KEY-----"

proc opensslAvailable*(): bool =
  findExe("openssl").len > 0

proc isNativePublicKeyFile(path: string): bool =
  if not fileExists(path): return false
  try:
    readFile(path).splitLines()[0].strip() == NativePublicHeader
  except CatchableError:
    false

proc readNativePublicKeyBody(path: string): tuple[ok: bool, key: string, err: string] =
  let lines = readFile(path).splitLines()
  var b64 = ""
  for i in 1 ..< lines.len:
    let l = lines[i].strip()
    if l.startsWith("-----END"): break
    b64.add l
  try:
    let raw = decode(b64)
    if raw.len != 32:
      return (false, "", &"klucz natywny w {path} ma nieprawidłowy rozmiar ({raw.len}, oczekiwano 32)")
    (true, raw, "")
  except CatchableError as e:
    (false, "", &"nie udało się zdekodować klucza natywnego z {path}: {e.msg}")

proc detectVerifyKeyKind(pubKeyPath: string): tuple[ok: bool, kind: VerifyKeyKind] =
  if isNativePublicKeyFile(pubKeyPath):
    return (true, vkEd25519Native)
  let cmd = &"openssl pkey -pubin -in {quoteShell(pubKeyPath)} -text -noout"
  let (output, code) = execCmdEx(cmd)
  if code != 0 or output.len == 0:
    return (false, vkRsaOrEc)
  let firstLine = output.splitLines()[0]
  if "ed25519" in firstLine.toLowerAscii:
    (true, vkEd25519Pem)
  else:
    (true, vkRsaOrEc)

proc verifyFile*(path, publicKeyPath, signatureBase64: string): tuple[ok: bool, error: string] =
  ## Weryfikuje `signatureBase64` (dokładnie to, co niesie
  ## `ZpkManifest.signature`) pliku `path` względem klucza publicznego
  ## `publicKeyPath`. Zwraca (false, powód) na KAŻDY możliwy sposób
  ## niepowodzenia, żeby wołający mógł pokazać sensowny komunikat.
  if not fileExists(publicKeyPath):
    return (false, &"nie znaleziono klucza publicznego: {publicKeyPath}")
  if not fileExists(path):
    return (false, &"nie znaleziono pliku do zweryfikowania: {path}")
  if signatureBase64.strip().len == 0:
    return (false, "pusty podpis -- nic do zweryfikowania")

  let (detected, kind) = detectVerifyKeyKind(publicKeyPath)
  if not detected:
    return (false, &"nie udało się odczytać typu klucza publicznego {publicKeyPath}")

  if kind == vkEd25519Native:
    let (ok, key, err) = readNativePublicKeyBody(publicKeyPath)
    if not ok: return (false, err)
    var sig: string
    try:
      sig = decode(signatureBase64.strip())
    except CatchableError as e:
      return (false, &"podpis nie jest poprawnym base64: {e.msg}")
    if sig.len != 64:
      return (false, &"podpis ma nieprawidłowy rozmiar ({sig.len}, oczekiwano 64) -- to nie jest podpis Ed25519")
    let content = readFile(path)
    if ed25519.ed25519Verify(key, content, sig):
      return (true, "")
    else:
      return (false, &"podpis nie zgadza się z kluczem {publicKeyPath}")

  if not opensslAvailable():
    return (false, "'openssl' nie jest dostępne w PATH -- wymagane do weryfikacji tego klucza (PEM)")

  let sigPath = path & ".zpm-verify.tmp"
  defer:
    if fileExists(sigPath): removeFile(sigPath)
  try:
    writeFile(sigPath, decode(signatureBase64.strip()))
  except CatchableError as e:
    return (false, &"podpis nie jest poprawnym base64: {e.msg}")

  let cmd = case kind
    of vkEd25519Pem:
      &"openssl pkeyutl -verify -pubin -inkey {quoteShell(publicKeyPath)} -rawin " &
        &"-in {quoteShell(path)} -sigfile {quoteShell(sigPath)}"
    of vkRsaOrEc:
      &"openssl dgst -sha256 -verify {quoteShell(publicKeyPath)} " &
        &"-signature {quoteShell(sigPath)} {quoteShell(path)}"
    of vkEd25519Native: ""  # nieosiagalne (obsluzone wyzej)

  let (output, code) = execCmdEx(cmd)
  if code != 0:
    return (false, &"podpis nie zgadza się z kluczem {publicKeyPath}: {output.strip()}")
  (true, "")
