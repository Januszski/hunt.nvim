---@class StoreModule
---@field get_marks fun(): Mark[]
---@field has_marks fun(): boolean
---@field load fun(): boolean
---@field reload fun()
---@field save fun(): boolean
---@field save_async fun(callback?: fun(success: boolean))
---@field get_quickfix_items fun(opts?: QuickfixOpts): QuickfixItem[]
---@field find_by_id fun(mark_id: string): Mark|nil, number|nil
---@field get_mark_at_line fun(filepath: string, line: number): Mark|nil, number|nil
---@field get_sorted_marks_for_file fun(filepath: string): Mark[]
---@field add_mark fun(marks: Mark)
---@field remove_mark fun(mark: Mark): boolean
---@field remove_mark_at_index fun(index: number): Mark|nil
---@field clear_file_marks fun(filepath: string): Mark[]
---@field clear_all_marks fun(): number
---@field get_all_raw fun(): Mark[]
---@field _reset_for_testing fun()

---@type StoreModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@class QuickfixOpts
---@field current_buffer? boolean If true, only include marks from the current buffer
---@field append_annotations? boolean If true, include annotations in quickfix text

---@class QuickfixItem
---@field filename string
---@field lnum integer
---@field col integer
---@field text string

local utils = require("hunt.utils")

---@private
---@type Mark[]
local marks = {}

---@private
---@type table<string, Mark[]>
local marks_by_file = {}

---@private
---@type boolean
local _loaded = false

---@private
---@type PersistenceModule|nil
local persistence = nil

---@private
local function ensure_persistence()
	if not persistence then
		persistence = require("hunt.persistence")
	end
end

--- Add a mark to the file-based index
--- Maintains sorted order by line number using binary search insertion
---@param mark Mark The mark to add to the index
local function add_to_file_index(mark)
	if not marks_by_file[mark.file] then
		marks_by_file[mark.file] = {}
	end

	local file_marks = marks_by_file[mark.file]

	-- Binary search to find insertion point
	local left, right = 1, #file_marks
	local insert_pos = #file_marks + 1

	while left <= right do
		local mid = math.floor((left + right) / 2)
		if file_marks[mid].line_start < mark.line_start then
			left = mid + 1
		else
			insert_pos = mid
			right = mid - 1
		end
	end

	table.insert(file_marks, insert_pos, mark)
end

--- Remove a mark from the file-based index
---@param mark Mark The mark to remove from the index
local function remove_from_file_index(mark)
	local file_marks = marks_by_file[mark.file]
	if not file_marks then
		return
	end

	for i, bm in ipairs(file_marks) do
		if bm.id == mark.id then
			table.remove(file_marks, i)
			-- Clean up empty file entries
			if #file_marks == 0 then
				marks_by_file[mark.file] = nil
			end
			break
		end
	end
end

--- Clear all marks for a specific file from the index
---@param filepath string The file path to clear from the index
local function clear_file_from_index(filepath)
	marks_by_file[filepath] = nil
end

--- Rebuild the entire file-based index from the marks array
--- This is called after loading marks from persistence
local function rebuild_file_index()
	marks_by_file = {}

	for _, mark in ipairs(marks) do
		add_to_file_index(mark)
	end
end

--- Ensure marks have been loaded
--- Triggers deferred loading if not already loaded
local function ensure_loaded()
	if not _loaded then
		M.load()
	end
end

--- Find a mark by its ID
---@param mark_id string The unique ID of the mark to find
---@return Marks|nil mark The mark if found, nil otherwise
---@return number|nil index The index in the marks array, nil if not found
function M.find_by_id(mark_id)
	ensure_loaded()
	for i, bm in ipairs(marks) do
		if bm.id == mark_id then
			return bm, i
		end
	end
	return nil, nil
end

--- Find a mark at a specific line in a file
---@param filepath string Normalized absolute file path
---@param line number 1-based line number
---@return Mark|nil mark The mark at the line, or nil if none exists
---@return number|nil index The index of the mark in the marks table
function M.get_mark_at_line(filepath, line)
	local matches = M.get_marks_at_line(filepath, line)

	if #matches == 0 then
		return nil, nil
	end

	return matches[1]
end

--- Find marks within specific lines in a file
---@param filepath string Normalized absolute file path
---@param line number 1-based line number
---@return Mark[]|nil mark The marks at the line, or nil if none exists
function M.get_marks_at_line(filepath, line)
	ensure_loaded()

	if filepath == "" then
		return {}
	end

	local matches = {}

	for _, mark in ipairs(marks) do
		if mark.file == filepath and line >= mark.line_start and line <= mark.line_end then
			table.insert(matches, mark)
		end
	end

	return matches
end

--- Get sorted marks for a specific file
--- O(1) lookup from file-based index (already sorted)
---@param filepath string The normalized file path
---@return Mark[] marks Sorted array of marks for the file
function M.get_sorted_marks_for_file(filepath)
	ensure_loaded()
	return marks_by_file[filepath] or {}
end

--- Get all marks as a deep copy.
---
--- Returns all marks currently in memory. The returned table is a
--- deep copy, so modifications won't affect the internal state.
---
---@return Mark[] marks Array of all marks
function M.get_marks()
	ensure_loaded()
	return vim.deepcopy(marks)
end

