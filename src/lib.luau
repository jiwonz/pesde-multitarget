local stdio = require("@lune/stdio")
local serde = require("@lune/serde")
local pathfs = require("../lune_packages/pathfs")
local fs = pathfs.fs
local gt = require("../lune_packages/greentea")
local glob = require("../lune_packages/glob")
local process = require("@lune/process")
local darklua = require("../lune_packages/darklua_lune")
local Result = require("../lune_packages/result")
local tableHelper = require("../luau_packages/table_helper")

local DEFAULT_DARKLUA_RULES = {
	"remove_unused_if_branch",
	"filter_after_early_return",
	"remove_empty_do",
}
local DEFAULT_PESDE_TOML_DIR = "pesde.toml"
local DEFAULT_OUTPUT_DIR = "target"
local DEFAULT_LUA_ENV_GLOBAL = "LUA_ENV"
local DEFAULT_PKG_ALIAS = "pkg"
local DEFAULT_LUAU_PKG_ALIAS = "luau_pkg"

type Dependency = {
	name: string?,
	version: string?,
	wally: string?,
	workspace: string?,
	repo: string?,
	path: string?,
}

--[=[
	@class multitarget
	@prop DEFAULT_PESDE_TOML_DIR string
	@prop DEFAULT_OUTPUT_DIR string
	@prop DEFAULT_LUA_ENV_GLOBAL string
	@prop DEFAULT_PKG_ALIAS string

	# [pesde-multitarget](https://pesde.dev/packages/jiwonz/multitarget)
	Customizable and flexible build script for multiple pesde targets

	Build your pure pesde project easier targeting both `luau` and `roblox` targets at the same time.

	No more annoying package build scripts manually! (But this doesn't support `wally`)
]=]
local multitarget = {}

local targetsType = gt.build(gt.table({
	luau = gt.opt(gt.boolean()),
	lune = gt.opt(gt.boolean()),
	roblox = gt.opt(gt.boolean()),
}, {
	min = 1,
	max = 3,
}))
local environmentType = gt.build(gt.union(gt.literal("luau"), gt.literal("lune"), gt.literal("roblox")))
local optionalStringType = gt.build(gt.opt(gt.string()))
local optionalStringArrayType = gt.build(gt.opt(gt.array(gt.string())))
local optionalAsPathType = gt.build(gt.opt(pathfs.types.AsPath:type()))
local optionalBooleanType = gt.build(gt.opt(gt.boolean()))

--[=[
	@within multitarget
	@param pesdeTomlPath string? -- Path to the `pesde.toml` file. Default is `pesde.toml`.
	@param targets { luau: boolean?, lune: boolean?, roblox: boolean? } -- Targets to build
	@param outputPath string? -- Output directory. Default is `dist`.
	@param buildFiles { string }? -- Paths to build files
	@param luaEnvGlobal string? -- Lua environment global variable name. Default is `LUA_ENV`.
	@param pkgAlias string? -- Package alias name. Default is `pkg`.
	@param strict boolean? -- Stop the process if any error occurs while re-adding dependencies. Defaults to `true`.

	Builds a pesde project for multiple targets

	Pass `nil` to use default arguments.

	```lua
	local result = multitarget.build("pesde.toml", {
		luau = true,
		lune = true,
		roblox = true,
	}, "dist", { "build.lua" }, "LUA_ENV", "pkg")

	if result:isOk() then
		print("Built successfully!")
	else
		print("Error:", result:unwrapErr().message)
	end
	```
]=]
function multitarget.build(
	pesdeTomlPath: typeof(optionalAsPathType:type()),
	targets: typeof(targetsType:type()),
	outputPath: typeof(optionalAsPathType:type()),
	buildFiles: typeof(optionalStringArrayType:type()),
	luaEnvGlobal: typeof(optionalStringType:type()),
	pkgAlias: typeof(optionalStringType:type()),
	luauPkgAlias: typeof(optionalStringType:type()),
	strict: typeof(optionalBooleanType:type())
): Result.Result<pathfs.Directory, {
	message: string,
	outputDir: pathfs.Directory?,
}>
	pathfs.types.AsPath:assert(pesdeTomlPath)
	pathfs.types.AsPath:assert(outputPath)
	targetsType:assert(targets)
	optionalStringArrayType:assert(buildFiles)
	optionalStringType:assert(luaEnvGlobal)
	optionalStringType:assert(pkgAlias)
	optionalStringType:assert(luauPkgAlias)
	optionalBooleanType:assert(strict)

	-- selene: allow(shadowing)
	local luauPkgAlias = luauPkgAlias or DEFAULT_LUAU_PKG_ALIAS
	-- selene: allow(shadowing)
	local strict = strict == nil or strict
	-- selene: allow(shadowing)
	local pesdeTomlPath = pesdeTomlPath or DEFAULT_PESDE_TOML_DIR
	-- selene: allow(shadowing)
	local outputPath = outputPath or DEFAULT_OUTPUT_DIR
	-- selene: allow(shadowing)
	local luaEnvGlobal = luaEnvGlobal or DEFAULT_LUA_ENV_GLOBAL
	-- selene: allow(shadowing)
	local pkgAlias = pkgAlias or DEFAULT_PKG_ALIAS
	-- selene: allow(shadowing)
	local pesdeTomlFile = pathfs.File.fromExisting(pesdeTomlPath)
	local outputDir = pathfs.findDirectory(outputPath)
	if outputDir then
		return Result.Err({
			message = `Output directory '{outputDir.path}' already exists.`,
		})
	end
	-- selene: allow(shadowing)
	local outputDir = pathfs.Directory.create(outputPath)

	local pesdeToml: {
		includes: { string }?,
		target: {
			environment: typeof(environmentType:type())?,
			lib: string?,
			bin: string?,
			build_files: { string }?,
			scripts: { [string]: string }?,
		},
		dependencies: { [string]: Dependency }?,
		dev_dependencies: { [string]: Dependency }?,
		peer_dependencies: { [string]: Dependency }?,
		private: boolean?,
		engines: { [string]: string }?,
		wally_indices: { [string]: string }?,
	} =
		serde.decode("toml", pesdeTomlFile:readFile())

	if not pesdeToml.target then
		return Result.Err({
			message = `'target' field is required in 'pesde.toml'.`,
			outputDir = outputDir,
		})
	end
	-- selene: allow(shadowing)
	local buildFiles = (pesdeToml.target.build_files or buildFiles) :: typeof(buildFiles)

	local pesdeAddParams = {}
	local function getPackageName(dep: Dependency): string?
		if dep.name and dep.version then
			return `{dep.name}@{dep.version}`
		end
		if dep.wally and dep.version then
			return `wally#{dep.name}@{dep.version}`
		end
		return nil
	end
	if pesdeToml.dependencies then
		for alias, dep in pesdeToml.dependencies do
			local packageName = getPackageName(dep)
			if packageName then
				table.insert(pesdeAddParams, { "--alias", alias, packageName })
			end
		end
	end
	if pesdeToml.peer_dependencies then
		for alias, dep in pesdeToml.peer_dependencies do
			local packageName = getPackageName(dep)
			if packageName then
				table.insert(pesdeAddParams, { "--alias", alias, "--peer", packageName })
			end
		end
	end

	do
		local members = {}
		for t, value in targets :: { [typeof(environmentType:type())]: boolean? } do
			if value == nil then
				continue
			end
			table.insert(members, t)
		end
		local workspacePesdeToml = {
			name = "multitarget/root",
			version = "0.0.0",
			private = true,
			workspace_members = members,
			target = { environment = "luau" },
		}
		fs.writeFile(outputDir.path:join("pesde.toml"), serde.encode("toml", workspacePesdeToml, true))
	end

	if not buildFiles then
		if targets.roblox then
			return Result.Err({
				message = `Build files are required for 'roblox' target.`,
				outputDir = outputDir,
			})
		end
		print(
			`{stdio.color("yellow")}warn{stdio.color("reset")}: None of build files are specified. The files may not be processed properly. It is ok to skip if you haven't used '_G.{luaEnvGlobal}' in your build files.`
		)
	end

	for target: "lune" | "luau" | "roblox", value in targets :: { [any]: boolean? } do
		if not value then
			continue
		end
		environmentType:assert(target)

		local targetDir = pathfs.Directory.new(outputDir.path:join(target))
		-- selene: allow(shadowing)
		local newPesdeToml = tableHelper.copy(pesdeToml, true)
		if newPesdeToml.includes then
			for _, include in newPesdeToml.includes do
				for _, path in glob(include) do
					local dest = targetDir.path:join(path)
					local parent = dest:parent()
					if parent then
						fs.writeDir(parent)
					end
					fs.copy(path, dest, true)
				end
			end
		else
			if newPesdeToml.target.lib then
				local dest = targetDir.path:join(newPesdeToml.target.lib)
				local parent = dest:parent()
				if parent then
					fs.writeDir(parent)
				end
				fs.copy(newPesdeToml.target.lib, dest, true)
			end
			if newPesdeToml.target.bin then
				local dest = targetDir.path:join(newPesdeToml.target.bin)
				local parent = dest:parent()
				if parent then
					fs.writeDir(parent)
				end
				fs.copy(newPesdeToml.target.bin, dest, true)
			end
		end

		newPesdeToml.private = nil

		if #pesdeAddParams > 0 then -- there are dependencies
			local luaurcFile = pathfs.File.new(targetDir.path:join(".luaurc"))
			local luaurc: {
				aliases: { [string]: string? }?,
			} = if luaurcFile:isFile()
				then serde.decode("json", luaurcFile:readFile())
				else {}
			tableHelper.set(luaurc, { "aliases", pkgAlias }, `./{target}_packages/`)
			if targets.lune then
				if target == "lune" then
					tableHelper.set(luaurc, { "aliases", luauPkgAlias }, `./luau_packages/`)
				elseif target == "roblox" then
					tableHelper.set(luaurc, { "aliases", luauPkgAlias }, `./roblox_packages/`)
				end
			end
			luaurcFile:writeFile(serde.encode("json", luaurc, true))

			local includes = newPesdeToml.includes or {}
			if table.find(includes, ".luaurc") == nil then
				table.insert(includes, ".luaurc")
			end
			newPesdeToml.includes = includes
		end

		if target == "luau" or target == "lune" then
			newPesdeToml.target.build_files = nil
			newPesdeToml.wally_indices = nil
		elseif target == "roblox" then
			newPesdeToml.target.build_files = buildFiles
			newPesdeToml.target.bin = nil
			newPesdeToml.target.scripts = nil
			newPesdeToml.engines = nil
		end
		newPesdeToml.target.environment = target
		newPesdeToml.dev_dependencies = nil
		newPesdeToml.peer_dependencies = nil
		newPesdeToml.dependencies = nil
		fs.writeFile(targetDir.path:join("pesde.toml"), serde.encode("toml", newPesdeToml, true))

		for _, pesdeAddParam in pesdeAddParams do
			local params = { "add" }
			for _, param in pesdeAddParam do
				table.insert(params, param)
			end
			table.insert(params, "--target")
			table.insert(params, target)
			local result = process.spawn("pesde", params, {
				cwd = targetDir.path:toString(),
				stdio = "inherit",
			})
			if not result.ok and target == "lune" then
				params[#params] = "luau"
				result = process.spawn("pesde", params, {
					cwd = targetDir.path:toString(),
					stdio = "inherit",
				})
			end
			if strict and not result.ok then
				return Result.Err({
					message = `Failed to add dependency '{table.concat(pesdeAddParam, " ")}' to '{target}' target.`,
					outputDir = outputDir,
				})
			end
		end

		local injectGlobalValueRule = {
			rule = "inject_global_value",
			identifier = luaEnvGlobal,
			value = target,
		}
		if buildFiles then
			for _, buildFile in buildFiles do
				local darkluaOutputPath = targetDir.path:join(buildFile)

				local rules = { injectGlobalValueRule :: any }
				for _, rule in DEFAULT_DARKLUA_RULES do
					table.insert(rules, rule)
				end
				darklua.process(buildFile, darkluaOutputPath:toString(), {
					rules = rules,
				})
			end
			if target == "roblox" then
				-- need to install dependencies for darklua
				local result = process.spawn("pesde", { "install" }, {
					cwd = outputDir.path:toString(),
					stdio = "inherit",
				})
				if not result.ok then
					return Result.Err({
						message = `Failed to install dependencies for '{target}' target.`,
						outputDir = outputDir,
					})
				end

				for _, buildFile in buildFiles do
					local darkluaOutputPath = targetDir.path:join(buildFile)

					local rules = {
						injectGlobalValueRule :: any,
						{
							rule = "convert_require",
							current = {
								name = "path",
							},
							target = {
								name = "roblox",
								indexing_style = "property",
								rojo_sourcemap = if fs.isFile("sourcemap.json") then "sourcemap.json" else nil,
							},
						},
					}
					darklua.process(darkluaOutputPath:toString(), darkluaOutputPath:toString(), {
						rules = rules,
					}, {
						stdio = "inherit",
					})
				end
			end
		end
	end

	return Result.Ok(outputDir)
end

multitarget.DEFAULT_PESDE_TOML_DIR = DEFAULT_PESDE_TOML_DIR
multitarget.DEFAULT_OUTPUT_DIR = DEFAULT_OUTPUT_DIR
multitarget.DEFAULT_LUA_ENV_GLOBAL = DEFAULT_LUA_ENV_GLOBAL
multitarget.DEFAULT_PKG_ALIAS = DEFAULT_PKG_ALIAS
multitarget.DEFAULT_LUAU_PKG_ALIAS = DEFAULT_LUAU_PKG_ALIAS

return multitarget
