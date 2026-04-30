---@toc_entry Commands
---@tag hunt-commands
---@text
--- # Commands ~
---
--- hunt.nvim provides the following user commands:
---
--- `:HuntToggle` - Toggle bookmark annotation visibility
--- `:HuntAnnotate [text]` - Add or edit annotation for bookmark at cursor
--- `:HuntDelete` - Delete bookmark at current line
--- `:HuntNext` - Jump to next bookmark
--- `:HuntPrev` - Jump to previous bookmark
--- `:HuntList` - Open interactive picker to browse all bookmarks
--- `:HuntClear` - Clear all bookmarks in current buffer
--- `:HuntClearAll` - Clear all bookmarks across all files
--- `:HuntChangeDataDir [path]` - Change bookmark data directory (for project-specific bookmarks)
---

-- hunt.nvim plugin loader
-- This file is automatically sourced by Neovim when the plugin is installed

-- Prevent loading twice
if vim.g.loaded_hunt == 1 then
	return
end
vim.g.loaded_hunt = 1

---@class HuntCommandInfo
---@field fn string
---@field desc string
---@field has_args? boolean
---@field args? table

---@type table<string, HuntCommandInfo>
local commands = {
	HuntToggle = { fn = "toggle_annotation", desc = "Toggle bookmark annotation visibility" },
	HuntAnnotate = { fn = "annotate", desc = "Add/edit annotation", has_args = true },
	HuntClear = { fn = "clear", desc = "Clear bookmarks in current file" },
	HuntClearAll = { fn = "clear_all", desc = "Clear all bookmarks" },
	HuntNext = { fn = "next", desc = "Jump to next bookmark" },
	HuntPrev = { fn = "prev", desc = "Jump to previous bookmark" },
	HuntDelete = { fn = "delete", desc = "Delete bookmark at current line" },
	HuntQf = { fn = "to_quickfix", desc = "Send Buffer Annotations to Quickfix List", args = { current_buffer = true } },
	HuntQfAll = { fn = "to_quickfix", desc = "Send All Annotations to Quickfix List" },
	HuntChangeDataDir = { fn = "change_data_dir", desc = "Change bookmark data directory", has_args = true },
}

for name, info in pairs(commands) do
	vim.api.nvim_create_user_command(name, function(opts)
		if info.has_args and opts.args ~= "" then
			require("hunt.api")[info.fn](opts.args)
		elseif info.args then
			require("hunt.api")[info.fn](info.args)
		else
			require("hunt.api")[info.fn]()
		end
	end, { desc = info.desc, nargs = info.has_args and "?" or 0 })
end

-- Special case for HuntList (uses picker)
vim.api.nvim_create_user_command("HuntList", function()
	require("hunt.picker").show()
end, { desc = "List all bookmarks" })

-- Deferred restoration setup. Dashboard plugins seemingly block this
vim.api.nvim_create_autocmd("UIEnter", {
	once = true,
	callback = function()
		vim.schedule(function()
			require("hunt")._setup_restoration_autocmd()
		end)
	end,
})
