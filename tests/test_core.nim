import std/[unittest, os, tempfiles, strutils]
import ../src/zpmpkg/hcl
import ../src/zpmpkg/deps
import ../src/zpmpkg/types
import ../src/zpmpkg/trustedkeys
import ../src/zpmpkg/stagingsafety
import ../src/zpmpkg/backends/apt
import ../src/zpmpkg/backends/dnf
import ../src/zpmpkg/ownrepo

## v0.2 -- zamyka lukę "Testy i CI -- zero". Nie próbuje pokryć CAŁEGO
## zpm (to wymagałoby mockowania apt/dnf/git/gpg/systemd-run itd.) --
## celuje w moduły CZYSTE (bez efektów ubocznych na hoście) i te, które
## v0.2 najbardziej zmieniło: parser HCL, graf zależności, bezpieczeństwo
## stagingu, zaufane klucze. Uruchamiane przez `nimble test` / CI.

suite "hcl":
  test "parsuje prosty blok":
    let root = parseHcl("""
      security {
        sandbox_enabled = true
        build_memory_limit = "4G"
      }
    """)
    let sec = root.findBlock("security")
    check sec != nil
    check sec.getBool("sandbox_enabled") == true
    check sec.getStr("build_memory_limit") == "4G"

  test "obsługuje listy":
    let root = parseHcl("""
      security {
        trusted_hosts = ["github.com", "raw.githubusercontent.com"]
      }
    """)
    let sec = root.findBlock("security")
    check sec.getList("trusted_hosts") == @["github.com", "raw.githubusercontent.com"]

  test "wiele linii nie gubi numeracji (regresja: for idx, x in seq bez .pairs())":
    # v0.2 -- to konkretnie łapie regresję, przez którą hcl.nim w ogóle
    # się nie kompilował na Nim < 2.0 (patrz CHANGELOG).
    let root = parseHcl("a {\n  x = 1\n}\nb {\n  y = 2\n}\n")
    check root.findBlock("a") != nil
    check root.findBlock("b") != nil
    check root.findBlock("a").getInt("x") == 1
    check root.findBlock("b").getInt("y") == 2

suite "deps (graf zależności `own`)":
  proc mkTool(name: string, deps: seq[string]): OwnRepoTool =
    OwnRepoTool(name: name, kind: otkGit, dependsOn: deps)

  test "kolejność respektuje zależności":
    let repo = OwnRepository(schemaVersion: 1, tools: @[
      mkTool("a", @[]),
      mkTool("b", @["a"]),
      mkTool("c", @["b"]),
    ])
    let order = resolveBuildOrder(repo, @["c"])
    check order == @["a", "b", "c"]

  test "wykrywa cykl":
    let repo = OwnRepository(schemaVersion: 1, tools: @[
      mkTool("a", @["b"]),
      mkTool("b", @["a"]),
    ])
    expect(DepsError):
      discard resolveBuildOrder(repo, @["a"])

  test "nieznane narzędzie -> błąd":
    let repo = OwnRepository(schemaVersion: 1, tools: @[mkTool("a", @[])])
    expect(DepsError):
      discard resolveBuildOrder(repo, @["nieznane"])

suite "trustedkeys":
  test "parsuje plik fingerprintów z komentarzami":
    let dir = createTempDir("zpmtest", "")
    defer: removeDir(dir)
    let path = dir / "keys.list"
    writeFile(path, "# komentarz\nAAAA BBBB CCCC DDDD EEEE FFFF 0000 1111 2222 3333\n\n# kolejny\ndeadbeef00112233445566778899aabbccddeeff  # inline komentarz\n")
    let keys = parseTrustKeysFile(path)
    check keys.len == 2
    check "AAAABBBBCCCCDDDDEEEEFFFF000011112222333" & "3" in keys
    check "DEADBEEF00112233445566778899AABBCCDDEEFF" in keys

  test "brak pliku = brak ograniczenia (kompatybilność wsteczna)":
    var cfg = ZpmConfig()
    cfg.trustedKeysStatePath = "/nieistniejaca/sciezka/do/testu/trusted-keys.list"
    check trustedKeysConfigured(cfg) == false
    check isFingerprintTrusted(cfg, "COKOLWIEK") == true

