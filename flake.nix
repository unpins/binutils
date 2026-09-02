{
  description = "the GNU binary utilities as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # binutils ships ~a dozen-and-a-half programs across several build subdirs
  # (objdump/readelf/nm/ar/…, the `ld` linker, the `as` assembler, gprof, the
  # gold linker + dwp, the PE dlltool/windres family) that share a stack of
  # static archives (libbfd/libopcodes/libctf/libsframe/libiberty, and — ELF
  # only — libgold). We fold them into one `argv[0]`-dispatching binary.
  #
  # Every target builds via the unpin-llvm engine and self-folds from bitcode:
  # each program compiles to an LLVM-bitcode module, and nix-lib's
  # multicallModuleHookLTO `llvm-link`s them with per-module `opt -internalize`,
  # which privatises the cross-program symbol collisions (objcopy/strip share
  # objcopy.c; ar/ranlib share ar.c; the bucomm/dwarf/elfcomm helpers) that the
  # old hand-rolled ./multicall.nix solved with per-tool `-include` rename
  # headers.
  #
  # `--enable-targets=all` makes a single objdump/readelf/ld understand every
  # architecture's object files, and turns on the PE/COFF dlltool/windres/windmc/
  # dllwrap on every OS. The applet set is per-OS/arch (all verified against the
  # shipped v2.46-1 release binaries): most Linux arches fold the full 21 names
  # (12 inspection + as/ld/gprof + the 4 PE tools + gold/dwp); riscv64 folds 19
  # (gold has no RISC-V backend, so binutils builds neither gold nor dwp there);
  # Windows folds the same 19, for the different reason that gold and dwp are
  # ELF-only by design — `supportedTarget` states both conditions. macOS folds
  # 16 (inspection + the 4 PE tools; GNU ld/as have no Mach-O backend and gprof/
  # gold/dwp aren't built there, so `darwinPrograms` is that subset).
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # Shared by every target. The two engine accommodations below are not
      # Linux-specific — the mingw cross runs through the same clang adapter now,
      # so the same two cascades apply there.
      mkBinutils = scope:
        scope.binutils-unwrapped.overrideAttrs (old: {
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
          ] ++ scope.lib.optional (scope.stdenv.hostPlatform.isWindows) "--program-prefix=";
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
          # libiberty's). binutils-unwrapped uses structuredAttrs, so
          # NIX_CFLAGS_COMPILE lives in `env`.
          env = (old.env or { }) // {
            NIX_CFLAGS_COMPILE = ((old.env or { }).NIX_CFLAGS_COMPILE or "") + " -Qunused-arguments";
          };
          # Disambiguate gold's build output. gold and the BFD linker BOTH link a
          # program whose `-o` basename is `ld-new` (ld/ from bin_PROGRAMS, gold/
          # from noinst_PROGRAMS). The engine's link-capture sidecar is keyed by
          # that basename with no collision handling — last writer wins — so the
          # two clobber each other's captured object list. Rename gold's program
          # (automake var prefix `ld_new_` + the `ld-new$(EXEEXT)` program file) to
          # `ld-gold`, and let the program's `linkName` carry that spelling so
          # the applet keeps the upstream name `ld.gold` — a name we invented to
          # break a tie has no business being announced to the user. gold is
          # `noinst` and our self-fold replaces its custom install, so nothing
          # downstream depends on the old name. Patch the committed
          # automake output `gold/Makefile.in` (NOT the generated gold/Makefile):
          # binutils generates the subdir Makefiles during the recursive `make`,
          # after postConfigure runs, so gold/Makefile doesn't exist yet at that
          # point — config.status stamps it out from this .in during the build.
          # The bootstrap refs to the top-level BFD `$(abs_top_builddir)/ld-new`
          # carry no `$(EXEEXT)` and aren't matched (and aren't built anyway).
          postPatch = (old.postPatch or "") + ''
            if [ -f gold/Makefile.in ]; then
              sed -i -e 's/ld_new/ld_gold/g' \
                     -e 's/ld-new$(EXEEXT)/ld-gold$(EXEEXT)/g' gold/Makefile.in
            fi
          '';
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

      # Build via the unpin-llvm engine and emit a bitcode multicall module. The
      # engine compiles the ~two-dozen programs binutils builds by default (each a
      # separate upstream binary) to bitcode; the standalone self-folds them into
      # one `binutils`. Programs are listed under the name they INSTALL as, with
      # `linkName` carrying the linker's `-o` basename where upstream spells it
      # differently — nm←nm-new, strip←strip-new, c++filt←cxxfilt, ld←ld-new,
      # as←as-new, ld.gold←ld-gold (see the gold rename in `build`). Those six
      # used to be listed the other way round, because the capture sidecar is
      # keyed on the linked name and `name` was the only place to say it; that
      # also made `nm-new` an ANNOUNCED name, so `unpin install binutils` linked
      # a `nm-new` slot for a program that exists only inside the build tree.
      # The PE tools and gprof link under their own name. gold/dwp are
      # C++ — `requires.cxx` links the fold with $CXX and folds libc++ statically
      # (a no-op on the C-only darwin/riscv64 subsets, where gold isn't folded).
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
          { name = "ld"; linkName = "ld-new"; aliases = [ "ld.bfd" ]; }
          { name = "as"; linkName = "as-new"; }
          { name = "gprof"; }
          # The PE/COFF tools `--enable-targets=all` turns on: link under their own
          # name (no -new suffix), dispatched under that name.
          { name = "dlltool"; }
          { name = "windres"; }
          { name = "windmc"; }
          { name = "dllwrap"; }
          # gold + its dwp companion are ELF-only by design, and have no RISC-V
          # backend either (gold's configure.tgt omits riscv; gold is frozen), so
          # binutils' configure builds neither on a riscv64 host nor on the mingw
          # cross — matching the shipped riscv64 release, which folds the 19 tools
          # above only. `supportedTarget` drops both there (no link sidecar to
          # fold, no dangling dispatcher entry) and folds them on the other five
          # linux arches. gold/dwp are C++ — `requires.cxx` links the fold with
          # $CXX.
          {
            name = "ld.gold";
            linkName = "ld-gold";
            supportedTarget = p: (p.isElf or false) && !p.isRiscV64;
          }
          { name = "dwp"; supportedTarget = p: (p.isElf or false) && !p.isRiscV64; }
        ];
        # darwin: GNU ld/as have no Mach-O backend, gprof isn't built, and gold/dwp
        # are ELF-only — binutils' configure builds only the inspection tools + the
        # PE tools there (verified against the shipped x86_64-darwin release: 16
        # applets, no as/ld/gprof/gold/dwp). Fold exactly that subset on a darwin
        # host.
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
          { name = "dllwrap"; }
        ];
      };

      build = pkgs: mkBinutils pkgs.pkgsStatic;

      # The mingw cross self-folds from bitcode too now. Its applet set is the
      # 19 that `supportedTarget` leaves after dropping gold/dwp, and it is a
      # DECLARATION rather than the discovery the hand-rolled fold did: what the
      # .exe announces is exactly this list, so a program upstream does not build
      # here would ship an applet the dispatcher cannot reach.
      windowsBuild = pkgs: mkBinutils (ulib.mingwStaticCross pkgs);
    };
}
