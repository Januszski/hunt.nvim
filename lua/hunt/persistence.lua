---@toc_entry Mark Structure
---@tag hunt-mark
---@tag Mark
---@text
--- # Mark Structure ~
---
--- Marks are stored as tables with the following fields:

--- Mark data structure.
---
--- Represents a single mark in hunt.nvim.
---
---@class Mark
---@field kind string "mark" | "finding" The kind of the marking
---@field tag string|nil String used to tag marked section with a symbol
---@field symbol string|nil Symbol derived from the tag
---@field severity string "info" | "low" | "medium" | "high" | "critial" The kind of the marking
---@field file string Absolute path to the marked file
---@field line_start number 1-based line number of where the marked sections starts
---@field line_end number 1-based line number of where the marked section ends
---@field note string|nil Optional annotation text displayed as virtual text
---@field id string Unique mark identifier (auto-generated)
---@field extmark_id number|nil Extmark ID for line tracking (internal)
---@field annotation_extmark_id number|nil Extmark ID for annotation display (internal)

---@class PersistenceModule
---@field set_data_dir fun(dir: string|nil)
---@field ensure_data_dir fun(): string|nil, string|nil
---@field get_git_info fun(): {root: string|nil, branch: string|nil}
---@field get_storage_path fun(): string|nil, string|nil
---@field save_marks fun(marks: Mark[], filepath?: string): boolean
---@field save_marks_async fun(marks: Mark[], filepath?: string, callback?: fun(success: boolean))
---@field load_marks fun(filepath?: string): Mark[]|nil
---@field create_mark fun(file: string, line: number, note?: string): Mark|nil, string|nil
---@field is_valid_mark fun(mark: table): boolean

---@private
---@type PersistenceModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
---@type string|nil
local custom_data_dir = nil

-- Git info cache with TTL
---@type {root: string|nil, branch: string|nil}|nil
local _git_info_cache = nil
---@type number
local _cache_time = 0
---@type number
local CACHE_TTL = 5000 -- 5 seconds in milliseconds

-- Track if we've already warned about git not being available
---@type boolean
local _git_warning_shown = false

--- Gets the git root directory for the current working directory
---@return string|nil git_root The git repository root path, or nil if not in a git repo
local function get_git_root()
	local result = vim.fn.systemlist("git rev-parse --show-toplevel")
	local exit_code = vim.v.shell_error

	if exit_code == 0 and result[1] then
		return result[1]
	end

	-- Exit code 128 typically means "not a git repository" - this is expected
	-- Exit code 127 means "command not found" - git is not installed
	if exit_code == 127 and not _git_warning_shown then
		_git_warning_shown = true
		vim.notify(
			"hunt.nvim: git command not found. Marks will be stored per working directory instead of per repository/branch.",
			vim.log.levels.DEBUG
		)
	end

	return nil
end

--- Gets the current git branch name or commit hash for detached HEAD
---@return string|nil branch The current git branch name, short commit hash, or nil if not in a git repo
local function get_git_branch()
	local result = vim.fn.systemlist("git branch --show-current")
	local exit_code = vim.v.shell_error

	if exit_code ~= 0 then
		return nil
	end

	local branch = result[1]
	if branch and branch ~= "" then
		return branch
	end

	-- Detached HEAD (e.g., tag checkout): use short commit hash as identifier
	local hash_result = vim.fn.systemlist("git rev-parse --short HEAD")
	if vim.v.shell_error == 0 and hash_result[1] and hash_result[1] ~= "" then
		return hash_result[1]
	end

	return nil
end

--- Set custom data directory
--- Expands ~ to home directory and ensures trailing slash
---@param dir string|nil Custom data directory path, or nil to reset to default
function M.set_data_dir(dir)
	if dir == nil then
		custom_data_dir = nil
		return
	end

	local expanded = vim.fn.expand(dir)

	if expanded:sub(-1) ~= "/" then
		expanded = expanded .. "/"
	end

	custom_data_dir = expanded
end

