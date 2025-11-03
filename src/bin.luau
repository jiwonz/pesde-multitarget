local argparse = require("../lune_packages/argparse")
local multitarget = require("./lib")
local pathfs = require("../lune_packages/pathfs")
local fs = pathfs.fs
local stdio = require("@lune/stdio")
local serde = require("@lune/serde")
local process = require("@lune/process")
local chalk = require("../luau_packages/chalk_luau")

local set = require("./tableUtils/set")

local DEFAULT_OUTPUT_DIR = multitarget.DEFAULT_OUTPUT_DIR
local DEFAULT_LUA_ENV_GLOBAL = multitarget.DEFAULT_LUA_ENV_GLOBAL
local DEFAULT_PKG_ALIAS = multitarget.DEFAULT_PKG_ALIAS
local ERROR_PREFIX = `{stdio.color("red")}{stdio.style("bold")}error{stdio.color("reset")}:`
local WARN_PREFIX = `{stdio.color("yellow")}{stdio.style("bold")}warn{stdio.color("reset")}:`
local DEFAULT_DECLARATION_FILE_CONTENT = `declare _G: \{\
	{DEFAULT_LUA_ENV_GLOBAL}: ("luau" | "lune" | "roblox")?,\
\}\
`
local COLORFUL_TARGETS = {
	luau = chalk.bgBlue(chalk.bold("Luau")),
	lune = chalk.bgMagenta(chalk.bold("Lune")),
	roblox = chalk.red(chalk.bold("ROBLOX")),
}
local DEFAULT_LUAU_PKG_ALIAS = multitarget.DEFAULT_LUAU_PKG_ALIAS

local CLI_NAME = "multitarget"
local cli = argparse(CLI_NAME, "A tool to build a pesde project for multiple targets")

