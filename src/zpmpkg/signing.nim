import std/[os, osproc, base64, strformat, strutils]

## Weryfikacja podpisów kryptograficznych pakietów `.zpk` (v0.4).
##
## `zpk` (osobne repo, `zpkpkg/signing.nim`) umie PODPISYWAĆ zbudowane
## `.zpk` kluczem prywatnym RSA/EC albo Ed25519 (przez `openssl`), i
## niesie ten podpis w polu `signature` manifestu (W ŚRODKU archiwum,
## patrz `zpmpkg/zpk.nim`). Do tej pory `zpm` -- program, który te
## pakiety FAKTYCZNIE instaluje -- w ogóle nie miało odpowiednika
## `verifyFile`: `zpm install` sprawdzało WYŁĄCZNIE sha256
## (integralność, "plik nie jest uszkodzony/przekłamany"), nigdy podpis
## (autentyczność, "plik faktycznie pochodzi od posiadacza klucza
## prywatnego") -- nawet jeśli pakiet BYŁ podpisany. Ten moduł domyka tę
## lukę po stronie instalującej, dokładnie tymi samymi komendami openssl
## co `zpk` używa do podpisywania (patrz komentarz niżej) -- żeby podpis
## zweryfikowany przez `zpm` był NAPRAWDĘ tym samym, co `zpk verify` by
## potwierdziło.
##
## Komendy (identyczne jak w `zpk`, sekcja "RSA vs Ed25519" w README
## głównego repo):
##   RSA/EC:  openssl dgst -sha256 -verify pub.pem -signature sig plik
##   Ed25519: openssl pkeyutl -verify -pubin -inkey pub.pem -rawin
##            -in plik -sigfile sig
## (Ed25519 w OpenSSL 3.x nie wspiera trybu "podpisz/zweryfikuj skrót"
## przez `dgst` -- podpisuje/weryfikuje całą wiadomość wewnętrznie, stąd
## `pkeyutl -rawin`, wymagające OpenSSL >= 3.0.)
##
## `zpm` samo NIGDY nie podpisuje (to zadanie `zpk build --sign-key=...`)
## -- ten moduł jest CELOWO ograniczony do weryfikacji.

type VerifyKeyKind = enum
  vkRsaOrEc
  vkEd25519

proc opensslAvailable*(): bool =
  findExe("openssl").len > 0

proc detectVerifyKeyKind(pubKeyPath: string): tuple[ok: bool, kind: VerifyKeyKind] =
  let cmd = &"openssl pkey -pubin -in {quoteShell(pubKeyPath)} -text -noout"
  let (output, code) = execCmdEx(cmd)
  if code != 0 or output.len == 0:
    return (false, vkRsaOrEc)
  let firstLine = output.splitLines()[0]
  if "ed25519" in firstLine.toLowerAscii:
    (true, vkEd25519)
  else:
    (true, vkRsaOrEc)

proc verifyFile*(path, publicKeyPath, signatureBase64: string): tuple[ok: bool, error: string] =
  ## Weryfikuje `signatureBase64` (dokładnie to, co niesie
  ## `ZpkManifest.signature`) pliku `path` względem klucza publicznego
  ## `publicKeyPath` (PEM). Zwraca (false, powód) na KAŻDY możliwy sposób
  ## niepowodzenia -- brak openssl, brak klucza, niepoprawny base64,
  ## niezgodny podpis -- żeby wołający mógł pokazać sensowny komunikat
  ## zamiast gołego "nie zweryfikowano".
  if not opensslAvailable():
    return (false, "'openssl' nie jest dostępne w PATH -- wymagane do weryfikacji podpisu")
  if not fileExists(publicKeyPath):
    return (false, &"nie znaleziono klucza publicznego: {publicKeyPath}")
  if not fileExists(path):
    return (false, &"nie znaleziono pliku do zweryfikowania: {path}")
  if signatureBase64.strip().len == 0:
    return (false, "pusty podpis -- nic do zweryfikowania")

  let (detected, kind) = detectVerifyKeyKind(publicKeyPath)
  if not detected:
    return (false, &"nie udało się odczytać typu klucza publicznego {publicKeyPath}")

  let sigPath = path & ".zpm-verify.tmp"
  defer:
    if fileExists(sigPath): removeFile(sigPath)
  try:
    writeFile(sigPath, decode(signatureBase64.strip()))
  except CatchableError as e:
    return (false, &"podpis nie jest poprawnym base64: {e.msg}")

  let cmd = case kind
    of vkEd25519:
      &"openssl pkeyutl -verify -pubin -inkey {quoteShell(publicKeyPath)} -rawin " &
        &"-in {quoteShell(path)} -sigfile {quoteShell(sigPath)}"
    of vkRsaOrEc:
      &"openssl dgst -sha256 -verify {quoteShell(publicKeyPath)} " &
        &"-signature {quoteShell(sigPath)} {quoteShell(path)}"

  let (output, code) = execCmdEx(cmd)
  if code != 0:
    return (false, &"podpis nie zgadza się z kluczem {publicKeyPath}: {output.strip()}")
  (true, "")
