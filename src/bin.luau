local argparse = require("../lune_packages/argparse")
local multitarget = require("./lib")
local pathfs = require("../lune_packages/pathfs")
local stdio = require("@lune/stdio")
local serde = require("@lune/serde")
local process = require("@lune/process")

local DEFAULT_OUTPUT_DIR = "dist"
local DEFAULT_LUA_ENV_GLOBAL = "LUA_ENV"

local cli = argparse("multitarget")

local build = cli:command("build", "Build a pesde project for multiple targets")
build:argument("config", "Path to the pesde.toml file"):default("pesde.toml")
build:option("-o --output", "Output directory"):default(DEFAULT_OUTPUT_DIR)
build:option("-g --global", "Lua environment global variable name"):default(DEFAULT_LUA_ENV_GLOBAL)
build:flag("--luau", "Build for Luau")
build:flag("--lune", "Build for Lune")
build:flag("--roblox", "Build for Roblox")
build:option("--build-files", "Paths to build files"):args("*")
build:action(function(args: {
	config: string,
	output: string,
	global: string,
	luau: boolean,
	lune: boolean,
	roblox: boolean,
	build_files: { string }?,
})
	local config = args.config
	local output = args.output
	local targets = {
		luau = args.luau,
		lune = args.lune,
		roblox = args.roblox,
	}
	multitarget.build(config, output, targets, args.build_files, args.global)
end)

local function tableSet(t: {}, path: { any }, value: any)
	local current = t
	for i = 1, #path - 1 do
		local key = path[i]
		if not current[key] then
			current[key] = {}
		end
		current = current[key]
	end
	current[path[#path]] = value
end

local function tableGet(t: {}, path: { any }): any?
	local current = t
	for i = 1, #path - 1 do
		local key = path[i]
		if not current[key] then
			return nil
		end
		current = current[key]
	end
	return current[path[#path]]
end

local setup = cli:command("setup", "Setup your project before building")
setup:action(function()
	do
		local gitignore = pathfs.findFile(".gitignore")
		if gitignore then
			local toIgnore = `/{DEFAULT_OUTPUT_DIR}`
			local content = gitignore:readFile()
			local found = false
			for _, line in content:split("\n") do
				if line == toIgnore then
					found = true
					break
				end
			end
			if not found then
				local yes = stdio.prompt(
					"confirm",
					`Found a .gitignore file. Would you like to add the default output directory('{toIgnore}') to it?`
				)
				if yes then
					content ..= "\n" .. toIgnore .. "\n"
					gitignore:writeFile(content)
				end
			end
		end
	end
	do
		local seleneFile = pathfs.findFile("selene.toml")
		if seleneFile then
			-- selene: allow(shadowing)
			local seleneToml: {
				config: {
					global_usage: {
						ignore_pattern: string?,
					}?,
				}?,
			} =
				serde.decode("toml", seleneFile:readFile())
			local path = { "config", "global_usage", "ignore_pattern" }
			if not tableGet(seleneToml, path) then
				local yes = stdio.prompt(
					"confirm",
					`Found a selene.toml file. Would you to add the default lua environment global variable name('{DEFAULT_LUA_ENV_GLOBAL}') to the ignore pattern?`
				)
				if yes then
					tableSet(seleneToml, path, DEFAULT_LUA_ENV_GLOBAL)
					seleneFile:writeFile(serde.encode("toml", seleneToml, true))
				end
			end
		end
	end
	do
		local ok, result = pcall(process.spawn, "darklua", { "--version" })
		if not ok or (ok and not result.ok) then
			local yes = stdio.prompt("confirm", `darklua is not found. Would you like to install it from pesde?`)
			if yes then
				process.spawn("pesde", { "add", "pesde/darklua", "--dev", "-t", "lune" }, { stdio = "forward" })
				process.spawn("pesde", { "install" }, { stdio = "forward" })
			end
		end
	end

	print("You are ready to go! Try running 'multitarget build [arguments]' to build your project.")
end)

cli:parse()
