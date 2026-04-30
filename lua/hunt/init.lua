-- ===========================================================================
-- hunt.nvim - Bookmark management for Neovim
--
-- MIT License. See LICENSE file for details.
-- ===========================================================================

---@tag hunt.nvim
---@tag hunt
---@toc_entry Introduction
---@toc

---@text
--- # Introduction ~
---
--- hunt.nvim is a powerful and elegant bookmark management plugin for Neovim.
--- It allows you to mark important lines in your code, navigate between them
--- effortlessly, and add contextual annotations - all persisted per git branch.
---
--- Features:
---   - Smart bookmarking with a single command
---   - Quick navigation between bookmarks
---   - Rich annotations displayed as virtual text
---   - Git-aware persistence (per repository and branch)
---   - Visual indicators (customizable signs and inline annotations)
---   - Automatic line tracking as you edit
---   - Zero configuration required
---
--- # Quick Start ~
---                                                           *hunt-quickstart*
---
--- After installation, haunt.nvim works out of the box with sensible defaults.
---
--- Basic usage: >lua
---   -- Add an annotation (creates bookmark if needed)
---   require('hunt.api').annotate()
---
---   -- Navigate to the next bookmark
---   require('hunt.api').next()
---
---   -- Navigate to the previous bookmark
---   require('hunt.api').prev()
---
---   -- Toggle annotation visibility
---   require('hunt.api').toggle_annotation()
---
---   -- Delete bookmark at current line
---   require('hunt.api').delete()
---
---   -- Clear all bookmarks in current file
---   require('hunt.api').clear()
--- <
---
--- Or use the provided commands: >vim
---   :HuntAnnotate
---   :HuntNext
---   :HuntPrev
---   :HuntToggle
---   :HuntDelete
---   :HuntList
---   :HuntClear
---   :HuntClearAll
---   :HuntQf
---   :HuntQfAll
--- <
---
--- # Recommended Keymaps ~
---                                                             *hunt-keymaps*
--- >lua
---   -- Toggle bookmark annotation visibility
---   vim.keymap.set('n', 'mm', function() require('hunt.api').toggle_annotation() end,
---     { desc = "Toggle bookmark annotation" })
---
---   -- Navigate bookmarks
---   vim.keymap.set('n', 'mn', function() require('hunt.api').next() end,
---     { desc = "Next bookmark" })
---   vim.keymap.set('n', 'mp', function() require('hunt.api').prev() end,
---     { desc = "Previous bookmark" })
---
---   -- Annotate bookmark
---   vim.keymap.set('n', 'ma', function() require('hunt.api').annotate() end,
---     { desc = "Annotate bookmark" })
---
---   -- Delete bookmark
---   vim.keymap.set('n', 'md', function() require('hunt.api').delete() end,
---     { desc = "Delete bookmark" })
---
---   -- Clear bookmarks
---   vim.keymap.set('n', 'mc', function() require('hunt.api').clear() end,
---     { desc = "Clear bookmarks in file" })
---   vim.keymap.set('n', 'mC', function() require('hunt.api').clear_all() end,
---     { desc = "Clear all bookmarks" })
---
---   -- List bookmarks
---   vim.keymap.set('n', 'ml', function() require('hunt.picker').show() end,
---     { desc = "List bookmarks" })
--- <
---
--- # Persistence ~
---                                                          *hunt-persistence*
---
--- Bookmarks are automatically saved and loaded:
---   - Location: `~/.local/share/nvim/hunt/` (or custom data_dir)
---   - Format: JSON files named by git repo + branch hash
---   - Auto-save: On text changes (debounced) and Neovim exit
---   - Per-branch: Each git branch has its own bookmark set
---
--- This means you can:
---   - Switch branches without losing bookmarks
---   - Have different bookmarks for different features
---   - Share bookmark files with your team (optional)
---
--- # Troubleshooting ~
---                                                       *hunt-troubleshooting*
---
--- Bookmarks not persisting: ~
---
--- Make sure you're in a git repository with an active branch.
--- hunt.nvim uses git to determine where to save bookmarks.
--- If not in a git repo, bookmarks are stored per working directory.
---
--- Signs not showing: ~
---
--- 1. Verify signs are enabled in your terminal/GUI
--- 2. Check if another plugin is using the sign column
--- 3. Ensure your colorscheme defines the highlight groups
---
--- Bookmarks at wrong lines after editing: ~
---
--- This shouldn't happen as bookmarks use extmarks that track line changes.
--- If it does occur, save your bookmarks and restart Neovim.
---
--- Picker not working: ~
---
--- The picker supports Snacks.nvim (https://github.com/folke/snacks.nvim)
--- and Telescope.nvim (https://github.com/nvim-telescope/telescope.nvim).
--- Install one via your plugin manager, or configure which to use via
--- the `picker` option: "snacks", "telescope", or "auto" (default).

---@class HuntModule
---@field _has_potential_bookmarks fun(): boolean
---@field _ensure_initialized fun()
---@field _setup_restoration_autocmd fun()
---@field setup_autocmds fun()
---@field setup fun(opts?: HuntConfig)
---@field get_config fun(): HuntConfig
---@field is_setup fun(): boolean

---@private
---@type HuntModule
---@diagnostic disable-next-line: missing-fields
local M = {}

local config = require("hunt.config")

-- Track initialization state
---@type boolean
local _initialized = false

function M._ensure_initialized()
	if _initialized then
		return
	end
	_initialized = true

	local display = require("hunt.display")
	display.setup_signs(config.get())
end

---@private
function M._setup_restoration_autocmd()
	local augroup = vim.api.nvim_create_augroup("hunt_restore", { clear = true })
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = augroup,
		callback = function(args)
			M._ensure_initialized()
			require("hunt.api").restore_buffer_bookmarks(args.buf)
		end,
		desc = "Restore bookmark visuals when buffers are opened",
	})

	-- Clean up restoration tracking when buffers are deleted
	vim.api.nvim_create_autocmd("BufDelete", {
		group = augroup,
		callback = function(args)
			require("hunt.api").cleanup_buffer_tracking(args.buf)
		end,
		desc = "Clean up bookmark restoration tracking",
	})

	-- Restore bookmarks for already-loaded buffers (they missed BufReadPost)
	M._ensure_initialized()
	local api = require("hunt.api")
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			api.restore_buffer_bookmarks(bufnr)
		end
	end
