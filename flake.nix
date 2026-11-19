{
  description = "the GNU binary utilities as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # binutils' programs share libbfd/libopcodes/libctf/libsframe/libiberty
  # (and, on ELF, gold's own code); the engine folds them into one binary.
  #
  # `--enable-targets=all` makes one objdump/readelf/ld read every
  # architecture's objects and builds the PE/COFF tools on every OS. Programs
  # per target: 24 (25 names with `ld.bfd`) on most Linux arches; 22 on
  # riscv64, loongarch64 and Windows, which have no gold or dwp (`withGold`);
  # 19 on macOS, where GNU ld/as have no Mach-O backend and gprof isn't built.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # nixpkgs' binutils `withGold`: gold has no RISC-V or LoongArch backend.
      withGold = p: (p.isElf or false) && !(p.isRiscV or false) && !(p.isLoongArch64 or false);

      # Shared by every target, the mingw cross included.
      mkBinutils = scope:
        scope.binutils-unwrapped.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ./patches/windres-res-coff-info.patch
            ./patches/gold-ld-new-rename.patch
            ./patches/implib-deterministic-flag.patch
          ];
          # One objdump/readelf/ld that groks every architecture's objects.
          # `--disable-dependency-tracking`: binutils' `make install` re-runs
          # ld/genscripts.sh, which regenerates the emulation `.c` files from a
          # per-emulation `.deps/*.Pc` scheme that parses the compiler's `-MD`
          # output. Under the engine that output carries the zig-libc sysroot
          # header paths (`/__unpin_ziglib__/…/endian.h`); the .Pc parser mangles
          # them into a bogus emulation name and `install-recursive` dies. We only
          # build once, so drop autotools dependency tracking entirely — genscripts
          # then uses the clean configure-provided emulation list (and the build
          # runs faster with no .deps churn).
          #
          # `--program-prefix=`: nixpkgs forces `--program-prefix=${targetPrefix}`,
          # and in a cross set `targetPlatform != hostPlatform` compares two
          # SEPARATELY elaborated platform attrsets — unequal even when both spell
          # `x86_64-w64-mingw32` — so the mingw build installs everything as
          # `x86_64-w64-mingw32-*`. The binaries don't matter (the self-fold links
          # from the build tree's `-o` names, not the installed ones), but the man
          # pages do: the .exe shipped `x86_64-w64-mingw32-objdump.1` while
          # announcing `objdump`, so NOT ONE of its 25 names resolved. We ship one
          # `binutils` binary, not a cross toolchain — the prefix has no meaning
          # here. Last `--program-prefix` on the command line wins. Only where the
          # prefix is non-empty: native already resolves to `--program-prefix=`,
          # so adding a second copy there would re-hash eight green targets to
          # say the same thing.
          configureFlags = (old.configureFlags or [ ]) ++ [
            "--enable-targets=all"
            "--disable-dependency-tracking"
          ] ++ (if scope.stdenv.hostPlatform.isWindows then [ "--program-prefix=" ] else [
            # Where objdump and readelf look for separate debug files: the
            # system's directory, not this package's store path.
            "--with-separate-debug-dir=/usr/lib/debug"
          ]);
          # The suite compiles its test programs with CC_FOR_TARGET; the
          # engine's cc emits bitcode objects that strip/objdump/ld can't read,
          # so the tests get the build host's ordinary compiler, which only
          # targets the host when the systems match (not i686) and isn't
          # measured on darwin. gold is left out: its testsuite builds its
          # objects with the build's own compiler and wants `ld-new`, which
          # patches/gold-ld-new-rename.patch renames.
          doCheck = scope.stdenv.hostPlatform.isLinux
            && scope.stdenv.buildPlatform.system == scope.stdenv.hostPlatform.system;
          checkTarget = scope.lib.concatMapStringsSep " " (d: "check-${d}") [
            "binutils" "gas" "ld" "libctf" "libsframe" "libiberty" "bfd" "opcodes" "gprof"
          ];
          # The ar testsuite checks `ar u` against real member mtimes, which
          # SOURCE_DATE_EPOCH (set by the build) pins.
          preCheck = (old.preCheck or "") + "\nunset SOURCE_DATE_EPOCH\n";
          checkFlags = [
            "CC_FOR_TARGET=${scope.buildPackages.stdenv.cc}/bin/cc"
            "CXX_FOR_TARGET=${scope.buildPackages.stdenv.cc}/bin/c++"
          ];
          nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ scope.dejagnu ];
          # nixpkgs' binutils bakes `-static-libgcc` (a link flag) into
          # NIX_CFLAGS_COMPILE, so it rides every clang invocation — including the
          # `clang -E` preprocessor calls binutils' many sub-configures use for
          # their `AC_CHECK_HEADER` probes. clang warns `argument unused during
          # compilation: '-static-libgcc'` on those, and autoconf's preprocessor
          # header check treats ANY stderr output as failure → HAVE_LIMITS_H /
          # HAVE_FCNTL_H / … come back "no", so libiberty then skips <limits.h>
          # (fibheap.c: `LONG_MIN` undeclared) and <unistd.h> (filedescriptor.c:
          # implicit `dup2`) and the build dies. gcc accepted the stray flag
          # silently, clang doesn't. `-Qunused-arguments` silences the unused-arg
          # warning so the probes see clean stderr and the headers detect
          # correctly (this cascade broke every subdir's config.h, not just
          # libiberty's). binutils-unwrapped sets NIX_CFLAGS_COMPILE in `env`,
          # so append there.
          env = (old.env or { }) // {
            NIX_CFLAGS_COMPILE = ((old.env or { }).NIX_CFLAGS_COMPILE or "") + " -Qunused-arguments";
          } // scope.lib.optionalAttrs (!scope.stdenv.hostPlatform.isWindows) {
            # musl's host differs from the gnu build, so autoconf can't run its
            # mmap probe and guesses no: elfedit then loses --enable-x86-feature
            # and bfd reads files without mmap.
            ac_cv_func_mmap_fixed_mapped = "yes";
          };
        });
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "binutils";
      # The binutils programs, libbfd and libopcodes are all GPL-3.0-or-later;
      # libiberty (folded in statically) is more permissive but doesn't loosen
      # the combined binary. nixpkgs reports the full component list -- pin the
      # effective license so the catalog shows one SPDX id.
      license = "GPL-3.0-or-later";
      # objdump's banner is `GNU objdump (GNU Binutils) 2.46`. Bare `binutils`
      # is not a program — it lists.
      smoke = [ "--unpin-program=objdump" "--version" ];
      # Anchored on the program, not the suite: every applet prints
      # `GNU <program> (GNU Binutils) 2.46`, so "GNU Binutils" is satisfied by
      # nm/ar/ld just as well and never tests the only thing --unpin-program
      # adds. The banner is a literal in bucomm.c, not argv[0], so this still
      # matches when smoke_windows runs the artifact renamed to smoke.exe.
      smokePattern = "^GNU objdump ";

      # Programs are listed under the name they install as; `linkName` is the
      # build's `-o` name where it differs (nm-new, strip-new, cxxfilt, ld-new,
      # as-new, ld-gold — the last set by patches/gold-ld-new-rename.patch).
      # gold and dwp are C++, hence `requires.cxx`.
      engine = "unpin-llvm";
      multicall = {
        windows = true;
        requires.cxx = true;
        programs = [
          { name = "objdump"; }
          { name = "nm"; linkName = "nm-new"; }
          { name = "readelf"; }
          { name = "ar"; }
          { name = "ranlib"; }
          { name = "strings"; }
          { name = "size"; }
          { name = "strip"; linkName = "strip-new"; }
          { name = "objcopy"; }
          { name = "addr2line"; }
          { name = "c++filt"; linkName = "cxxfilt"; }
          { name = "elfedit"; }
          # binutils-2.46 documents neither `ld.bfd` nor gold/dwp/dllwrap:
          # `binutils/doc` holds 14 `.1` plus `cxxfilt.man`, and
          # `ld/Makefile.am` says `man_MANS = ld.1` — one page for a linker
          # `install-exec-local` installs under two names, by design. All four
          # names run; none has a page anywhere, so a stub would be invention.
          { name = "ld"; linkName = "ld-new";
            aliases = [ { name = "ld.bfd"; noMan = true; } ]; }
          { name = "as"; linkName = "as-new"; }
          { name = "gprof"; }
          # The PE/COFF tools `--enable-targets=all` turns on: link under their own
          # name (no -new suffix), dispatched under that name.
          { name = "dlltool"; }
          { name = "windres"; }
          { name = "windmc"; }
          { name = "dllwrap"; noMan = true; }
          { name = "coffdump"; noMan = true; }
          { name = "srconv"; noMan = true; }
          { name = "sysdump"; noMan = true; }
          # gold and dwp: ELF only, and no RISC-V or LoongArch backend.
          {
            name = "ld.gold";
            linkName = "ld-gold";
            noMan = true;
            supportedTarget = withGold;
          }
          { name = "dwp"; noMan = true; supportedTarget = withGold; }
        ];
        # darwin: GNU ld/as have no Mach-O backend, gprof isn't built and
        # gold/dwp are ELF-only, so configure builds only these.
        darwinPrograms = [
          { name = "objdump"; }
          { name = "nm"; linkName = "nm-new"; }
          { name = "readelf"; }
          { name = "ar"; }
          { name = "ranlib"; }
          { name = "strings"; }
          { name = "size"; }
          { name = "strip"; linkName = "strip-new"; }
          { name = "objcopy"; }
          { name = "addr2line"; }
          { name = "c++filt"; linkName = "cxxfilt"; }
          { name = "elfedit"; }
          { name = "dlltool"; }
          { name = "windres"; }
          { name = "windmc"; }
          { name = "dllwrap"; noMan = true; }
          { name = "coffdump"; noMan = true; }
          { name = "srconv"; noMan = true; }
          { name = "sysdump"; noMan = true; }
        ];
      };

      build = pkgs: mkBinutils pkgs.pkgsStatic;

      # Windows folds the list above minus gold and dwp.
      windowsBuild = pkgs: mkBinutils (ulib.mingwStaticCross pkgs);
    };
}
