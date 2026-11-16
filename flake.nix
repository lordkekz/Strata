{
  description = "Generic FHS environment for C/C++ toolchains, Python, and GPU computing";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      pythonEnv = pkgs.python313.withPackages (ps: with ps; [
        pip
        virtualenv
        setuptools
        wheel
        # Dépendances requises par Strata et son serveur
        jinja2
        numpy
        requests
        pyyaml
        regex
        tqdm
        pillow
        psutil
      ]);

      fhsEnv = pkgs.buildFHSEnv {
        name = "build-fhs";
        targetPkgs = pkgs: with pkgs; [
          # Chaîne de compilation C/C++ de base
          gcc
          gcc.cc
          glibc
          glibc.dev
          stdenv.cc.cc.lib
          binutils

          # Outils de métaconstruction
          cmake
          ninja
          gnumake
          pkg-config
          git

          # Débogage et introspection
          gdb
          valgrind

          # Interpréteur Python enveloppé avec ses modules
          pythonEnv

          # Bibliothèques système standard pour liaisons dynamiques
          zlib
          ncurses
          libxml2
          numactl
          pciutils
          libdrm
          util-linux
        ];

        profile = ''
          export HARDENING_DISABLE=all
          export LIBRARY_PATH="/usr/lib:/usr/lib64:$LIBRARY_PATH"
          export CPATH="/usr/include:$CPATH"
        '';

        runScript = "bash --norc --noprofile";
      };
    in
    {
      packages.${system}.default = fhsEnv;

      apps.${system}.default = {
        type = "app";
        program = "${fhsEnv}/bin/build-fhs";
      };
    };
}