--- Ensures the hunt data directory exists
---@return string data_dir The hunt data directory path
function M.ensure_data_dir()
	local config = require("hunt.config")
	local data_dir = custom_data_dir or config.DEFAULT_DATA_DIR
	vim.fn.mkdir(data_dir, "p")
	return data_dir
end

--- Get git repository information for the current working directory
--- Uses caching with 5-second TTL to avoid repeated system calls
--- @return { root: string|nil, branch: string|nil }
--- Returns a table with:
---   - root: absolute path to git repository root, or nil if not in a git repo
---   - branch: name of current branch, or nil if not in a git repo, detached HEAD, or no commits
function M.get_git_info()
	local now = vim.uv.hrtime() / 1e6 -- Convert to milliseconds

	-- Check if cache is valid
	if _git_info_cache and (now - _cache_time) < CACHE_TTL then
		return _git_info_cache
	end

	-- Cache miss or expired - fetch fresh data
	local result = {
		root = get_git_root(),
		branch = get_git_branch(),
	}

	-- Update cache
	_git_info_cache = result
	_cache_time = now

	return result
end

--- Generates a storage path for the current git repository and branch
--- Uses a 12-character SHA256 hash of "repo_root|branch" for the filename
--- For detached HEAD states (e.g., tag checkouts), uses the short commit hash as identifier
--- Falls back to CWD and "__default__" branch when not in a git repository
--- When per_branch_marks is false, only uses repo_root for the hash (marks shared across branches)
---@return string path The full path to the storage file
function M.get_storage_path()
	local config = require("hunt.config").get()
	local data_dir = M.ensure_data_dir()
	local git_info = M.get_git_info()
	local repo_root = git_info.root or vim.fn.getcwd()

	-- Skip branch scoping if per_branch_marks is disabled
	if not config.per_branch_marks then
		local hash = vim.fn.sha256(repo_root):sub(1, 12)
		return data_dir .. hash .. ".json"
	end

	local branch = git_info.branch or "__default__"
	local key = repo_root .. "|" .. branch
	local hash = vim.fn.sha256(key):sub(1, 12)

	return data_dir .. hash .. ".json"
end

--- Save marks to JSON file
---@param marks table Array of marks tables to save
---@param filepath? string Optional custom file path (defaults to git-based path)
---@return boolean success True if save was successful, false otherwise
function M.save_marks(marks, filepath)
	-- Validate input
	if type(marks) ~= "table" then
		vim.notify("hunt.nvim: save_marks: marks must be a table", vim.log.levels.ERROR)
		return false
	end

	-- Get storage path
	local storage_path = filepath or M.get_storage_path()
	if not storage_path then
		vim.notify("hunt.nvim: save_marks: could not determine storage path", vim.log.levels.ERROR)
		return false
	end

	-- Ensure storage directory exists
	M.ensure_data_dir()

	-- Create data structure with version
	local data = {
		version = 1,
		marks = marks,
	}

	-- Encode to JSON
	local ok, json_str = pcall(vim.json.encode, data)
	if not ok then
		vim.notify("hunt.nvim: save_marks: JSON encoding failed: " .. tostring(json_str), vim.log.levels.ERROR)
		return false
	end

	-- Write to file
	local write_ok = pcall(vim.fn.writefile, { json_str }, storage_path)
	if not write_ok then
		vim.notify("hunt.nvim: save_marks: failed to write file: " .. storage_path, vim.log.levels.ERROR)
		return false
	end

	return true
end

