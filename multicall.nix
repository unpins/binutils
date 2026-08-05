# WINDOWS-ONLY as of the unpin-llvm engine migration. Linux + macOS now
# self-fold from bitcode via nix-lib's multicallModuleHookLTO (see flake.nix);
# this hand-rolled ld-r/objcopy recipe operates on native ELF/COFF objects and
# archives, which the engine's -flto bitcode path is not, so it is reached only
# through `windowsBuild` (the mingw cross). The isDarwin/isElf branches below
# are dead on that path (the mingw stdenv reports isWindows) but kept intact.
#
# Upstream binutils ships ~a dozen-and-a-half separate programs spread across
# several build subdirs that share a stack of static archives (`libbfd.a`,
# `libopcodes.a`, `libctf.a`, `libsframe.a`, `libiberty.a`, and — ELF only —
# `libgold.a`). To honour the one-pkg-one-bin rule we fold them into a single
# multicall binary that dispatches on `argv[0]`.
#
# Scope is MAXIMAL — every program that builds on the platform, accepting per-OS
# differences. Rather than hard-code three per-OS applet lists, the recipe is
# SELF-ADAPTING: it offers the full candidate set to every platform and folds in
# exactly the ones whose subdir was configured and whose link line yields
# objects. The 12 inspection/manipulation tools are *required* (a build that
# can't produce one is a real regression → hard error); everything else is
# *optional* (silently skipped + logged when the platform didn't build it).
#
#   inspection/manip (required, every OS):
#     objdump nm readelf ar ranlib strings size strip objcopy
#     addr2line c++filt elfedit
#   optional, folded when present:
#     ld (+ ld.bfd alias)   the BFD linker        — ELF + PE (not Mach-O)
#     as                    the GNU assembler     — ELF + PE (gas is off on
#                                                   darwin: BFD has no Mach-O
#                                                   assembler backend)
#     gprof                 the profiler
#     ld.gold, dwp          gold linker + DWARF packager, C++  — ELF only
#                           (gold/dwp are ELF-only by design)
#     dlltool windres       PE import-lib / resource tools     — Windows only
#     windmc dllwrap        PE message-compiler / dll wrapper   — Windows only
#
# So the natural per-OS outcome is: Linux = the full 18-name set (gold/dwp incl);
# Windows = inspection + ld/as/gprof + the four PE tools (no gold/dwp); macOS =
# inspection + gprof only (GNU ld/as can't emit Mach-O, so binutils' own
# configure drops them — that per-OS difference is accepted, as the user asked).
# `--enable-targets=all` still makes objdump/readelf/ld grok every architecture's
# object files everywhere; `as` is single-target by nature (host arch only).
#
# Why a *rebuild* recipe (Recipe A, procps-ng style) rather than splicing the
# already-built objects:
#
#   * Several tools are compiled from the *same* source. `objcopy` ⇐ not-strip.c
#     and `strip` ⇐ is-strip.c both `#include "objcopy.c"`; `ar` ⇐ not-ranlib.c
#     and `ranlib` ⇐ is-ranlib.c both `#include "ar.c"`. Each pair defines an
#     identical set of globals (plus its own `main`).
#   * Shared helpers (`bucomm.c`/`dwarf.c`/`elfcomm.c`/… in binutils/, the
#     emulation objects in ld/, …) are compiled once and reused.
#
# Fix: recompile every tool's objects with a per-tool `-include` header that
# `#define`s `main` → `bu_<san>_main` and every other defined global `foo` →
# `<san>__foo`, privatising each tool's surface across the final link. The big
# archives stay *shared* (linked once at the end). The `bu_` prefix on the
# dispatched main is required: binutils' own sources already use `ranlib_main`/
# `strip_main`/`copy_main` as static helpers, so a plain `<san>_main` collides.
#
# Shared by the native `build` (pkgsStatic) and `windowsBuild`
# (mingwStaticCross) paths; isDarwin/isWindows come from the INPUT derivation's
# stdenv (under windowsBuild `pkgs` is the x86_64-linux root — the cross lives
# inside mingwStaticCross — so `pkgs.stdenv` would wrongly say "not Windows").
{ lib }:
{ pkgs, binutils }:
let
  isDarwin = binutils.stdenv.hostPlatform.isDarwin or false;
  isWindows = binutils.stdenv.hostPlatform.isWindows or false;
  isElf = binutils.stdenv.hostPlatform.isElf or false;

  # gold/dwp are ELF-only (gold has no Mach-O / PE backend). That is the only
  # C++ in the binary, so its presence also decides the link driver (g++ vs cc)
  # and whether libgold.a joins the shared-archive group.
  hasGold = isElf && !isDarwin && !isWindows;

  exeext = if isWindows then ".exe" else "";

  # darwin only: windres/windmc's winduni.c does charset conversion via iconv,
  # which on macOS lives in libiconv (NOT libSystem). Fold the *static*
  # libiconv.a into the final link — a plain `-liconv` would pull
  # /usr/lib/libiconv.2.dylib, which the darwin allow-list rejects. libiconv is
  # a leaf in pkgsStatic, so this doesn't drag the broken cctools-static cascade
  # (see docs/platforms/darwin.md "the libiconv catch"). Lazily forced — only
  # evaluated on the isDarwin link path.
  iconvStatic = pkgs.pkgsStatic.libiconv;

  # applet (argv[0] name) · build subdir · upstream make-target file.
  # `required` tools must build on every platform; the rest are folded only when
  # the platform actually produced them (see the self-adapting discovery below).
  requiredPrograms = [
    { a = "objdump"; d = "binutils"; t = "objdump"; }
    { a = "nm"; d = "binutils"; t = "nm-new"; }
    { a = "readelf"; d = "binutils"; t = "readelf"; }
    { a = "ar"; d = "binutils"; t = "ar"; }
    { a = "ranlib"; d = "binutils"; t = "ranlib"; }
    { a = "strings"; d = "binutils"; t = "strings"; }
    { a = "size"; d = "binutils"; t = "size"; }
    { a = "strip"; d = "binutils"; t = "strip-new"; }
    { a = "objcopy"; d = "binutils"; t = "objcopy"; }
    { a = "addr2line"; d = "binutils"; t = "addr2line"; }
    { a = "c++filt"; d = "binutils"; t = "cxxfilt"; }
    { a = "elfedit"; d = "binutils"; t = "elfedit"; }
  ];
  optionalPrograms = [
    { a = "ld"; d = "ld"; t = "ld-new"; }
    { a = "as"; d = "gas"; t = "as-new"; }
    { a = "gprof"; d = "gprof"; t = "gprof"; }
    { a = "ld.gold"; d = "gold"; t = "ld-new"; }
    { a = "dwp"; d = "gold"; t = "dwp"; }
    # PE-only tools (binutils/ subdir, built when the target is PE/COFF).
    { a = "dlltool"; d = "binutils"; t = "dlltool"; }
    { a = "windres"; d = "binutils"; t = "windres"; }
    { a = "windmc"; d = "binutils"; t = "windmc"; }
    { a = "dllwrap"; d = "binutils"; t = "dllwrap"; }
  ];
  allPrograms = requiredPrograms ++ optionalPrograms;

  requiredSet = lib.concatMapStringsSep " " (p: p.a) requiredPrograms;
  mapTsv = lib.concatMapStrings (p: "${p.a}\t${p.d}\t${p.t}\n") allPrograms;

  # man-page source per applet (committed roff in the source tree). `ld.bfd` is
  # an alias of ld, so it reuses ld.1 — handled in the install loop. Programs
  # without a committed man page (gold/dwp; dllwrap) simply skip (the install
  # loop probes for file existence).
  manRelOf = a:
    if a == "ld" then "ld/ld.1"
    else if a == "as" then "gas/doc/as.1"
    else if a == "gprof" then "gprof/gprof.1"
    else "binutils/doc/${a}.1";
  manMapTsv = lib.concatMapStrings (p: "${p.a}\t${manRelOf p.a}\n") allPrograms;

  # Final link reuses binutils/Makefile context so configure-detected leaf libs
  # ($(ZLIB) $(ZSTD_LIBS) …) expand exactly as upstream resolved them. The big
  # archives are passed in via $(MULTI_ARCHIVES); on GNU ld they are wrapped in
  # one --start-group (cross-references resolve regardless of order), while ld64
  # (darwin) rejects --start-group and re-scans on its own — there we just list
  # the set twice (cheap insurance for the bfd↔opcodes↔ctf back-refs). The
  # driver is $(MULTI_DRIVER): g++ when gold/dwp (C++) are folded in, else cc.
  # NLS ($(LIBINTL)) is left out of darwin/windows builds (--disable-nls) to
  # avoid dragging a dynamic libintl/libiconv there; on linux musl's libintl is
  # static so it stays.
  multicallMk = pkgs.writeText "unpin-binutils-multicall.mk" ''
    MULTI_OBJS ?=
    MULTI_DRIVER ?= $(CC)
    MULTI_ARCHIVES ?=
    MULTI_GROUP_START ?=
    MULTI_GROUP_END ?=
    MULTI_EXTRA_LDFLAGS ?=
    MULTI_EXTRA_LIBS ?=

    .PHONY: multicall-link
    multicall-link: multicall/binutils

    multicall/binutils: multicall/dispatcher.o $(MULTI_OBJS)
    	$(MULTI_DRIVER) $(CFLAGS) $(AM_LDFLAGS) $(LDFLAGS) $(MULTI_EXTRA_LDFLAGS) -o $@ \
    		multicall/dispatcher.o $(MULTI_OBJS) \
    		$(MULTI_GROUP_START) $(MULTI_ARCHIVES) $(MULTI_GROUP_END) \
    		$(LIBINTL) $(ZLIB) $(ZSTD_LIBS) $(DEBUGINFOD_LIBS) \
    		$(MSGPACK_LIBS) $(LEXLIB) $(LIBS) $(MULTI_EXTRA_LIBS)
  '';

  multicall = binutils.overrideAttrs (old: {
    pname = "binutils-multi";

    # Single output: we replace installPhase and only fill $out.
    outputs = [ "out" ];

    # `--enable-targets=all` so one objdump/readelf/ld groks every architecture.
    # ld/gas/gprof/gold build by default where the platform supports them
    # (the nixpkgs derivation already sets `--enable-gold` on ELF targets); we
    # never disable any of them ourselves. `--disable-nls` on darwin/windows
    # keeps libintl/libiconv out of those binaries (linux keeps static NLS).
    configureFlags = (old.configureFlags or [ ]) ++ [
      "--enable-targets=all"
    ] ++ lib.optionals (isDarwin || isWindows) [
      "--disable-nls"
    ];

    postBuild = (old.postBuild or "") + ''
      set -e
      root=$PWD
      mkdir -p binutils/multicall
      mc="$root/binutils/multicall"
      printf '%s' ${lib.escapeShellArg mapTsv} > "$mc/map.tsv"
      printf '%s' ${lib.escapeShellArg manMapTsv} > "$mc/manmap.tsv"

      _orig_NIX_CFLAGS_COMPILE=''${NIX_CFLAGS_COMPILE:-}
      REQUIRED="${requiredSet}"
      EXE=${lib.escapeShellArg exeext}   # "" on ELF/Mach-O, ".exe" on mingw

      # Mach-O leads C symbols with '_'. Detect once and strip it so the rename
      # `#define`s land on source-level names (the rebuild then re-adds the '_').
      up=""
      ${lib.optionalString isDarwin ''up="_"''}

      # ---- Phase A: discover objects + globals (PRISTINE .o), pick clashes ----
      # Self-adapting: a candidate is folded in only if its subdir was configured
      # (Makefile present) AND its link line yields objects. Required tools that
      # fail either test are a hard error; optional ones are skipped + logged.
      # Must run fully before any rebuild (Phase B recompiles shared objects in
      # place, so discovery reads the first-pass, un-renamed objects first).
      #
      # We privatise ONLY symbols a clash actually needs — those DEFINED by >=2
      # applets (the shared helpers bucomm/dwarf/elfcomm/…, the yacc `yyparse`,
      # `program_name`, …). Renaming EVERY global instead breaks gas: its
      # machine-dependent `md_*` interface (`md_operand`, `md_convert_frag`, …)
      # relies on the real names across its prototype/macro machinery, and those
      # are unique to `as`, so they need no rename.
      : > "$mc/built.tsv"
      while IFS=$'\t' read -r applet subdir target; do
        [ -n "$applet" ] || continue
        san=$(printf '%s' "$applet" | tr -c 'A-Za-z0-9_' '_')
        required=no
        case " $REQUIRED " in *" $applet "*) required=yes ;; esac

        if [ ! -f "$root/$subdir/Makefile" ]; then
          if [ "$required" = yes ]; then
            echo "ERROR: required applet $applet: $subdir not configured" >&2
            exit 1
          fi
          echo "=== binutils multicall: skip $applet ($subdir not configured) ==="
          continue
        fi

        objs=$(
          cd "$root/$subdir"
          # Take objects from the LINK line only (the one that outputs the
          # program), NOT the whole `make -n` dump: gold's ld-new pulls
          # libgold.a, whose archive-build commands would otherwise leak
          # libgold's own members (workqueue.o, …) into this tool's set →
          # multiple definition against libgold.a at the final link. The C tools
          # list all their objects on the (libtool) link line, so this is
          # identical for them. automake names the file `<target>$(EXEEXT)`, so
          # ask make for `$target$EXE` (`.exe` on mingw). `tail` keeps the exit
          # status 0 even when grep matches nothing (empty = skip).
          rm -f "$target$EXE"
          make -n "$target$EXE" 2>/dev/null \
            | grep -E -- " -o ([^ ]*/)?$target$EXE( |\$)" | tail -1 \
            | tr ' ' '\n' | grep -E '\.o$' | grep -vE '^[/-]' | sort -u
        )
        if [ -z "$objs" ]; then
          if [ "$required" = yes ]; then
            echo "ERROR: no objects discovered for required $subdir/$target" >&2
            exit 1
          fi
          echo "=== binutils multicall: skip $applet (no objects from $subdir/$target) ==="
          continue
        fi

        printf '%s\n' "$objs" > "$mc/$san.objs"
        ( cd "$root/$subdir"
          $NM --defined-only -g $objs 2>/dev/null \
            | awk -v up="$up" '
                { n = $3; if (n == "") next
                  if (up != "" && index(n, up) == 1) n = substr(n, 2)
                  if (n ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && n != "main") print n }' \
            | sort -u
        ) > "$mc/$san.syms"
        printf '%s\t%s\t%s\n' "$applet" "$subdir" "$target" >> "$mc/built.tsv"
      done < "$mc/map.tsv"

      echo "=== binutils multicall: $(wc -l < "$mc/built.tsv") programs fold in ==="

      # A2: shared = defined by >=2 applets (each .syms is per-applet sorted -u,
      # so a duplicate across the concatenation means >=2 applets define it).
      cat "$mc"/*.syms | sort | uniq -d > "$mc/shared.syms"
      echo "=== binutils multicall: $(wc -l < "$mc/shared.syms") shared symbols privatised ==="

      # A3: per-applet rename header — `main` → bu_<san>_main, plus only the
      # shared symbols THIS applet defines → <san>__<sym>. (`bu_` prefix on main
      # because binutils' own sources use static `ranlib_main`/`strip_main`/
      # `copy_main`, which a plain `<san>_main` would textually collide with.)
      while IFS=$'\t' read -r applet subdir target; do
        [ -n "$applet" ] || continue
        san=$(printf '%s' "$applet" | tr -c 'A-Za-z0-9_' '_')
        {
          echo "/* binutils multicall rename header: $san */"
          # C++ tools (gold/dwp): the renamed main must keep C linkage, else g++
          # mangles `bu_<san>_main` and the C dispatcher can't resolve it. The
          # decl is harmless in the C tools' objects (guarded by __cplusplus).
          printf '#ifdef __cplusplus\nextern "C" int bu_%s_main(int, char **);\n#endif\n' "$san"
          echo "#define main bu_''${san}_main"
          comm -12 "$mc/$san.syms" "$mc/shared.syms" \
            | awk -v s="$san" '{ print "#define " $1 " " s "__" $1 }'
        } > "$mc/$san.rename.h"
      done < "$mc/built.tsv"

      # ---- Phase B: rebuild each tool with its header, isolate the copies ----
      : > "$mc/all_objs.list"
      : > "$mc/applets.list"
      while IFS=$'\t' read -r applet subdir target; do
        [ -n "$applet" ] || continue
        san=$(printf '%s' "$applet" | tr -c 'A-Za-z0-9_' '_')
        objs=$(cat "$mc/$san.objs")
        (
          cd "$root/$subdir"
          rm -f $objs
          NIX_CFLAGS_COMPILE="$_orig_NIX_CFLAGS_COMPILE -include $mc/$san.rename.h" \
            make -j''${NIX_BUILD_CORES:-1} $objs

          mkdir -p "$mc/$san"
          for o in $objs; do
            flat=$(printf '%s' "$o" | tr '/' '_')
            cp "$o" "$mc/$san/$flat"
            echo "multicall/$san/$flat" >> "$mc/all_objs.list"
          done
        )
        printf '%s\tbu_%s\n' "$applet" "$san" >> "$mc/applets.list"
      done < "$mc/built.tsv"

      # `ld.bfd` is the explicit name for the BFD linker — same bu_ld_main, only
      # emitted when ld itself folded in.
      if grep -qP '^ld\t' "$mc/built.tsv"; then
        printf 'ld.bfd\tbu_ld\n' >> "$mc/applets.list"
      fi
      echo "=== binutils multicall: $(wc -l < "$mc/applets.list") dispatch names ==="

      # ---- Dispatcher (TSV name\tfn → <fn>_main; bare/renamed → listing) ----
      cd "$root/binutils"
