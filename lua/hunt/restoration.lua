---@class RestorationModule
---@field restore_buffer_marks fun(bufnr: number, annotations_visible: boolean): boolean
---@field cleanup_buffer_tracking fun(bufnr: number)
---@field reset_tracking fun()

---@type RestorationModule
---@diagnostic disable-next-line: missing-fields
local M = {}

local utils = require("hunt.utils")

---@private
---@type table<number, boolean>
local restored_buffers = {}

---@private
---@type StoreModule|nil
local store = nil
---@private
---@type DisplayModule|nil
local display = nil

---@private
local function ensure_modules()
	if not store then
		store = require("hunt.store")
	end
	if not display then
		display = require("hunt.display")
	end
end

--- Restore visual elements (extmarks, signs, annotations) for a mark in a loaded buffer
--- This is called when loading marks to recreate visual state
---@param bufnr number Buffer number
---@param mark Mark The mark to restore
---@param annotations_visible boolean Whether annotations should be displayed
local function restore_mark_display(bufnr, mark, annotations_visible)
	ensure_modules()
	---@cast display -nil

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- Clean up old extmark if it exists to prevent orphaning
	if mark.extmark_id then
		display.delete_mark(bufnr, mark.extmark_id)
		display.unplace_sign(bufnr, mark.extmark_id)
	end

	-- Clean up old annotation extmark if it exists
	if mark.annotation_extmark_id then
		display.hide_annotation(bufnr, mark.annotation_extmark_id)
	end

	-- Create extmark for line tracking
	local extmark_id = display.set_mark(bufnr, mark)
	if not extmark_id then
		return
	end

	mark.extmark_id = extmark_id

	-- Place sign
	display.place_sign(bufnr, mark.line_start, extmark_id)

	-- Show annotation if it exists and global visibility is enabled
	if mark.note and annotations_visible then
		local annotation_extmark_id = display.show_annotation(bufnr, mark.line_start, mark.note)
		mark.annotation_extmark_id = annotation_extmark_id
	end
end

--- Restore mark visuals for a specific buffer.
---
--- This is called automatically when buffers are opened. You typically
--- don't need to call this manually.
---
---@param bufnr number Buffer number to restore marks for
---@param annotations_visible boolean Whether annotations should be displayed
---@return boolean success True if restoration succeeded or was skipped
function M.restore_buffer_marks(bufnr, annotations_visible)
	ensure_modules()
	---@cast store -nil
	---@cast display -nil

	require("hunt")._ensure_initialized()

	local valid, _ = utils.validate_buffer_for_marks(bufnr)
	if not valid then
		return true
	end

	-- Guard against race condition: check if buffer already restored
	if restored_buffers[bufnr] then
		return true
	end

	-- Mark buffer as restored before doing work to prevent concurrent restoration
	restored_buffers[bufnr] = true

	-- Additional safety check: verify no extmarks exist (shouldn't happen with guard above)
	local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, display.get_namespace(), 0, -1, { limit = 1 })

	-- already restored
	if #extmarks > 0 then
		return true
	end

	local filepath = utils.normalize_filepath(vim.api.nvim_buf_get_name(bufnr))
	if filepath == "" then
		return true
	end

	-- Find all marks for this file
	local all_marks = store.get_all_raw()
	local buffer_marks = {}
	for _, mark in ipairs(all_marks) do
		if mark.file == filepath then
			table.insert(buffer_marks, mark)
		end
	end

	-- early return for no marks
	if #buffer_marks == 0 then
		return true
	end

	-- Restore visual elements for each mark
	local success = true
	for _, mark in ipairs(buffer_marks) do
		-- Use pcall to handle race conditions where buffer becomes invalid
		local ok, err = pcall(restore_mark_display, bufnr, mark, annotations_visible)
		if ok then
			goto continue
		end

		-- Log at DEBUG level - this is expected in race conditions
		vim.notify(
			string.format("hunt.nvim: Failed to restore mark in %s: %s", mark.file, tostring(err)),
			vim.log.levels.DEBUG
		)
		success = false

		::continue::
	end

	return success
end

--- Clean up restoration tracking for a deleted buffer
--- This prevents memory leaks in the restored_buffers table
---@param bufnr number Buffer number that was deleted
function M.cleanup_buffer_tracking(bufnr)
	restored_buffers[bufnr] = nil
end

--- Reset all restoration tracking
--- Used when changing data_dir to allow buffers to be re-restored
function M.reset_tracking()
	restored_buffers = {}
end

return M
