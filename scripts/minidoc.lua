-- run with: :lua MiniDoc.generate() or :luafile scripts/minidoc.lua

local MiniDoc = require("mini.doc")
_G.MiniDoc = MiniDoc

-- define order for the docs
local files = {
	"lua/hunt/init.lua", -- Main module, introduction, TOC
	"lua/hunt/config.lua", -- Configuration options
	"lua/hunt/api.lua", -- Public API functions
	"lua/hunt/persistence.lua", -- Bookmark structure
	"lua/hunt/picker.lua", -- Picker integration
	"lua/hunt/sidekick.lua", -- Sidekick integration
	"plugin/hunt.lua", -- Commands
}

MiniDoc.generate(files, "doc/hunt.txt")
