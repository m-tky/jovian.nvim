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
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };

          pythonEnv = pkgs.python3.withPackages (
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
            -- Add the plugin source from the Nix store to the runtime path
            vim.opt.rtp:prepend("${self}")

            -- Also add current directory (for local development)
            vim.opt.rtp:prepend(".")

            -- Setup image.nvim
            local image_ok, image = pcall(require, "image")
            if image_ok then
              image.setup({
                backend = "kitty",
                processor = "magick_cli",
                max_width_window_percentage = 100,
                max_height_window_percentage = 30,
                window_overlap_clear_enabled = true,
              })
            end



            -- Setup jovian.nvim
            require("jovian").setup({
              -- python_interpreter = "${pythonEnv}/bin/python3",
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
            exec ${neovimWithPlugins}/bin/nvim -u ${initLua} "$@"
          '';

        in
        {
          default = nvim-jovian;
          nvim-jovian = nvim-jovian;
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
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
              pkgs.imagemagick
              pkgs.pyright
              pkgs.ruff
              pythonEnv
            ];

            shellHook = ''
              echo "🪐 Jovian.nvim development environment loaded!"

              if [ ! -f demo_jovian.py ]; then
                echo "Copying demo_jovian.py to current directory..."
                cp ${self}/examples/demo_jovian.py .
                chmod +w demo_jovian.py
              fi

              echo "Run 'nvim-jovian demo_jovian.py' to try the plugin."
            '';
          };
        }
      );
    };
}
