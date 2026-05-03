---@class DisplayModule
---@field get_namespace fun(): number
---@field setup_signs fun(opts: table)
---@field get_config fun(): table
---@field is_initialized fun(): boolean
---@field show_annotation fun(bufnr: number, line: number, note: string): number|nil
---@field hide_annotation fun(bufnr: number, extmark_id: number): boolean
---@field set_mark fun(bufnr: number, mark: Mark): number|nil
---@field get_extmark_line fun(bufnr: number, extmark_id: number): number|nil
---@field delete_mark fun(bufnr: number, extmark_id: number)
---@field clear_buffer_marks fun(bufnr: number)
---@field clear_buffer_signs fun(bufnr: number): boolean
---@field place_sign fun(bufnr: number, line: number, sign_id: number)
---@field unplace_sign fun(bufnr: number, sign_id: number)

---@type DisplayModule
---@diagnostic disable-next-line: missing-fields
local M = {}

-- Lazy namespace creation (create on first use, not at module load)
---@type number|nil
local _namespace = nil

-- Track if highlight groups have been defined
---@type boolean
local _highlights_defined = false

--- Check if a buffer number is valid
---@param bufnr any The value to check
---@return boolean is_valid True if bufnr is a valid buffer number
local function is_valid_buffer(bufnr)
	return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr)
end

--- Define custom highlight groups for hunt
--- Creates HuntAnnotation highlight group with sensible defaults
--- Users can override this by defining the highlight group themselves
local function define_highlights()
	local highlights = {
		HuntAnnotation = {
			link = "DiagnosticVirtualTextHint",
		},

		-- SIGN HIGHLIGHTS
		HuntBookmarkSign = {
			link = "DiagnosticHint",
		},

		HuntFindingInfoSign = {
			fg = "#cc9666",
		},

		HuntFindingLowSign = {
			fg = "#cc6666",
		},

		HuntFindingMediumSign = {
			fg = "#ff4444",
		},

		HuntFindingHighSign = {
			fg = "#ff2222",
			bold = true,
		},

		HuntFindingCriticalSign = {
			fg = "#5c0000",
			bold = true,
		},

		HuntBookmarkRange = {
			link = "Visual",
		},

		HuntFindingInfoRange = {
			bg = "#cc9666",
		},

		HuntFindingLowRange = {
			bg = "#cc6666",
		},

		HuntFindingMediumRange = {
			bg = "#ff4444",
		},

		HuntFindingHighRange = {
			bg = "#ff2222",
		},

		HuntFindingCriticalRange = {
			bg = "#5c0000",
			bold = true,
		},
	}

	for group, opts in pairs(highlights) do
		local existing = vim.api.nvim_get_hl(0, { name = group })

		-- Only define if user/theme hasn't already defined it
		if vim.tbl_isempty(existing) then
			vim.api.nvim_set_hl(0, group, opts)
		end
	end
end

local function get_range_hl(mark)
	if mark.kind == "finding" then
		local severity = mark.severity or "medium"

		if severity == "info" then
			return "HuntFindingInfoRange"
		end

		if severity == "low" then
			return "HuntFindingLowRange"
		end

		if severity == "high" then
			return "HuntFindingHighRange"
		end

		if severity == "critical" then
			return "HuntFindingCriticalRange"
		end

		return "HuntFindingMediumRange"
	end

	-- default non-finding marks
	return "HuntBookmarkRange"
end

local function ensure_highlights_defined()
	if _highlights_defined then
		return
	end
	_highlights_defined = true

	define_highlights()

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("hunt_highlights", { clear = true }),
		callback = define_highlights,
		desc = "Re-apply HuntAnnotation highlight after colorscheme change",
	})
end

--- Get or create the namespace for hunt extmarks
---@return number namespace The namespace ID
function M.get_namespace()
	if not _namespace then
		_namespace = vim.api.nvim_create_namespace("hunt")
	end
	return _namespace
end

local config = require("hunt.config")

-- Track if signs have been defined
---@type boolean
local _signs_defined = false

--- Ensure signs are defined (lazy definition)
--- Only defines signs once when first needed
local function ensure_signs_defined()
	if _signs_defined then
		return
	end

	_signs_defined = true

	-- Generic marks / bookmarks
	vim.fn.sign_define("HuntMarkBookmark", {
		text = "󰃀",
		texthl = "HuntBookmarkSign",
	})

	-- Findings
	vim.fn.sign_define("HuntMarkFindingInfo", {
		text = "🐭",
		texthl = "HuntFindingInfoSign",
	})

	vim.fn.sign_define("HuntMarkFindingLow", {
		text = "🐰",
		texthl = "HuntFindingLowSign",
	})

	vim.fn.sign_define("HuntMarkFindingMedium", {
		text = "🦌",
		texthl = "HuntFindingMediumSign",
	})

	vim.fn.sign_define("HuntMarkFindingHigh", {
		text = "🦬",
		texthl = "HuntFindingHighSign",
	})

	vim.fn.sign_define("HuntMarkFindingCritical", {
		text = "🦅",
		texthl = "HuntFindingCriticalSign",
	})