local build = cli:command("build", "Build a pesde project for multiple targets")
build:argument("project", "Path to the pesde.toml file"):default("pesde.toml")
build:option("-o --output", "Output directory"):default(DEFAULT_OUTPUT_DIR)
build:option("-g --global", "Lua environment global variable name"):default(DEFAULT_LUA_ENV_GLOBAL)
build:option("-p --pkg", "Package alias name"):default(DEFAULT_PKG_ALIAS)
build:option("--luau-pkg", "Luau Package alias name (Used for Lune target)"):default(DEFAULT_LUAU_PKG_ALIAS)
build:flag("--luau", "Build for Luau")
build:flag("--lune", "Build for Lune and Prefix for luau package alias")
build:flag("--roblox", "Build for Roblox")
build:flag("-a --all", "Build for every targets (luau, lune, roblox)")
build:option("--build-files", "Paths to build files"):args("*")
build:flag("-y --yes", "Automatically confirm prompts without asking")
build:flag("--non-strict", "Do not fail the build when there are errors while re-adding dependencies")
build:option("--require-mode", "Which darklua require mode the current source code is using"):default("luau")
build:action(function(args: {
	project: string,
	output: string,
	global: string,
	pkg: string,
	luau_pkg: string,
	luau: boolean,
	lune: boolean,
	roblox: boolean,
	all: boolean,
	build_files: { string }?,
	yes: boolean,
	non_strict: boolean,
	require_mode: string,
})
	local output = args.output
	if fs.isDir(output) then
		if args.yes or stdio.prompt("confirm", "Output directory already exists. Would you like to overwrite it?") then
			fs.removeDir(output)
		else
			print("Canceled. Output directory already exists.")
			process.exit(1)
		end
	end
	if args.all then
		args.luau = true
		args.lune = true
		args.roblox = true
	end
	local targets = {
		luau = args.luau,
		lune = args.lune,
		roblox = args.roblox,
	}
	local result = multitarget.build(
		args.project,
		targets,
		output,
		args.build_files,
		args.global,
		args.pkg,
		args.luau_pkg,
		not args.non_strict,
		args.require_mode
	)
	if result:isErr() then
		local err = result:unwrapErr()

		if err.outputDir then -- rollback!
			print(`{WARN_PREFIX} Error occurred while building the project. Deleting the output directory...`)
			err.outputDir:removeDir()
		end

		stdio.ewrite(`{ERROR_PREFIX} {err.message}\n`)
		process.exit(1)
		error("unreachable")
	end

	local colorfulTargets = {}
	for target: string, enabled: boolean in targets :: any do
		if enabled then
			table.insert(colorfulTargets, COLORFUL_TARGETS[target])
		end
	end
	print(
		`\n{stdio.color("green")}Build completed!{stdio.color("reset")} {table.concat(colorfulTargets, ", ")}\nTo publish them, run 'cd {output} && pesde publish'`
	)
end)

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
		local pesdeToml = pathfs.FilePath.new("pesde.toml")
		if not pesdeToml:isFile() then
			stdio.ewrite(`{ERROR_PREFIX} pesde.toml is not found. Are you in the right directory?\n`)
			process.exit(1)
			error("unreachable")
		end
		local pesdeManifest: {
			private: boolean?,
			dependencies: { [string]: any }?,
			peer_dependencies: { [string]: any }?,
			target: {
				environment: ("luau" | "lune" | "roblox")?,
			}?,
		} =
			serde.decode("toml", pesdeToml:readFile())
		if not pesdeManifest.private then
			print(
				`{WARN_PREFIX} It is recommended to set 'private = true' in pesde.toml to prevent accidental publishing the root project.`
			)
		end
		local luaurcFile = pathfs.FilePath.new(".luaurc")
		local luaurc: {
			aliases: { [string]: string? }?,
		} = if luaurcFile:isFile()
			then serde.decode("json", luaurcFile:readFile())
			else {}
		if not pesdeManifest.target or not pesdeManifest.target.environment then
			stdio.ewrite(`{ERROR_PREFIX} 'target.environment' is not found in pesde.toml\n`)
			process.exit(1)
			error("unreachable")
		end
		local pkgPath = `./{pesdeManifest.target.environment}_packages/`
		local pkgAlias = luaurc.aliases and luaurc.aliases[DEFAULT_PKG_ALIAS]
		local hasDependencies = (
			(pesdeManifest.dependencies and next(pesdeManifest.dependencies))
			or (pesdeManifest.peer_dependencies and next(pesdeManifest.peer_dependencies))
		)
		local isPkgAliasInvalid = if pkgAlias then pkgAlias ~= pkgPath else false
		if (not pkgAlias and hasDependencies) or isPkgAliasInvalid then
			if isPkgAliasInvalid then
				print(
					`{WARN_PREFIX} @{DEFAULT_PKG_ALIAS} alias already used. This will be replaced with './\{target\}_packages/' for each target's dependencies when you build the project.`
				)
			end
			if
				stdio.prompt(
					"confirm",
					`Found dependencies in pesde.toml. Would you like to add default aliases '@{DEFAULT_PKG_ALIAS}' and '@{DEFAULT_LUAU_PKG_ALIAS}' in .luaurc for each target's dependencies?`
				)
			then
				set(luaurc, { "aliases", DEFAULT_PKG_ALIAS }, pkgPath)
				set(luaurc, { "aliases", DEFAULT_LUAU_PKG_ALIAS }, "./luau_packages/")
				luaurcFile:writeFile(serde.encode("json", luaurc, true))
			end
		end
	end
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
				if
					stdio.prompt(
						"confirm",
						`Found a .gitignore file. Would you like to add the default output directory('{toIgnore}') to it?`
					)
				then
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
				if
					stdio.prompt(
						"confirm",
						`Found a selene.toml file. Would you like to add the default lua environment global variable name('{DEFAULT_LUA_ENV_GLOBAL}') to the ignore pattern?`
					)
				then
					set(seleneToml, path, DEFAULT_LUA_ENV_GLOBAL)
					seleneFile:writeFile(serde.encode("toml", seleneToml, true))
				end
			end
		end
	end
	do
		local ok, result = pcall(process.exec, "darklua", { "--version" })
		if not ok or (ok and not result.ok) then
			if stdio.prompt("confirm", `darklua is not found. Would you like to install it from pesde?`) then
				process.exec("pesde", { "add", "pesde/darklua", "--dev", "-t", "lune" }, { stdio = "forward" })
				process.exec("pesde", { "install" }, { stdio = "forward" })
			end
		end
	end
	do
		local declarationFile = pathfs.FilePath.new(".d.luau")
		if not declarationFile:isFile() then
			if
				stdio.prompt(
					"confirm",
					`Would you like to add .d.luau type definition file for default lua environment global variable name('{DEFAULT_LUA_ENV_GLOBAL}')?`
				)
			then
				declarationFile:writeFile(DEFAULT_DECLARATION_FILE_CONTENT)
			end
		end
	end
	do
		local vscodeDir = pathfs.DirectoryPath.new(".vscode")
		local vscodeSettings = pathfs.FilePath.new(vscodeDir.path:join("settings.json"))
		local settings: {
			["luau-lsp.types.definitionFiles"]: { string }?,
		} = if vscodeSettings:isFile()
			then serde.decode("json", vscodeSettings:readFile())
			else {}
		if
			not settings["luau-lsp.types.definitionFiles"]
			or not table.find(settings["luau-lsp.types.definitionFiles"], ".d.luau")
		then
			if
				stdio.prompt(
					"confirm",
					"Would you like to add .d.luau type definition file to '.vscode/settings.json'?"
				)
			then
				local defFiles = settings["luau-lsp.types.definitionFiles"] or {}
				table.insert(defFiles, ".d.luau")
				settings["luau-lsp.types.definitionFiles"] = defFiles
				if not vscodeDir:isDir() then
					vscodeDir:writeDir()
				end
				vscodeSettings:writeFile(serde.encode("json", settings, true))
			end
		end
	end

	print(
		chalk.green(
			chalk.bold("You are ready to go! Try running 'multitarget build [arguments]' to build your project.")
		)
	)
end)

local version = cli:command("version", "Show the version of multitarget")
version:action(function()
	local multitargetPesdeToml = pathfs.FilePath.fromExisting(pathfs.Path.from(_G.PESDE_ROOT):join("pesde.toml"))
	local pesdeManifest: {
		version: string,
	} = serde.decode("toml", multitargetPesdeToml:readFile())
	print(`{CLI_NAME} {pesdeManifest.version}`)
end)

cli:parse()
