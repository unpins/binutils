{
  description = "Standalone build of the GNU binary utilities";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # binutils ships ~a dozen-and-a-half programs across several build subdirs
  # (objdump/readelf/nm/ar/…, the `ld` linker, the `as` assembler, gprof, the
  # gold linker, the PE dlltool/windres family). ./multicall.nix folds whatever
  # the platform actually builds into one `argv[0]`-dispatching binary via the
  # Recipe-A rebuild route (lib.multicallTableDispatcherC). `--enable-targets=all`
  # makes a single objdump/readelf/ld understand every architecture's object
  # files. The applet set is self-adapting per OS (gold/dwp are ELF-only; the PE
  # tools are Windows-only; GNU ld/as don't target Mach-O so macOS gets the
  # inspection tools + gprof) — see ./multicall.nix.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "binutils";
      # The binutils programs, libbfd and libopcodes are all GPL-3.0-or-later;
      # libiberty (folded in statically) is more permissive but doesn't loosen
      # the combined binary. nixpkgs reports the full component list -- pin the
      # effective license so the catalog shows one SPDX id.
      license = "GPL-3.0-or-later";
      smoke = [ "--version" ];
      smokePattern = "GNU Binutils";

      build = pkgs:
        import ./multicall.nix { lib = pkgs.lib // ulib; }
          { inherit pkgs; binutils = pkgs.pkgsStatic.binutils-unwrapped; };

      windowsBuild = pkgs:
        import ./multicall.nix { lib = pkgs.lib // ulib; }
          { inherit pkgs; binutils = (ulib.mingwStaticCross pkgs).binutils-unwrapped; };
    };
}