end

-- Check if any bookmarks exist
-- This prevents unnecessary writes when there are no bookmarks
local function has_bookmarks()
	-- Use the API's has_bookmarks function which handles loading state properly
	local api = require("hunt.api")
	return api.has_bookmarks()
end

local function save_all_bookmarks()
	if not has_bookmarks() then
		return
	end

	local api = require("hunt.api")
	if api.save_async then
		api.save_async()
	end
end

-- Debounce timer for saving bookmarks after text changes
local save_timer = assert(vim.uv.new_timer())
local SAVE_DEBOUNCE_DELAY = 500 -- milliseconds

-- Debounced save function for text change events
local function debounced_save()
	-- Stop the timer if it's running (safe to call even if not running)
	save_timer:stop()

	-- Restart the timer
	save_timer:start(
		SAVE_DEBOUNCE_DELAY,
		0,
		vim.schedule_wrap(function()
			save_all_bookmarks()
		end)
	)
end

---@private
function M.setup_autocmds()
	local augroup = vim.api.nvim_create_augroup("hunt_autosave", { clear = true })

	-- Save all bookmarks before Vim exits (synchronous to ensure completion)
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = augroup,
		pattern = "*",
		callback = function()
			save_timer:stop()

			if not has_bookmarks() then
				return
			end

			local store = require("hunt.store")
			store.save()
		end,
		desc = "Auto-save all bookmarks before Vim exits",
	})

	-- Save bookmarks after text changes (debounced)
	-- This handles bookmark line updates when text is edited
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = augroup,
		pattern = "*",
		callback = function()
			debounced_save()
		end,
		desc = "Auto-save bookmarks after text changes (handles line updates)",
	})
end

--- Setup function for hunt.nvim.
---
--- Initializes the plugin with user configuration. This is optional -
--- hunt.nvim works with zero configuration using sensible defaults.
---
---@param opts? HuntConfig Optional configuration table. See |HuntConfig|.
---
---@usage >lua
---   -- Use defaults (no setup required)
---   require('hunt.api').annotate()
---
---   -- Or customize with setup
---   require('hunt').setup({
---     sign = '',
---     sign_hl = 'DiagnosticInfo',
---     virt_text_hl = 'Comment',
---   })
--- <
function M.setup(opts)
	config.setup(opts)

	-- Setup custom data directory if provided (deferred until first use)
	local user_config = config.get()
	if user_config.data_dir then
		-- Store for later use, don't load persistence module yet
		vim.schedule(function()
			local persistence = require("hunt.persistence")
			persistence.set_data_dir(user_config.data_dir)
		end)
	end
end

--- Get the current configuration.
---
---@return HuntConfig config The current configuration
function M.get_config()
	return config.get()
end

--- Check if setup has been called.
---
---@return boolean is_setup True if setup has been called, false otherwise
function M.is_setup()
	return config.is_setup()
end

return M