end

--- Setup mark signs with vim.fn.sign_define()
--- Creates a "HuntMark" sign that can be reused for all marks
--- Lightweight - stores config via config module, doesn't define signs yet
---@param opts? HuntConfig Optional configuration table
---@return nil
function M.setup_signs(opts)
	-- Config is already set up by init.lua, this is just for compatibility
	-- The config module handles merging with defaults
	if opts and not config.is_setup() then
		config.setup(opts)
	end
	-- Don't call sign_define here - it will be called lazily when first needed
end

--- Get the current display configuration
---@return HuntConfig config The current display configuration
function M.get_config()
	return config.get()
end

--- Check if config has been initialized
---@return boolean initialized True if setup has been called
function M.is_initialized()
	return config.is_setup()
end

--- Show annotation as virtual text at the end of a line
---@param bufnr number Buffer number
---@param line number 1-based line number
---@param note string The annotation text to display
---@return number|nil extmark_id The ID of the created extmark, or nil if validation fails
function M.show_annotation(bufnr, line, note)
	ensure_highlights_defined()

	if not is_valid_buffer(bufnr) then
		vim.notify("hunt.nvim: show_annotation: invalid buffer", vim.log.levels.WARN)
		return nil
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if line < 1 or line > line_count then
		vim.notify(
			string.format("hunt.nvim: Cannot show annotation at line %d (buffer has %d lines)", line, line_count),
			vim.log.levels.WARN
		)
		return nil
	end

	local cfg = config.get()
	-- some guards
	local hl_group = cfg.virt_text_hl or "HuntAnnotation"
	local prefix = cfg.annotation_prefix or "  "
	local suffix = cfg.annotation_suffix or ""
	local virt_text_pos = cfg.virt_text_pos or "eol"

	-- nvim_buf_set_extmark uses 0-based line numbers
	local extmark_id = vim.api.nvim_buf_set_extmark(bufnr, M.get_namespace(), line - 1, 0, {
		virt_text = { { prefix .. note .. suffix, hl_group } },
		virt_text_pos = virt_text_pos,
	})

	return extmark_id
end

--- Hide annotation by removing the extmark
---@param bufnr number Buffer number
---@param extmark_id number The extmark ID to remove
---@return boolean success True if hiding was successful, false otherwise
function M.hide_annotation(bufnr, extmark_id)
	if not is_valid_buffer(bufnr) then
		return false
	end

	-- Try to delete extmark (may fail if extmark doesn't exist, which is OK)
	local ok = pcall(vim.api.nvim_buf_del_extmark, bufnr, M.get_namespace(), extmark_id)
	return ok
end

--- Set a mark extmark for line tracking
--- Creates an extmark at the mark's line that will automatically move with text edits
--- This extmark is separate from the annotation extmark and is used purely for line tracking
---@param bufnr number Buffer number where the mark is located
---@param mark Mark The mark data structure
---@return number|nil extmark_id The created extmark ID, or nil if creation failed
function M.set_mark(bufnr, mark)
	-- Validate inputs
	if not is_valid_buffer(bufnr) then
		vim.notify("hunt.nvim: set_mark: invalid buffer number", vim.log.levels.ERROR)
		return nil
	end

	if type(mark) ~= "table" or type(mark.line_start) ~= "number" then
		vim.notify("hunt.nvim: set_mark: invalid mark structure", vim.log.levels.ERROR)
		return nil
	end

	-- Convert from 1-based to 0-based indexing for nvim_buf_set_extmark
	local line = mark.line_start - 1

	-- Check if line is within buffer bounds
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if line < 0 or line >= line_count then
		vim.notify(
			string.format("hunt.nvim: set_mark: line %d out of bounds (buffer has %d lines)", mark.line_start, line_count),
			vim.log.levels.ERROR
		)
		return nil
	end

	local start_row = mark.line_start - 1
	local end_row = mark.line_end - 1

	-- Create extmark with right_gravity=false so it stays at the beginning of the line
	-- even when text is inserted at the start of the line
	local hl_group = get_range_hl(mark)

	local ok, extmark_id = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.get_namespace(), start_row, 0, {
		end_row = end_row,
		end_col = vim.v.maxcol,
		right_gravity = false,
		hl_group = hl_group,
		hl_mode = "combine",
	})

	if not ok then
		vim.notify(
			string.format("hunt.nvim: set_mark: failed to create extmark: %s", tostring(extmark_id)),
			vim.log.levels.ERROR
		)
		return nil
	end

	return extmark_id