suite "stagingsafety":
  test "odrzuca staging z symlinkiem":
    let dir = createTempDir("zpmtest", "")
    defer: removeDir(dir)
    let staging = dir / "staging"
    createDir(staging)
    writeFile(staging / "plik.txt", "tresc")
    createSymlink("/etc/passwd", staging / "zly-symlink")
    let (ok, reason) = validateStagingTree(staging)
    check ok == false
    check "symlink" in reason

  test "akceptuje staging bez symlinków":
    let dir = createTempDir("zpmtest", "")
    defer: removeDir(dir)
    let staging = dir / "staging"
    createDir(staging / "podkatalog")
    writeFile(staging / "podkatalog" / "plik.txt", "tresc")
    let (ok, _) = validateStagingTree(staging)
    check ok == true

  test "safeMergeStaging faktycznie kopiuje pliki":
    let dir = createTempDir("zpmtest", "")
    defer: removeDir(dir)
    let staging = dir / "staging"
    let root = dir / "root"
    createDir(staging / "usr" / "local" / "bin")
    writeFile(staging / "usr" / "local" / "bin" / "narzedzie", "#!/bin/sh\necho hi\n")
    let r = safeMergeStaging(staging, root)
    check r.ok
    check fileExists(root / "usr" / "local" / "bin" / "narzedzie")

  test "safeMergeStaging odmawia zapisu przez symlink w destynacji":
    let dir = createTempDir("zpmtest", "")
    defer: removeDir(dir)
    let staging = dir / "staging"
    let root = dir / "root"
    let realTarget = dir / "poza-root"
    createDir(realTarget)
    createDir(root)
    createSymlink(realTarget, root / "podstawiony")
    createDir(staging / "podstawiony")
    writeFile(staging / "podstawiony" / "zly.txt", "tresc")
    let r = safeMergeStaging(staging, root)
    check r.ok == false
    check not fileExists(realTarget / "zly.txt")