--- Save marks to JSON file asynchronously using libuv
--- Used for autosave scenarios where blocking I/O would cause UI lag
---@param marks table Array of mark tables to save
---@param filepath? string Optional custom file path (defaults to git-based path)
---@param callback? fun(success: boolean) Optional callback called when write completes
function M.save_marks_async(marks, filepath, callback)
	if type(marks) ~= "table" then
		if callback then
			callback(false)
		end
		return
	end

	local storage_path = filepath or M.get_storage_path()
	if not storage_path then
		if callback then
			callback(false)
		end
		return
	end

	M.ensure_data_dir()

	local data = {
		version = 1,
		marks = marks,
	}

	local ok, json_str = pcall(vim.json.encode, data)
	if not ok then
		if callback then
			callback(false)
		end
		return
	end

	vim.uv.fs_open(storage_path, "w", 438, function(open_err, fd)
		if open_err or not fd then
			vim.schedule(function()
				if callback then
					callback(false)
				end
			end)
			return
		end

		vim.uv.fs_write(fd, json_str, -1, function(write_err, _)
			vim.uv.fs_close(fd, function(close_err)
				local success = not write_err and not close_err
				vim.schedule(function()
					if callback then
						callback(success)
					end
				end)
			end)
		end)
	end)
end

--- Load marks from JSON file
---@param filepath? string Optional custom file path (defaults to git-based path)
---@return table marks Array of marks, or empty table if file doesn't exist or on error
function M.load_marks(filepath)
	-- Get storage path
	local storage_path = filepath or M.get_storage_path()
	if not storage_path then
		vim.notify("hunt.nvim: load_marks: could not determine storage path", vim.log.levels.WARN)
		return {}
	end

	-- Check if file exists
	if vim.fn.filereadable(storage_path) == 0 then
		-- File doesn't exist, return empty table (not an error)
		return {}
	end

	-- Read file
	local ok, lines = pcall(vim.fn.readfile, storage_path)
	if not ok then
		vim.notify("hunt.nvim: load_marks: failed to read file: " .. storage_path, vim.log.levels.ERROR)
		return {}
	end

	-- Join lines into single string
	local json_str = table.concat(lines, "\n")

	-- Decode JSON
	local decode_ok, data = pcall(vim.json.decode, json_str)
	if not decode_ok then
		vim.notify("hunt.nvim: load_marks: JSON decoding failed: " .. tostring(data), vim.log.levels.ERROR)
		return {}
	end

	-- Validate structure
	if type(data) ~= "table" then
		vim.notify("hunt.nvim: load_marks: invalid data structure (not a table)", vim.log.levels.ERROR)
		return {}
	end

	-- Validate version field
	if not data.version then
		vim.notify("hunt.nvim: load_marks: missing version field", vim.log.levels.WARN)
		return {}
	end

	-- Check version compatibility
	if data.version ~= 1 then
		vim.notify("hunt.nvim: load_marks: unsupported version: " .. tostring(data.version), vim.log.levels.ERROR)
		return {}
	end

	-- Validate marks field
	if type(data.marks) ~= "table" then
		vim.notify("hunt.nvim: load_marks: invalid marks field (not a table)", vim.log.levels.ERROR)
		return {}
	end

	return data.marks
end

--- Generate a unique mark ID
--- @param file string Absolute path to the file
--- @param line_start number 1-based line number
--- @param line_end number 1-based line number
--- @return string id A 16-character unique identifier
local function generate_mark_id(file, line_start, line_end)
	local timestamp = tostring(vim.uv.hrtime())
	local id_key = file .. tostring(line_start) .. tostring(line_end) .. timestamp
	return vim.fn.sha256(id_key):sub(1, 16)
end

