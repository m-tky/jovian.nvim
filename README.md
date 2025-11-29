# Jovian.nvim

A Neovim plugin for interactive Python programming, providing a Jupyter Notebook-like experience within Neovim. It allows executing code cells, inspecting variables, and visualizing data directly in the editor.

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "m-tky/jovian.nvim",
    config = function()
        require("jovian").setup({
            -- Configuration options (see below)
        })
    end
}
```

## Configuration

The following table shows the default configuration options. You can override these by passing a table to the `setup` function.

```lua
require("jovian").setup({
    -- UI Settings
    preview_width_percent = 35,
    repl_height_percent = 30,

    -- Visuals
    flash_highlight_group = "Visual",
    flash_duration = 300,
    float_border = "rounded", -- Options: "single", "double", "rounded", "solid", "shadow", "none"

    -- Python Environment
    python_interpreter = "python3",

    -- SSH Remote Settings (Optional)
    ssh_host = nil, -- Example: "user@192.168.1.10"
    ssh_python = "python3", -- Remote Python command

    -- Behavior
    notify_threshold = 10,
})
```

### `float_border`

Controls the border style of floating windows (Variable List, Peek, Doc, etc.).

- **Default:** `"rounded"`
- **Values:** `"single"`, `"double"`, `"rounded"`, `"solid"`, `"shadow"`, `"none"` (or any valid `nvim_open_win` border style).

## Commands

| Command                    | Description                                                             |
| :------------------------- | :---------------------------------------------------------------------- |
| **Execution**              |                                                                         |
| `JovianStart`              | Starts the Python kernel.                                               |
| `JovianRun`                | Executes the current cell.                                              |
| `JovianSendSelection`      | Executes the selected text (Visual mode).                               |
| `JovianRunAll`             | Executes all cells in the buffer.                                       |
| `JovianRunAndNext`         | Executes the current cell and moves to the next one.                    |
| `JovianRunLine`            | Executes the current line.                                              |
| `JovianRestart`            | Restarts the Python kernel.                                             |
| `JovianInterrupt`          | Interrupts the currently running execution.                             |
| **UI & Windows**           |                                                                         |
| `JovianOpen`               | Opens the REPL and Preview windows.                                     |
| `JovianToggle`             | Toggles the visibility of the REPL and Preview windows.                 |
| `JovianClear`              | Clears the REPL buffer.                                                 |
| `JovianClearDiag`          | Clears Jovian diagnostics from the buffer.                              |
| **Data & Inspection**      |                                                                         |
| `JovianVars`               | Shows a list of defined variables in a floating window.                 |
| `JovianView [name]`        | Displays a pandas DataFrame or similar object in a floating window.     |
| `JovianPeek [name]`        | Shows a quick peek of a variable's value and type.                      |
| `JovianDoc [name]`         | Shows documentation/inspection info for an object.                      |
| `JovianCopy [name]`        | Copies the string representation of a variable to the system clipboard. |
| `JovianProfile`            | Runs `cProfile` on the current cell and shows stats.                    |
| **Navigation & Editing**   |                                                                         |
| `JovianNextCell`           | Jumps to the next cell header.                                          |
| `JovianPrevCell`           | Jumps to the previous cell header.                                      |
| `JovianNewCellBelow`       | Inserts a new cell below the current one.                               |
| `JovianNewCellAbove`       | Inserts a new cell above the current one.                               |
| `JovianDeleteCell`         | Deletes the current cell.                                               |
| `JovianSplitCell`          | Splits the current cell at the cursor position.                         |
| `JovianMergeBelow`         | Merges the current cell with the one below it.                          |
| `JovianMoveCellUp`         | Moves the current cell up.                                              |
| `JovianMoveCellDown`       | Moves the current cell down.                                            |
| **Session**                |                                                                         |
| `JovianSaveSession [file]` | Saves the current kernel session (variables) to a file.                 |
| `JovianLoadSession [file]` | Loads a kernel session from a file.                                     |
| **Maintenance**            |                                                                         |
| `JovianClean`              | Cleans up stale cache files for the current buffer.                     |

## Keymaps

Jovian does not set default keymaps to avoid conflicts. You can define your own in your Neovim configuration. Example:

```lua
vim.keymap.set("n", "<leader>jr", "<cmd>JovianRun<CR>", { desc = "Run Cell" })
vim.keymap.set("n", "<leader>ji", "<cmd>JovianInterrupt<CR>", { desc = "Interrupt Kernel" })
vim.keymap.set("n", "<leader>jv", "<cmd>JovianVars<CR>", { desc = "Variables" })
-- Add more as needed
```
