{
  description = "A batteries-included development environment for jovian.nvim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);
    in
    {
      overlays.default = final: prev: {
        # Native Rust backend. Built once, shared between the standalone
        # `jovian-core` package and the bundled-in-plugin postPatch below.
        # buildAndTestSubdir keeps cargo scoped to core/ so the flake's other
        # files don't trigger spurious rebuilds.
        jovian-core = final.rustPlatform.buildRustPackage {
          pname = "jovian-core";
          version = "0.1.0";
          # Only the core/ subtree is needed for the Rust build; using a
          # narrower src avoids invalidating the cargoSetupHook every time an
          # unrelated lua/ or test file changes.
          src = "${self}/core";
          cargoLock.lockFile = "${self}/core/Cargo.lock";
          # Pure-rust zmq crate — no C deps, no system libzmq required. We
          # still need a C linker (provided by buildRustPackage's default
          # stdenv) for the final link step.
          doCheck = false;
        };

        vimPlugins = prev.vimPlugins // {
          jovian-nvim = final.vimUtils.buildVimPlugin {
            pname = "jovian-nvim";
            version = "unstable";
            src = self;
            dependencies = [ ];
            postPatch = ''
              substituteInPlace lua/jovian/backend/zmq.lua \
                --replace 'ffi.load, "zmq"' 'ffi.load, "${final.zeromq}/lib/libzmq${final.stdenv.hostPlatform.extensions.sharedLibrary}"'
              substituteInPlace lua/jovian/backend/messenger.lua \
                --replace 'ffi.load, "crypto"' 'ffi.load, "${final.openssl.out}/lib/libcrypto${final.stdenv.hostPlatform.extensions.sharedLibrary}"'

              # Drop the prebuilt jovian-core binary where lua/jovian/backend/core.lua
              # looks for it (`<plugin_dir>/core/target/release/jovian-core`).
              # This makes the plugin work out of the box under nix without the
              # lazy.nvim build hook ever running install.lua.
              mkdir -p core/target/release
              install -m755 ${final.jovian-core}/bin/jovian-core core/target/release/jovian-core
            '';
          };
        };
        # Provide the minimal python environment as a top-level attribute in pkgs
        jovian-minimal-python = final.python3.withPackages (ps: with ps; [
          ipython
          ipykernel
          jupyter-client
        ]);
      };

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [ self.overlays.default ];
          };

          # Full environment for testing and demoing
          pythonEnvFull = pkgs.python3.withPackages (
            ps: with ps; [
              ipython
              ipykernel
              jupyter-client
              numpy
              pandas
              matplotlib
              tqdm
            ]
          );

          initLua = pkgs.writeText "init.lua" ''
            -- Setup image.nvim
            local image_ok, image = pcall(require, "image")
            if image_ok then
              image.setup({
                backend = "kitty",
                processor = "magick_cli",
                max_width_window_percentage = 100,
                max_height_window_percentage = 100,
                window_overlap_clear_enabled = true,
              })
            end

            -- Setup jovian.nvim
            require("jovian").setup({
              python_interpreter = "${pythonEnvFull}/bin/python3",
            })

            -- Setup nvim-treesitter
            local ts_ok, ts_configs = pcall(require, "nvim-treesitter.configs")
            if ts_ok then
                ts_configs.setup({
                    highlight = {
                        enable = true,
                        additional_vim_regex_highlighting = false,
                    },
                })
            end

            vim.opt.number = true
            vim.opt.termguicolors = true
            vim.cmd("colorscheme habamax")

            vim.diagnostic.config({
              virtual_text = true,
              signs = true,
              underline = true,
              update_in_insert = false,
            })
            vim.lsp.config("pyright", {})
            vim.lsp.config("ruff", {})
            vim.lsp.enable("pyright")
            vim.lsp.enable("ruff")
          '';

          neovimWithPlugins = pkgs.neovim.override {
            configure = {
              customRC = "";
              packages.myVimPackage = {
                start = [
                  pkgs.vimPlugins.jovian-nvim
                  pkgs.vimPlugins.image-nvim
                  pkgs.vimPlugins.jupytext-nvim
                  pkgs.vimPlugins.nvim-lspconfig
                  (pkgs.vimPlugins.nvim-treesitter.withPlugins (p: [
                    p.python
                    p.markdown
                    p.markdown_inline
                  ]))
                ];
              };
            };
          };

          nvim-jovian = pkgs.writeShellScriptBin "nvim-jovian" ''
            export NVIM_APPNAME="nvim-jovian-demo"
            export XDG_CONFIG_HOME=$(mktemp -d)
            export XDG_DATA_HOME=$(mktemp -d)
            export XDG_STATE_HOME=$(mktemp -d)
            export JOVIAN_PYTHON="${pythonEnvFull}/bin/python3"
            export LD_LIBRARY_PATH="${pkgs.zeromq}/lib:${pkgs.openssl}/lib:$LD_LIBRARY_PATH"
            exec ${neovimWithPlugins}/bin/nvim -u ${initLua} "$@"
          '';

          nvim-jovian-fallback = pkgs.writeShellScriptBin "nvim-jovian-fallback" ''
            export NVIM_APPNAME="nvim-jovian-fallback"
            export XDG_CONFIG_HOME=$(mktemp -d)
            export XDG_DATA_HOME=$(mktemp -d)
            export XDG_STATE_HOME=$(mktemp -d)
            export JOVIAN_PYTHON="${pythonEnvFull}/bin/python3"
            # Note: No ZMQ or OpenSSL in LD_LIBRARY_PATH here
            exec ${neovimWithPlugins}/bin/nvim -u ${initLua} "$@"
          '';

          run-tests = pkgs.writeShellScriptBin "run-tests" ''
            echo ">>> Running New Feature Integration Tests (Real Kernel)..."
            ${nvim-jovian}/bin/nvim-jovian --headless -l tests/test_features.lua

            echo ">>> Running Integration Tests (Real Kernel)..."
            ${nvim-jovian}/bin/nvim-jovian --headless -l tests/edge_cases.lua

            echo ">>> Running Command Tests (Mocked)..."
            ${nvim-jovian}/bin/nvim-jovian --headless -l tests/test_commands.lua

            echo ">>> Running Cell Unit Tests..."
            ${nvim-jovian}/bin/nvim-jovian --headless -l tests/test_cell.lua

            echo ">>> Running Async Flow Tests..."
            ${nvim-jovian}/bin/nvim-jovian --headless -l tests/test_async_flow.lua

            echo ">>> Running UI/Layout Tests..."
            ${nvim-jovian}/bin/nvim-jovian --headless -l tests/test_resize_layout.lua

            echo ">>> Running Rust Backend Phase 1 Smoke Test (Real Kernel)..."
            ${nvim-jovian}/bin/nvim-jovian --headless -l tests/test_rust_phase1.lua
          '';

          run-tests-fallback = pkgs.writeShellScriptBin "run-tests-fallback" ''
            echo ">>> Running Fallback Mode Tests (NO Native ZMQ)..."
            ${nvim-jovian-fallback}/bin/nvim-jovian-fallback --headless -l tests/test_features.lua
            ${nvim-jovian-fallback}/bin/nvim-jovian-fallback --headless -l tests/edge_cases.lua
          '';
        in
        {
          default = nvim-jovian;
          nvim-jovian = nvim-jovian;
          nvim-jovian-fallback = nvim-jovian-fallback;
          jovian-nvim = pkgs.vimPlugins.jovian-nvim;
          jovian-core = pkgs.jovian-core;
          pythonEnv = pythonEnvFull;
          pythonEnvMinimal = pkgs.jovian-minimal-python;
          run-tests = run-tests;
          run-tests-fallback = run-tests-fallback;
        }
      );

      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [ self.overlays.default ];
          };
        in
        {
          integration-test = pkgs.stdenv.mkDerivation {
            name = "jovian-integration-test";
            src = self;
            buildInputs = [ self.packages.${system}.run-tests ];
            buildPhase = ''
              export HOME=$TMPDIR
              ${self.packages.${system}.run-tests}/bin/run-tests
            '';
            installPhase = "touch $out";
          };

          fallback-test = pkgs.stdenv.mkDerivation {
            name = "jovian-fallback-test";
            src = self;
            buildInputs = [ self.packages.${system}.run-tests-fallback ];
            buildPhase = ''
              export HOME=$TMPDIR
              ${self.packages.${system}.run-tests-fallback}/bin/run-tests-fallback
            '';
            installPhase = "touch $out";
          };

          lua-lint = pkgs.stdenv.mkDerivation {
            name = "jovian-lua-lint";
            src = self;
            nativeBuildInputs = [ pkgs.stylua pkgs.lua51Packages.luacheck ];
            buildPhase = ''
              stylua --check .
              luacheck .
            '';
            installPhase = "touch $out";
          };

          python-lint = pkgs.stdenv.mkDerivation {
            name = "jovian-python-lint";
            src = self;
            nativeBuildInputs = [ pkgs.python3Packages.ruff ];
            buildPhase = ''
              ruff check .
            '';
            installPhase = "touch $out";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [ self.overlays.default ];
          };
          pythonEnv = pkgs.python3.withPackages (
            ps: with ps; [
              ipython
              ipykernel
              jupyter-client
              numpy
              pandas
              matplotlib
              tqdm
              tkinter
            ]
          );
        in
        {
          default = pkgs.mkShell {
            packages = [
              self.packages.${system}.nvim-jovian
              self.packages.${system}.run-tests
              pkgs.neovim
              pkgs.imagemagick
              pkgs.pyright
              pkgs.ruff
              pkgs.stylua
              pkgs.lua51Packages.luacheck
              pkgs.libnotify
              pkgs.zeromq
              pkgs.openssl
              pythonEnv

              # Rust toolchain for building jovian-core (the native backend).
              # Pure-rust zmq crate so libzmq/openssl are NOT linked into the
              # binary; they remain only for the legacy lua/jovian/backend/zmq.lua
              # FFI path during the Phase 0..4 migration.
              pkgs.cargo
              pkgs.rustc
              pkgs.rustfmt
              pkgs.clippy
              pkgs.pkg-config
            ];

            shellHook = ''
              echo "🪐 Jovian.nvim development environment loaded!"

              if [ ! -f demo_jovian.py ]; then
                echo "Copying demo_jovian.py to current directory..."
                cp ${self}/examples/demo_jovian.py .
                chmod +w demo_jovian.py
              fi

              if [ -d core ] && [ ! -f core/target/release/jovian-core ]; then
                echo "🦀 Building jovian-core (first-time native backend build)..."
                (cd core && cargo build --release) || \
                  echo "  ⚠ cargo build failed; run 'cd core && cargo build --release' manually."
              fi

              echo "Run 'nvim-jovian demo_jovian.py' to try the plugin."
            '';
          };
        }
      );
    };
}
