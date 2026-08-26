import std/[os, osproc, strutils, strformat, sets, sequtils]
import ./types

## v0.2 -- zamyka lukę "`--trust-keys` nadal tylko drukuje komunikat --
## nie blokuje niczego realnie, nie jest spięte z `security.verify_signatures`".
##
## Format pliku wskazanego przez `--trust-keys=<plik>` (ten sam co
## `keys/default.hcl` w zlb -- patrz zlbpkg/keys.nim): jeden fingerprint
## GPG (40 znaków hex, ew. z odstępami jak `gpg --fingerprint` wypisuje) na
## linię, `#` zaczyna komentarz, puste linie ignorowane.
##
## `zpm init --trust-keys=<plik>` / `zpm --root=<r> init --trust-keys=<plik>`
## PARSUJE ten plik i PERSYSTUJE znormalizowany zestaw fingerprintów pod
## `cfg.trustedKeysStatePath` (domyślnie /var/lib/zpm/trusted-keys.list,
## albo <root>/etc/zpm/trusted-keys.list w trybie budowania). Od tej pory
## `verifyGitSignature` (ownrepo.nim) -- gdy taki plik ISTNIEJE -- nie
## poprzestaje na "git twierdzi, że podpis jest ważny wg lokalnego
## keyringu gpg", tylko DODATKOWO wymaga, żeby fingerprint podpisującego
## klucza był na tej liście. Brak pliku (nikt nigdy nie wywołał `init
## --trust-keys=...`) zachowuje stare zachowanie (ufaj keyringowi gpg) --
## to świadomy wybór kompatybilności wstecznej, nie cicha dziura: `zpm
## doctor` ostrzega, gdy `verify_signatures=true`, ale nie ma żadnego
## pliku zaufanych kluczy skonfigurowanego.

proc normalizeFingerprint(raw: string): string =
  raw.strip().replace(" ", "").toUpperAscii()

proc parseTrustKeysFile*(path: string): seq[string] =
  result = @[]
  if not fileExists(path):
    return
  for line in readFile(path).splitLines():
    var l = line.strip()
    if l.len == 0 or l.startsWith("#"): continue
    # dopuszczalne też "FINGERPRINT  # komentarz na końcu"
    let hashIdx = l.find('#')
    if hashIdx >= 0: l = l[0 ..< hashIdx].strip()
    if l.len == 0: continue
    result.add normalizeFingerprint(l)

proc trustedKeysStatePathFor*(cfg: ZpmConfig, rootPath: string): string =
  ## W trybie budowania (`--root=<rootfs>`) zestaw kluczy jest per-obraz,
  ## nie per-host -- ląduje pod `<rootfs>/etc/zpm/trusted-keys.list`
  ## zamiast w globalnej ścieżce hosta.
  if rootPath.len > 0 and rootPath != "/":
    rootPath / "etc" / "zpm" / "trusted-keys.list"
  else:
    cfg.trustedKeysStatePath

proc importTrustKeysFile*(cfg: ZpmConfig, sourcePath: string, rootPath: string = "/"): tuple[ok: bool, count: int] =
  ## Parsuje `sourcePath` i persystuje znormalizowaną listę. Próbuje też
  ## (best-effort, nie blokujące) zaimportować materiał klucza do lokalnego
  ## keyringu gpg, JEŚLI plik zawiera bloki `-----BEGIN PGP PUBLIC KEY
  ## BLOCK-----` zamiast gołych fingerprintów -- wygodne dla operatora,
  ## który chce dostarczyć sam plik z kluczami zamiast osobno `gpg --import`.
  if not fileExists(sourcePath):
    return (false, 0)

  let raw = readFile(sourcePath)
  var fingerprints: seq[string] = @[]

  if "BEGIN PGP PUBLIC KEY BLOCK" in raw:
    if findExe("gpg").len > 0:
      let (output, code) = execCmdEx(&"gpg --import \"{sourcePath}\" 2>&1")
      if code == 0:
        # Wyciągnij fingerprinty świeżo zaimportowanych kluczy.
        let (listOut, listCode) = execCmdEx("gpg --with-colons --fingerprint --import-options show-only --import " & sourcePath.quoteShell)
        if listCode == 0:
          for line in listOut.splitLines():
            if line.startsWith("fpr:"):
              let parts = line.split(':')
              if parts.len > 9 and parts[9].len > 0:
                fingerprints.add normalizeFingerprint(parts[9])
      else:
        stderr.writeLine(&"[zpm:keys] Ostrzeżenie: 'gpg --import' nie powiodło się dla {sourcePath}: {output}")
    else:
      stderr.writeLine("[zpm:keys] Ostrzeżenie: plik zawiera blok klucza PGP, ale 'gpg' nie jest w PATH -- pomijam import materiału klucza.")
  else:
    fingerprints = parseTrustKeysFile(sourcePath)

  if fingerprints.len == 0:
    stderr.writeLine(&"[zpm:keys] Ostrzeżenie: {sourcePath} nie zawiera żadnego rozpoznanego fingerprintu/klucza.")
    return (false, 0)

  let statePath = trustedKeysStatePathFor(cfg, rootPath)
  createDir(parentDir(statePath))
  var uniq = initHashSet[string]()
  for f in fingerprints: uniq.incl f
  writeFile(statePath, toSeq(uniq).join("\n") & "\n")
  (true, uniq.len)

proc loadTrustedKeys*(cfg: ZpmConfig, rootPath: string = "/"): seq[string] =
  let statePath = trustedKeysStatePathFor(cfg, rootPath)
  if not fileExists(statePath): return @[]
  result = @[]
  for line in readFile(statePath).splitLines():
    let l = line.strip()
    if l.len > 0: result.add l

proc trustedKeysConfigured*(cfg: ZpmConfig, rootPath: string = "/"): bool =
  fileExists(trustedKeysStatePathFor(cfg, rootPath))

proc isFingerprintTrusted*(cfg: ZpmConfig, fingerprint: string, rootPath: string = "/"): bool =
  ## Zwraca true też wtedy, gdy NIE MA skonfigurowanego pliku zaufanych
  ## kluczy w ogóle (kompatybilność wsteczna -- patrz komentarz u góry
  ## pliku). Jeśli plik istnieje, fingerprint MUSI się na nim znaleźć.
  if not trustedKeysConfigured(cfg, rootPath): return true
  let trusted = loadTrustedKeys(cfg, rootPath)
  normalizeFingerprint(fingerprint) in trusted

proc extractSignerFingerprint*(cacheDir, refStr: string, tryCommit: bool): string =
  ## Wyciąga fingerprint podpisującego klucza z `git verify-commit --raw`
  ## / `git verify-tag --raw` (linia `[GNUPG:] VALIDSIG <fpr> ...`).
  ## Zwraca "" jeśli nie da się ustalić (np. podpis w ogóle nie GOODSIG).
  let cmd =
    if tryCommit: &"git -C \"{cacheDir}\" verify-commit --raw HEAD 2>&1"
    else: &"git -C \"{cacheDir}\" verify-tag --raw \"{refStr}\" 2>&1"
  let (output, _) = execCmdEx(cmd)
  for line in output.splitLines():
    if "VALIDSIG" in line:
      let parts = line.strip().split(' ')
      # format: [GNUPG:] VALIDSIG <fpr> <data> <sig-time> ...
      if parts.len > 2:
        return normalizeFingerprint(parts[2])
  ""
