local M = {}
local Cell = require("jovian.cell")

-- Re-export Cell functions for backward compatibility
M.generate_id = Cell.generate_id
M.get_all_ids = Cell.get_all_ids
M.fix_duplicate_ids = Cell.fix_duplicate_ids
M.get_cell_range = Cell.get_cell_range
M.ensure_cell_id = Cell.ensure_cell_id
M.get_current_cell_id = Cell.get_current_cell_id
M.delete_cell = Cell.delete_cell
M.move_cell_up = Cell.move_cell_up
M.move_cell_down = Cell.move_cell_down
M.split_cell = Cell.split_cell
M.get_cell_hash = Cell.get_cell_hash
M.get_cell_md_path = Cell.get_cell_md_path

return M
