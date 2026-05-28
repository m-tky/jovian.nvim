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
              numpy
              pandas
              matplotlib
              tqdm
            ]
          );

          initLua = pkgs.writeText "init.lua" ''
            -- Setup jovian.nvim. use_rust_core defaults to true post-
            -- Phase 5, so we just opt in to the visual upgrades and
            -- inline outputs here; the Rust backend handles execute /
            -- Vars / View transparently.
            require("jovian").setup({
              python_interpreter = "${pythonEnvFull}/bin/python3",
              cell_frame = true,
              markdown_cell_style = true,
              inline_outputs = true,
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
            # Resolve the controlling tty in the launching shell (where it
            # still exists) and hand it down so the Rust core can write
            # Kitty graphics escapes. macOS lacks /proc, so without this
            # env var the Lua fallback can't find the tty.
            JOVIAN_TTY=$(tty 2>/dev/null) || JOVIAN_TTY=""
            export JOVIAN_TTY
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

            echo ">>> Running Cell Frame + Markdown Styling Tests..."
            ${nvim-jovian}/bin/nvim-jovian --headless -l tests/test_cell_frame.lua

            echo ">>> Running Inline Output Rendering Tests..."
            ${nvim-jovian}/bin/nvim-jovian --headless -l tests/test_inline_outputs.lua

            echo ">>> Running Kitty Image Placeholder Tests..."
            ${nvim-jovian}/bin/nvim-jovian --headless -l tests/test_kitty_images.lua

            echo ">>> Running Rust Backend Phase 1 Smoke Test (Real Kernel)..."
            ${nvim-jovian}/bin/nvim-jovian --headless -l tests/test_rust_phase1.lua
          '';
        in
        {
          default = nvim-jovian;
          nvim-jovian = nvim-jovian;
          jovian-nvim = pkgs.vimPlugins.jovian-nvim;
          jovian-core = pkgs.jovian-core;
          pythonEnv = pythonEnvFull;
          pythonEnvMinimal = pkgs.jovian-minimal-python;
          run-tests = run-tests;
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
              pythonEnv

              # Rust toolchain for building jovian-core (the native backend).
              # The zmq crate is pure-rust, so no system libzmq/openssl needed.
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