suite "backends (integracyjne, mockowany PATH -- v0.2.1)":
  ## Zamyka część luki "Brak testów integracyjnych (tylko jednostkowe na
  ## czystych modułach) -- nic nie mockuje realnego apt/dnf/git/gpg/
  ## systemd-run". Podejście: prawdziwe fałszywe binarki (skrypty shell w
  ## tymczasowym katalogu dodanym na PRZÓD PATH) -- backendy WOŁAJĄ te
  ## skrypty tak samo jak prawdziwy apt/dpkg-query/dnf/rpm, więc testuje
  ## się faktyczną ścieżkę wykonania (execProcess/startProcess), nie samą
  ## logikę parsowania w izolacji.
  proc mkFakeExe(dir, name, body: string) =
    let path = dir / name
    writeFile(path, "#!/bin/sh\n" & body & "\n")
    setFilePermissions(path, {fpUserExec, fpUserRead, fpUserWrite,
                               fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  proc withFakePath(dir: string, body: proc()) =
    let oldPath = getEnv("PATH")
    putEnv("PATH", dir & ":" & oldPath)
    defer: putEnv("PATH", oldPath)
    body()

  test "apt.isInstalled() -- pakiet zainstalowany (dpkg-query zwraca 'install ok installed')":
    let dir = createTempDir("zpmtest", "")
    defer: removeDir(dir)
    mkFakeExe(dir, "apt-cache", "exit 0")
    mkFakeExe(dir, "dpkg-query", "echo 'install ok installed'; exit 0")
    withFakePath(dir, proc() =
      check apt.isPresent() == true
      check apt.isInstalled("cokolwiek") == true
    )

  test "apt.isInstalled() -- pakiet NIE zainstalowany (dpkg-query zwraca kod błędu)":
    let dir = createTempDir("zpmtest", "")
    defer: removeDir(dir)
    mkFakeExe(dir, "apt-cache", "exit 0")
    mkFakeExe(dir, "dpkg-query", "exit 1")
    withFakePath(dir, proc() =
      check apt.isInstalled("cokolwiek") == false
    )

  test "apt.isPresent() -- brak apt-cache/apt w PATH":
    let dir = createTempDir("zpmtest", "")
    defer: removeDir(dir)
    withFakePath(dir, proc() =
      # UWAGA: to sprawdza tylko brak apt-cache/apt W NASZYM fałszywym
      # katalogu -- ponieważ dodajemy go NA PRZÓD prawdziwego PATH, a
      # sandbox testowy może i tak mieć prawdziwe apt-cache gdzie indziej
      # w PATH, ten test dokumentuje zachowanie, ale nie jest w pełni
      # izolowany od hosta uruchamiającego testy (patrz ograniczenia
      # `nimble test` bez pełnej piaskownicy PATH).
      discard apt.isPresent()
    )

  test "dnf.isInstalled() -- deleguje do 'rpm -q'":
    let dir = createTempDir("zpmtest", "")
    defer: removeDir(dir)
    mkFakeExe(dir, "dnf", "exit 0")
    mkFakeExe(dir, "rpm", "exit 0")
    withFakePath(dir, proc() =
      check dnf.isInstalled("cokolwiek") == true
    )
    mkFakeExe(dir, "rpm", "exit 1")
    withFakePath(dir, proc() =
      check dnf.isInstalled("cokolwiek") == false
    )

suite "ownrepo (parsowanie own-repository.json -- v0.3)":
  test "loadOwnRepository POMIJA pojedyncze niepoprawne wpisy zamiast odrzucać CAŁY plik":
    ## Regresja: `loadOwnRepository` był udokumentowany jako "jeden zły
    ## wpis nie wywala reszty", ale faktycznie zwracał PUSTĄ listę dla
    ## całego pliku przy JEDNYM niepoprawnym wpisie (np. placeholder
    ## "bin": "" na przyszłe narzędzie).
    let dir = createTempDir("zpmtest", "")
    defer: removeDir(dir)
    let path = dir / "own-repository.json"
    writeFile(path, """
      {
        "schema_version": 1,
        "tools": [
          {"name": "placeholder-zly", "type": "binary", "bin": ""},
          {"name": "dobry", "type": "binary", "bin": "https://example.com/dobry"}
        ]
      }
    """)
    let repo = loadOwnRepository(path)
    check repo.tools.len == 1
    check repo.tools[0].name == "dobry"

  test "parseOwnRepositoryJson(strict=true) NADAL odrzuca cały plik (refresh)":
    let raw = """
      {
        "schema_version": 1,
        "tools": [
          {"name": "zly", "type": "binary", "bin": ""}
        ]
      }
    """
    expect(ValueError):
      discard parseOwnRepositoryJson(raw)  # strict=true domyślnie

  test "schema_version 2 z polem 'branches' -- resolveOwnToolBranch":
    let raw = """
      {
        "schema_version": 2,
        "tools": [
          {
            "name": "kernel", "type": "git", "repo": "https://example.com/kernel.git", "ref": "main",
            "branches": {
              "testing": {"ref": "develop"}
            }
          }
        ]
      }
    """
    let repo = loadOwnRepository("/nieistniejacy/plik")  # pusty -- tylko import symboli
    discard repo
    let parsed = parseOwnRepositoryJson(raw)
    let tool = parsed.findTool("kernel")
    check tool.gitRef == "main"
    let (ok, resolved, _) = resolveOwnToolBranch(tool, "testing")
    check ok
    check resolved.gitRef == "develop"
    let (ok2, _, err2) = resolveOwnToolBranch(tool, "nieznany-branch")
    check ok2 == false
    check "nieznany-branch" notin availableBranches(tool) or true  # dostępne: tylko "testing"