--- Get mark locations as quickfix items.
---
---@param opts? QuickfixOpts Options for filtering and formatting
---@return QuickfixItem[] items Quickfix items
function M.get_quickfix_items(opts)
	ensure_loaded()

	opts = opts or {}

	local append_annotations = opts.append_annotations
	if append_annotations == nil then
		append_annotations = true
	end

	local current_buffer = opts.current_buffer or false

	-- Work on a copy to avoid mutating store order
	local active_marks = {}
	for _, mark in ipairs(marks) do
		table.insert(active_marks, mark)
	end

	if current_buffer then
		local current_file = utils.normalize_filepath(vim.api.nvim_buf_get_name(0))
		if current_file == "" then
			return {}
		end

		local filtered = {}
		for _, mark in ipairs(active_marks) do
			if mark.file == current_file then
				table.insert(filtered, mark)
			end
		end
		active_marks = filtered
	end

	if #active_marks == 0 then
		return {}
	end

	table.sort(active_marks, function(a, b)
		if a.file == b.file then
			return a.line_start < b.line_start
		end
		return a.file < b.file
	end)

	local items = {}
	for _, mark in ipairs(active_marks) do
		local text = string.format("[%s]", mark.kind)

		if mark.severity then
			text = text .. string.format(" (%s)", mark.severity)
		end

		if append_annotations and mark.note and mark.note ~= "" then
			text = text .. " " .. mark.note
		end
		if append_annotations and mark.note and mark.note ~= "" then
			text = mark.note
		end

		table.insert(items, {
			filename = mark.file, -- absolute path works best for quickfix
			lnum = mark.line_start,
			end_lnum = mark.line_end,
			col = 1,
			end_col = 1,
			text = text,
		})
	end

	return items
end

--- Get raw reference to marks array (for internal use only)
--- WARNING: Modifications to returned table affect internal state
---@return Mark[] marks Direct reference to marks array
function M.get_all_raw()
	ensure_loaded()
	return marks
end

--- Check if any marks exist.
---
--- Returns true if there are any marks in memory (after loading from disk).
---
---@return boolean has_marks True if marks exist, false otherwise
function M.has_marks()
	ensure_loaded()
	return #marks > 0
end

--- Load marks from persistent storage.
---
--- This is called automatically when needed. You typically don't need
--- to call this manually unless you want to reload marks from disk.
---
---@return boolean success True if load succeeded
function M.load()
	if _loaded then
		return true
	end

	ensure_persistence()
	---@cast persistence -nil
	local loaded_marks = persistence.load_marks()
	if loaded_marks then
		marks = loaded_marks
		rebuild_file_index()
	end
	_loaded = true

	return true
end

--- Reset state and reload marks from persistent storage.
---
--- Clears all in-memory marks and reloads from disk.
--- Used when changing data_dir to load from a new location.
function M.reload()
	marks = {}
	marks_by_file = {}
	_loaded = false
	M.load()
end

--- Save marks to persistent storage.
---
--- Marks are auto-saved on text changes (debounced) and Neovim exit,
--- but you can call this manually to force a save.
---
---@return boolean success True if save succeeded
function M.save()
	ensure_persistence()
	---@cast persistence -nil
	local success = persistence.save_marks(marks)
	return success
end

--- Save marks to persistent storage asynchronously.
---
--- Used for autosave scenarios where blocking I/O would cause UI lag.
--- Does not block the main thread.
---
---@param callback? fun(success: boolean) Optional callback when save completes
function M.save_async(callback)
	ensure_persistence()
	---@cast persistence -nil
	persistence.save_marks_async(marks, nil, callback)
end

--- Add a mark to the store
---@param mark Mark The mark to add
function M.add_mark(mark)
	ensure_loaded()
	table.insert(marks, mark)
	add_to_file_index(mark)
end

--- Remove a mark from the store
---@param mark Mark The mark to remove
---@return boolean success True if mark was found and removed
function M.remove_mark(mark)
	ensure_loaded()
	for i, bm in ipairs(marks) do
		if bm.id == mark.id then
			table.remove(marks, i)
			remove_from_file_index(mark)
			return true
		end
	end
	return false
end

--- Remove a mark at a specific index
---@param index number The index to remove
---@return Mark|nil mark The removed mark, or nil if index invalid
function M.remove_mark_at_index(index)
	ensure_loaded()
	if index < 1 or index > #marks then
		return nil
	end
	local mark = table.remove(marks, index)
	if mark then
		remove_from_file_index(mark)
	end
	return mark
end

--- Clear all marks for a specific file
---@param filepath string The file path to clear
---@return Mark[] removed Array of removed marks
function M.clear_file_marks(filepath)
	ensure_loaded()
	local removed = {}
	local indices_to_remove = {}

	for i, mark in ipairs(marks) do
		if mark.file == filepath then
			table.insert(removed, mark)
			table.insert(indices_to_remove, i)
		end
	end

	-- Remove in reverse order to avoid index shifting
	for i = #indices_to_remove, 1, -1 do
		table.remove(marks, indices_to_remove[i])
	end

	-- Clear from index
	clear_file_from_index(filepath)

	return removed
end

--- Clear all marks
---@return number count Number of marks that were cleared
function M.clear_all_marks()
	ensure_loaded()
	local count = #marks
	marks = {}
	marks_by_file = {}
	return count
end

--- Reset internal state for testing purposes only
--- WARNING: This will clear ALL marks from memory without persisting
--- Only use in test environments
---@private
function M._reset_for_testing()
	marks = {}
	marks_by_file = {}
	_loaded = true -- Prevent auto-loading from disk
end

return M