${lib.multicallTableDispatcherC { name = "binutils"; }}
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c
      cd "$root"

      # ---- Compute final-link knobs (driver / archives / group flags) --------
      # Discover which shared archives exist (libctf/libsframe/libgold are not
      # built on every platform); include only the ones present. Order is the
      # GNU --start-group order; ld64 gets the set listed twice.
      archs=""
      for rel in opcodes/.libs/libopcodes.a bfd/.libs/libbfd.a \
                 libctf/.libs/libctf.a libsframe/.libs/libsframe.a \
                 gold/libgold.a libiberty/libiberty.a; do
        [ -f "$root/$rel" ] && archs="$archs ../$rel"
      done

      MULTI_DRIVER='$(CC)'
      ${lib.optionalString hasGold ''MULTI_DRIVER='$(CXX)' ''}

      if ${if isDarwin then "true" else "false"}; then
        GROUP_START=""; GROUP_END=""
        ARCHIVES="$archs $archs"          # ld64: re-list, no --start-group
      else
        GROUP_START="-Wl,--start-group"; GROUP_END="-Wl,--end-group"
        ARCHIVES="$archs"
      fi

      EXTRA_LDFLAGS=""
      ${lib.optionalString isWindows ''EXTRA_LDFLAGS="-static -static-libgcc"''}

      EXTRA_LIBS=""
      ${lib.optionalString isDarwin ''
        # pkgsStatic libiconv stows its .a in the `dev` output (not `out`/`lib`),
        # so probe getDev/getLib/out and take the first hit per archive.
        for base in libiconv libcharset; do
          for cand in ${lib.getDev iconvStatic}/lib/$base.a \
                      ${lib.getLib iconvStatic}/lib/$base.a \
                      ${iconvStatic}/lib/$base.a; do
            if [ -f "$cand" ]; then EXTRA_LIBS="$EXTRA_LIBS $cand"; break; fi
          done
        done
        [ -n "$EXTRA_LIBS" ] || { echo "ERROR: darwin libiconv.a not found" >&2; exit 1; }
        echo "=== binutils multicall: darwin extra libs:$EXTRA_LIBS ==="
      ''}

      # ---- Final link (delegated to the Makefile for leaf-lib var expansion) --
      install -m644 ${multicallMk} binutils/unpin-multicall.mk
      make -C binutils -f Makefile -f unpin-multicall.mk \
        MULTI_OBJS="$(tr '\n' ' ' < "$mc/all_objs.list")" \
        MULTI_DRIVER="$MULTI_DRIVER" \
        MULTI_ARCHIVES="$ARCHIVES" \
        MULTI_GROUP_START="$GROUP_START" \
        MULTI_GROUP_END="$GROUP_END" \
        MULTI_EXTRA_LDFLAGS="$EXTRA_LDFLAGS" \
        MULTI_EXTRA_LIBS="$EXTRA_LIBS" \
        multicall-link

      # mingw gcc appends .exe; normalise to a suffix-free name for install.
      [ -f binutils/multicall/binutils ] || mv binutils/multicall/binutils.exe binutils/multicall/binutils
    '';

    # Replace install: upstream's rule would relink each per-tool binary, which
    # now fails (we renamed `main`). Ship one `binutils` + argv[0] symlinks; the
    # man pages are committed roff in the tree (withMan harvests $out/share/man).
    # The applet set is whatever actually folded in (multicall/built.tsv), so the
    # symlinks + man match the platform's real program list.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      install -m755 binutils/multicall/binutils "$out/bin/binutils"

      mc="$PWD/binutils/multicall"

      # argv[0] symlinks for every folded-in applet (+ the ld.bfd alias). These
      # are consumed by withAliases (it reads the names, then deletes the links).
      while IFS=$'\t' read -r applet _subdir _target; do
        [ -n "$applet" ] || continue
        ln -s binutils "$out/bin/$applet"
      done < "$mc/built.tsv"
      if grep -qP '^ld\t' "$mc/built.tsv"; then
        ln -s binutils "$out/bin/ld.bfd"
      fi

      # Man pages: install the committed roff for each folded-in applet, probing
      # both the (out-of-source) build tree and the pristine source tree, since
      # ld.1/gprof.1 aren't regenerated in the build dir. Missing pages (gold/dwp,
      # dllwrap) are skipped gracefully.
      while IFS=$'\t' read -r applet rel; do
        [ -n "$applet" ] || continue
        grep -qP "^$(printf '%s' "$applet" | sed 's/[.[\*+]/\\&/g')\t" "$mc/built.tsv" || continue
        for cand in "$NIX_BUILD_TOP/$sourceRoot/$rel" "$rel"; do
          if [ -f "$cand" ]; then
            install -Dm644 "$cand" "$out/share/man/man1/$applet.1"
            break
          fi
        done
      done < "$mc/manmap.tsv"
      runHook postInstall
    '';
  });

  aliased = lib.withAliases pkgs
    {
      primary = "binutils";
      aliasesFromSymlinksIn = "bin";
    }
    multicall;
in
if isWindows
then aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/binutils" ] && mv "$out/bin/binutils" "$out/bin/binutils.exe"
  '';
})
else aliased
