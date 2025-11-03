local lib = require("../src/lib")

lib.build(
	"pesde.toml",
	{
		luau = true,
		lune = true,
		roblox = true,
	},
	"dist",
	{
		"src",
	},
	"LUA_ENV",
	"pkg"
)