end

--- Get the current line number for an extmark
--- Queries the extmark position to find where it has moved to
--- This allows marks to stay synced with the buffer as text is edited
---@param bufnr number Buffer number where the extmark is located
---@param extmark_id number The extmark ID to query
---@return number|nil line The current 1-based line number, or nil if extmark not found
function M.get_extmark_line(bufnr, extmark_id)
	-- Validate inputs
	if not is_valid_buffer(bufnr) then
		vim.notify("hunt.nvim: get_extmark_line: invalid buffer number", vim.log.levels.ERROR)
		return nil
	end

	if type(extmark_id) ~= "number" then
		vim.notify("hunt.nvim: get_extmark_line: invalid extmark ID", vim.log.levels.ERROR)
		return nil
	end

	-- Query extmark position
	local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, M.get_namespace(), extmark_id, {})

	if not ok then
		-- Extmark not found or other error
		return nil
	end

	-- pos is a tuple {row, col} where row is 0-indexed
	-- Convert to 1-based line number
	if type(pos) == "table" and type(pos[1]) == "number" then
		return pos[1] + 1
	end

	return nil
end

--- Delete a mark extmark
--- Removes the extmark from the buffer when a mark is deleted
---@param bufnr number Buffer number where the extmark is located
---@param extmark_id number The extmark ID to delete
---@return boolean success True if deletion was successful, false otherwise
function M.delete_mark(bufnr, extmark_id)
	-- Validate inputs
	if not is_valid_buffer(bufnr) then
		vim.notify("hunt.nvim: delete_mark: invalid buffer number", vim.log.levels.ERROR)
		return false
	end

	if type(extmark_id) ~= "number" then
		vim.notify("hunt.nvim: delete_mark: invalid extmark ID", vim.log.levels.ERROR)
		return false
	end

	-- Delete the extmark
	local ok = pcall(vim.api.nvim_buf_del_extmark, bufnr, M.get_namespace(), extmark_id)

	if not ok then
		vim.notify(string.format("hunt.nvim: delete_mark: failed to delete extmark %d", extmark_id), vim.log.levels.WARN)
		return false
	end

	return true
end

--- Clear all mark extmarks from a buffer
--- Useful when reloading marks or clearing all marks
---@param bufnr number Buffer number to clear extmarks from
---@return boolean success True if clearing was successful, false otherwise
function M.clear_buffer_marks(bufnr)
	-- Validate input
	if not is_valid_buffer(bufnr) then
		vim.notify("hunt.nvim: clear_buffer_marks: invalid buffer number", vim.log.levels.ERROR)
		return false
	end

	-- Clear all extmarks in the namespace for this buffer
	local ok = pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.get_namespace(), 0, -1)

	if not ok then
		vim.notify("hunt.nvim: clear_buffer_marks: failed to clear extmarks", vim.log.levels.ERROR)
		return false
	end

	return true
end

-- Sign group name for organizing hunt signs
local SIGN_GROUP = "hunt_signs"

local function get_sign_name(mark)
	if mark.kind == "finding" then
		local severity = mark.severity or "medium"

		if severity == "info" then
			return "HuntMarkFindingInfo"
		end

		if severity == "low" then
			return "HuntMarkFindingLow"
		end

		if severity == "high" then
			return "HuntMarkFindingHigh"
		end

		if severity == "critical" then
			return "HuntMarkFindingCritical"
		end

		return "HuntMarkFindingMedium"
	end

	return "HuntMarkBookmark"
end

--- Place a sign at a specific line in a buffer
---@param bufnr number Buffer number
---@param mark Mark
---@param sign_id number Unique sign ID
function M.place_sign(bufnr, mark, sign_id)
	ensure_signs_defined()

	local sign_name = get_sign_name(mark)

	vim.fn.sign_place(sign_id, SIGN_GROUP, sign_name, bufnr, {
		lnum = mark.line_start,
		priority = 10,
	})
end

--- Remove a sign from a buffer
---@param bufnr number Buffer number
---@param sign_id number Sign ID to remove
function M.unplace_sign(bufnr, sign_id)
	vim.fn.sign_unplace(SIGN_GROUP, {
		buffer = bufnr,
		id = sign_id,
	})
end

--- Clear all hunt signs from a buffer
---@param bufnr number Buffer number to clear signs from
---@return boolean success True if clearing was successful
function M.clear_buffer_signs(bufnr)
	if not is_valid_buffer(bufnr) then
		return false
	end

	vim.fn.sign_unplace(SIGN_GROUP, { buffer = bufnr })
	return true
end

return M
