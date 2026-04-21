local M = {}
local Config = require("jovian.config")
local State = require("jovian.state")

local ns = vim.api.nvim_create_namespace("jovian_inline_images")

function M.clear_for_buffer(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	if State.inline_images[bufnr] and State.inline_images[bufnr].images then
		for _, img in ipairs(State.inline_images[bufnr].images) do
			pcall(function()
				img:clear()
			end)
		end
		State.inline_images[bufnr].images = {}
	end
end

-- Decode base64 and ensure image is persisted to cached path
local function decode_and_save(b64, img_path)
	if vim.fn.filereadable(img_path) == 1 then
		return true
	end

    -- Strip bad whitespace from base64 string mapping issues on multiple lines
    b64 = b64:gsub("%s+", "")
    
    -- Fix incorrect padding
    local pad = #b64 % 4
    if pad > 0 then
        b64 = b64 .. string.rep("=", 4 - pad)
    end

	-- Neovim 0.10+ native base64 decoding
	if vim.base64 and vim.base64.decode then
		local ok, decoded = pcall(vim.base64.decode, b64)
		if ok and decoded then
			local f = io.open(img_path, "wb")
			if f then
				f:write(decoded)
				f:close()
                if vim.fn.getfsize(img_path) > 0 then return true end
			end
		end
	end

	-- Fallback to Python Base64 Decoding
	local write_script = string.format("import base64, sys; open('%s', 'wb').write(base64.b64decode(sys.stdin.read()))", img_path)
	vim.fn.system({ Config.options.python_interpreter, "-c", write_script }, b64)
    if vim.fn.getfsize(img_path) > 0 then return true end
    
	return false
end

function M.render_for_buffer(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then return end
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	
	local ok, image_api = pcall(require, "image")
	if not ok then return end

	State.inline_images[bufnr] = State.inline_images[bufnr] or { images = {}, mtime = 0, hidden_b64 = {} }
	local cache = State.inline_images[bufnr]

    local base64_placeholder = "_HIDDEN_IMAGE_DATAURI_"
    
	local function scan_buffer_for_images(attachments_dict)
		M.clear_for_buffer(bufnr)
        M.restore_buffer_for_save(bufnr)

		local base_filename = vim.fn.fnamemodify(filepath, ":t")
		if base_filename == "" then base_filename = "scratchpad" end
		local file_dir = vim.fn.fnamemodify(filepath, ":p:h")
		local cache_dir = file_dir .. "/.jovian_cache/" .. base_filename .. "/attachments"
		vim.fn.mkdir(cache_dir, "p")

		if attachments_dict then
			local cached_files = vim.fn.readdir(cache_dir)
			for _, cached_f in ipairs(cached_files) do
				if not cached_f:match("^datauri_") and not attachments_dict[cached_f] then
					vim.fn.delete(cache_dir .. "/" .. cached_f)
				end
			end
		end

		if not vim.api.nvim_buf_is_valid(bufnr) then return end
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

		local in_data_uri = false
		local data_uri_b64 = ""
		local data_uri_line = 0
		local data_uri_prefix = ""
        local line_offset = 0
        local images_to_render = {}

		for i, line in ipairs(lines) do
			local rendered = false

			if attachments_dict then
				local attach_name = line:match("!%[.-%]%(attachment:([^%)]+)%)")
				if not attach_name then attach_name = line:match('src=["\']attachment:([^"\']+)["\']') end

				if attach_name then
					local safe_name = attach_name:gsub("%.%.", ""):gsub("/", "_")
					if attachments_dict[safe_name] then
						local img_path = cache_dir .. "/" .. safe_name
						decode_and_save(attachments_dict[safe_name], img_path)

						local win_id = vim.fn.win_findbuf(bufnr)[1]
						if win_id then
                            local target_y = math.min(i - 1 - line_offset + 1, vim.api.nvim_buf_line_count(bufnr) - 1)
							local img = image_api.from_file(img_path, { window = win_id, buffer = bufnr, y = target_y, with_virtual_padding = true })
							if img then 
                                table.insert(images_to_render, img)
                                table.insert(cache.images, img)
                                rendered = true 
                            end
						end
					end
				end
			end

			if not rendered then
				-- Jupytext multiline extraction logic
				if in_data_uri then
					local b64_part = line:match("^#?%s*(.*)")
					if not b64_part then b64_part = line end
					
					local end_idx = b64_part:find("[%)\"']")
					if end_idx then
						data_uri_b64 = data_uri_b64 .. b64_part:sub(1, end_idx - 1)
						in_data_uri = false

						-- Stitched base64 string completely decoded
						local safe_name = "datauri_" .. vim.fn.sha256(data_uri_b64):sub(1, 12) .. ".png"
						local img_path = cache_dir .. "/" .. safe_name
						decode_and_save(data_uri_b64, img_path)

						-- Delete massive multiline blocks and substitute them with a hidden physical placeholder
                        -- This prevents neovim wrapping artifacts on long strings.
						local was_mod = vim.api.nvim_buf_get_option(bufnr, "modified")
                        
                        -- Store the real original lines safely in State so we can restore them on save!
                        table.insert(cache.hidden_b64, {
                            start_l = data_uri_line - line_offset,
                            end_l = i - 1 - line_offset,
                            lines = vim.api.nvim_buf_get_lines(bufnr, data_uri_line - line_offset, i - line_offset, false)
                        })
                        
						local single_line = data_uri_prefix .. base64_placeholder .. ")"
						vim.api.nvim_buf_set_lines(bufnr, data_uri_line - line_offset, i - line_offset, false, { single_line })
                        
                        -- Update the global line offset so downstream images use corrected buffer indices
                        local removed_lines = (i - data_uri_line) - 1
                        line_offset = line_offset + removed_lines
						
						-- Re-conceal the freshly injected placeholder text so no garbage remains
						local c_start, c_end = single_line:find(base64_placeholder, 1, true)
						if c_start and c_end then
							pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, data_uri_line - line_offset, c_start - 1, {
								end_col = c_end,
								conceal = "",
							})
						end

						if not was_mod then
							vim.api.nvim_buf_set_option(bufnr, "modified", false)
						end

						local win_id = vim.fn.win_findbuf(bufnr)[1]
						if win_id then
                            local target_y = math.min(data_uri_line - line_offset + 1, vim.api.nvim_buf_line_count(bufnr) - 1)
							local img = image_api.from_file(img_path, { window = win_id, buffer = bufnr, y = target_y, with_virtual_padding = true })
							if img then
                                table.insert(images_to_render, img)
                                table.insert(cache.images, img)
                            end
						end
					else
						data_uri_b64 = data_uri_b64 .. b64_part
					end
				else
					local start_b64 = line:match("data:image/[%w%+%-]+;base64,([^%)\"']*)")
					if start_b64 then
						local full_match, b64_single = line:match("(data:image/[%w%+%-]+;base64,([^%)\"']*)[%)\"'])")
						if full_match then
							local safe_name = "datauri_" .. vim.fn.sha256(b64_single):sub(1, 12) .. ".png"
							local img_path = cache_dir .. "/" .. safe_name
							decode_and_save(b64_single, img_path)

                            local was_mod = vim.api.nvim_buf_get_option(bufnr, "modified")
                            table.insert(cache.hidden_b64, {
                                start_l = i - 1 - line_offset,
                                end_l = i - 1 - line_offset,
                                lines = { line }
                            })

                            local sub_line = line:gsub("data:image/[%w%+%-]+;base64,[^%)\"']*", base64_placeholder)
                            vim.api.nvim_buf_set_lines(bufnr, i - 1 - line_offset, i - line_offset, false, { sub_line })

                            if not was_mod then
                                vim.api.nvim_buf_set_option(bufnr, "modified", false)
                            end

							local win_id = vim.fn.win_findbuf(bufnr)[1]
							if win_id then
                                local target_y = math.min(i - 1 - line_offset + 1, vim.api.nvim_buf_line_count(bufnr) - 1)
								local img = image_api.from_file(img_path, { window = win_id, buffer = bufnr, y = target_y, with_virtual_padding = true })

								-- Conceal the substituted portion so it doesn't blast the user's screen
								local c_start, c_end = sub_line:find(base64_placeholder, 1, true)
								if c_start and c_end then
									pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, i - 1 - line_offset, c_start - 1, {
										end_col = c_end,
										conceal = "",
									})
								end

								if img then
                                    table.insert(images_to_render, img)
                                    table.insert(cache.images, img)
                                end
							end
						else
							in_data_uri = true
							data_uri_b64 = start_b64
							data_uri_line = i - 1
							local prefix_idx = line:find(start_b64, 1, true)
							data_uri_prefix = prefix_idx and line:sub(1, prefix_idx - 1) or ""
							
							-- Conceal partial starting line
							local c_start = line:find("data:image/[%w%+%-]+;base64,")
							if c_start then
								pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, i - 1 - line_offset, c_start - 1, {
									end_col = #line,
									conceal = "",
								})
							end
						end
					end
				end
			end
		end

        -- Execute UI redraw so modified buffer states visually propagate before screen coordinate polling
        vim.cmd("redraw")
        for _, img in ipairs(images_to_render) do
            img:render()
        end
	end

	if filepath:match("%.ipynb$") then
		vim.loop.fs_stat(filepath, function(err, stat)
			if err or not stat then
				vim.schedule(function() scan_buffer_for_images(nil) end)
				return
			end
			vim.schedule(function()
				if stat.mtime.sec <= cache.mtime and #cache.images > 0 then return end
				vim.loop.fs_open(filepath, "r", 438, function(open_err, fd)
					if open_err or not fd then return end
					vim.loop.fs_fstat(fd, function(stat_err, fstat)
						if stat_err or not fstat then vim.loop.fs_close(fd); return end
						vim.loop.fs_read(fd, fstat.size, 0, function(read_err, data)
							vim.loop.fs_close(fd)
							if read_err or not data then return end
							vim.schedule(function()
								local decode_ok, decoded = pcall(vim.json.decode, data)
								if not decode_ok or type(decoded) ~= "table" or not decoded.cells then
									scan_buffer_for_images(nil)
									return
								end

								local attachments = {}
								for _, cell in ipairs(decoded.cells) do
									if cell.attachments then
										for name, att_data in pairs(cell.attachments) do
											local safe_name = name:gsub("%.%.", ""):gsub("/", "_")
											for _, b64 in pairs(att_data) do
												if #(b64) < 7000000 then attachments[safe_name] = b64 end
												break
											end
										end
									end
								end
								
								cache.mtime = stat.mtime.sec
								scan_buffer_for_images(attachments)
							end)
						end)
					end)
				end)
			end)
		end)
	else
		scan_buffer_for_images(nil)
	end

	-- Enforce conceallevel so our hidden base64 extmarks actually disappear
	vim.schedule(function()
		local wins = vim.fn.win_findbuf(bufnr)
		for _, win in ipairs(wins) do
			if vim.api.nvim_win_is_valid(win) then
				if vim.wo[win].conceallevel < 2 then
					vim.wo[win].conceallevel = 2
				end
				-- Prevent the cursor from expanding the massive base64 text when placed on it
				vim.wo[win].concealcursor = "nvic"
			end
		end
	end)
end

function M.restore_buffer_for_save(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    
    local cache = State.inline_images[bufnr]
    if not cache or not cache.hidden_b64 or #cache.hidden_b64 == 0 then
        return
    end

    local was_mod = vim.api.nvim_buf_get_option(bufnr, "modified")

    -- We must restore them in reverse order to ensure line indices don't shift!
    for i = #cache.hidden_b64, 1, -1 do
        local block = cache.hidden_b64[i]
        vim.api.nvim_buf_set_lines(bufnr, block.start_l, block.start_l + 1, false, block.lines)
    end
    
    if not was_mod then
        vim.api.nvim_buf_set_option(bufnr, "modified", false)
    end

    -- Clear state, it will be lazily repopulated on cache rebuild via BufWritePost
    cache.hidden_b64 = {}
end

return M