--- Create a new mark. Does NOT save it!
---@param opts table Mark creation options
---@field file string Absolute file path
---@field line_start number 1-based line number
---@field line_end number 1-based line number
---@field kind? string Mark type ("mark", "finding", etc.)
---@field severity? string Severity level ("info", "low", etc.)
---@field note? string Optional annotation text
---@field symbol_key? string Stable semantic key used for symbol hashing/grouping
---@field symbol? string Display symbol associated with symbol_key
---
---@return Mark|nil mark The created mark table
---@return string|nil error_msg Validation error if creation failed
function M.create_mark(opts)
	-- Validate opts
	if type(opts) ~= "table" then
		vim.notify("hunt.nvim: create_mark: opts must be a table", vim.log.levels.ERROR)
		return nil, "opts must be a table"
	end

	local file = opts.file
	local line_start = opts.line_start
	local line_end = opts.line_end
	local kind = opts.kind or "mark"
	local severity = opts.severity
	local note = opts.note
	local symbol_key = opts.symbol_key
	local symbol = opts.symbol

	-- Validate file
	if type(file) ~= "string" or file == "" then
		vim.notify("hunt.nvim: create_mark: file must be a non-empty string", vim.log.levels.ERROR)
		return nil, "file must be a non-empty string"
	end

	-- Validate line
	if type(line_start) ~= "number" or type(line_end) ~= "number" or line_start < 1 or line_end < 1 then
		vim.notify("hunt.nvim: create_mark: lines must be a positive number", vim.log.levels.ERROR)
		return nil, "lines must be a positive number"
	end

	-- Validate kind
	if type(kind) ~= "string" or kind == "" then
		vim.notify("hunt.nvim: create_mark: kind must be a non-empty string", vim.log.levels.ERROR)
		return nil, "kind must be a non-empty string"
	end

	-- Validate severity
	if type(severity) ~= nil and type(severity) ~= "string" or severity == "" then
		vim.notify("hunt.nvim: create_mark: severity must be a non-empty string", vim.log.levels.ERROR)
		return nil, "severity must be a non-empty string"
	end

	-- Validate note
	if note ~= nil and type(note) ~= "string" then
		vim.notify("hunt.nvim: create_mark: note must be nil or a string", vim.log.levels.ERROR)
		return nil, "note must be nil or a string"
	end

	-- Validate symbol_key
	if symbol_key ~= nil and type(symbol_key) ~= "string" then
		vim.notify("hunt.nvim: create_mark: symbol_key must be nil or a string", vim.log.levels.ERROR)
		return nil, "symbol_key must be nil or a string"
	end

	-- Validate symbol
	if symbol ~= nil and type(symbol) ~= "string" then
		vim.notify("hunt.nvim: create_mark: symbol must be nil or a string", vim.log.levels.ERROR)
		return nil, "symbol must be nil or a string"
	end

	return {
		id = generate_mark_id(file, line_start, line_end),

		-- core location data
		file = file,
		line_start = line_start,
		line_end = line_end,

		-- semantic type
		kind = kind,

		-- optional user annotation
		note = note,

		-- Optional severity
		severity = severity,

		-- optional symbol-group metadata
		symbol_key = symbol_key,
		symbol = symbol,

		-- runtime-only fields
		extmark_id = nil,
		annotation_extmark_id = nil,
	}
end

--- Validate a mark structure
--- @param mark any The value to validate
--- @return boolean valid True if the mark structure is valid
function M.is_valid_mark(mark)
	-- Must be a table
	if type(mark) ~= "table" then
		return false
	end

	-- Required: file
	if type(mark.file) ~= "string" or mark.file == "" then
		return false
	end

	-- Required: line range
	if
		type(mark.line_start) ~= "number"
		or type(mark.line_end) ~= "number"
		or mark.line_start < 1
		or mark.line_end < 1
	then
		return false
	end

	-- Optional sanity check:
	-- end line should not be before start line
	if mark.line_end < mark.line_start then
		return false
	end

	-- Required: id
	if type(mark.id) ~= "string" or mark.id == "" then
		return false
	end

	-- Optional: kind
	if mark.kind ~= nil and (type(mark.kind) ~= "string" or mark.kind == "") then
		return false
	end

	-- Optional: severity
	if mark.severity ~= nil and (type(mark.severity) ~= "string" or mark.severity == "") then
		return false
	end

	-- Optional: note
	if mark.note ~= nil and type(mark.note) ~= "string" then
		return false
	end

	-- Optional: symbol_key
	if mark.symbol_key ~= nil and type(mark.symbol_key) ~= "string" then
		return false
	end

	-- Optional: symbol
	if mark.symbol ~= nil and type(mark.symbol) ~= "string" then
		return false
	end

	-- Runtime-only fields
	if mark.extmark_id ~= nil and type(mark.extmark_id) ~= "number" then
		return false
	end

	if mark.annotation_extmark_id ~= nil and type(mark.annotation_extmark_id) ~= "number" then
		return false
	end

	return true
end
