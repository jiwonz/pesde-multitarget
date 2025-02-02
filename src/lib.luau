local stdio = require("@lune/stdio")
local serde = require("@lune/serde")
local pathfs = require("../lune_packages/pathfs")
local fs = pathfs.fs
local gt = require("../lune_packages/greentea")
local glob = require("../lune_packages/glob")
local process = require("@lune/process")
local darklua = require("../lune_packages/darklua_lune")

local ERROR_PREFIX = `{stdio.color("red")}{stdio.style("bold")}error{stdio.color("reset")}:`
local DEFAULT_DARKLUA_RULES = {
	"remove_unused_if_branch",
	"filter_after_early_return",
	"remove_empty_do",
}

local multitarget = {}

local targetsType = gt.build(gt.table({
	luau = gt.opt(gt.boolean()),
	lune = gt.opt(gt.boolean()),
	roblox = gt.opt(gt.boolean()),
}))
local environmentType = gt.build(gt.union(gt.literal("luau"), gt.literal("lune"), gt.literal("roblox")))
local optionalStringType = gt.build(gt.opt(gt.string()))
local optionalStringArrayType = gt.build(gt.opt(gt.array(gt.string())))

-- local function processDarklua(input: string, output: string, config: {})
-- 	local darkluaProcessArgs = {
-- 		"process",
-- 		input,
-- 		output,
-- 	}
-- 	--if not fs.isFile(".darklua.json") and not fs.isFile(".darklua.json5") then
-- 	local darkluaConfigFile = dirs.createTempFile()

-- 	darkluaConfigFile:writeFile(serde.encode("json", config, true))

-- 	table.insert(darkluaProcessArgs, "--config")
-- 	table.insert(darkluaProcessArgs, darkluaConfigFile.path:toString())
-- 	--end

-- 	local result = process.spawn("darklua", darkluaProcessArgs, {
-- 		stdio = "forward",
-- 	})
-- 	if not result.ok then
-- 		stdio.ewrite(`{ERROR_PREFIX} darklua failed to build.\n\nstdout: {result.stdout}\n\nstderr: {result.stderr}\n`)
-- 		process.exit(1)
-- 		error("unreachable")
-- 	end
-- end

local optionalAsPathType = gt.build(gt.opt(pathfs.types.AsPath:type()))
function multitarget.build(
	pesdeTomlPath: typeof(optionalAsPathType:type()),
	outputPath: typeof(pathfs.types.AsPath:type()),
	targets: typeof(targetsType:type()),
	buildFiles: typeof(optionalStringArrayType:type()),
	luaEnvGlobal: typeof(optionalStringType:type())
)
	optionalAsPathType:assert(pesdeTomlPath)
	pathfs.types.AsPath:assert(outputPath)
	targetsType:assert(targets)
	optionalStringArrayType:assert(buildFiles)
	optionalStringType:assert(luaEnvGlobal)

	-- selene: allow(shadowing)
	local luaEnvGlobal = luaEnvGlobal or "LUA_ENV"
	-- selene: allow(shadowing)
	local pesdeTomlFile = pathfs.File.fromExisting(pesdeTomlPath or "pesde.toml")
	local outputDir = pathfs.Directory.create(outputPath, true)
	local pesdeToml: {
		includes: { string }?,
		target: {
			environment: typeof(environmentType:type())?,
			lib: string?,
			bin: string?,
			build_files: { string }?,
		},
	} =
		serde.decode("toml", pesdeTomlFile:readFile())

	if not pesdeToml.target then
		stdio.ewrite(`{ERROR_PREFIX} 'target' field is required in 'pesde.toml'.\n`)
		process.exit(1)
		error("unreachable")
	end

	for target: typeof(environmentType:type()), targetConfig: any in targets :: any do
		if not targetConfig then
			continue
		end
		environmentType:assert(target)

		local targetDir = pathfs.Directory.create(outputDir.path:join(target))
		-- selene: allow(shadowing)
		local pesdeToml = table.clone(pesdeToml)
		if pesdeToml.includes then
			for _, include in pesdeToml.includes do
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
			if pesdeToml.target.lib then
				local dest = targetDir.path:join(pesdeToml.target.lib)
				local parent = dest:parent()
				if parent then
					fs.writeDir(parent)
				end
				fs.copy(pesdeToml.target.lib, dest, true)
			end
			if pesdeToml.target.bin then
				local dest = targetDir.path:join(pesdeToml.target.bin)
				local parent = dest:parent()
				if parent then
					fs.writeDir(parent)
				end
				fs.copy(pesdeToml.target.bin, dest, true)
			end
		end

		local injectGlobalValueRule = {
			rule = "inject_global_value",
			identifier = luaEnvGlobal,
			value = target,
		}
		if buildFiles then
			if target == "luau" or target == "lune" then
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
			elseif target == "roblox" then -- not ready yet, needs darklua path require conversion
				pesdeToml.target.build_files = buildFiles
				for _, buildFile in buildFiles do
					-- local luaurc = if fs.isFile(".luaurc") then
					-- 	serde.decode("json", fs.readFile(".luaurc")) :: {
					-- 		aliases: { [string]: string },
					-- 	}
					-- else nil
					local darkluaOutputPath = targetDir.path:join(buildFile)

					local rules = {
						injectGlobalValueRule :: any,
						{
							rule = "convert_require",
							current = {
								name = "path",
								-- sources = if luaurc then -- remove this after darklua 0.16.0
								-- 	luaurc.aliases
								-- else nil,
							},
							target = {
								name = "roblox",
								indexing_style = "property",
								rojo_sourcemap = if fs.isFile("sourcemap.json") then "sourcemap.json" else nil,
							},
						},
					}
					for _, rule in DEFAULT_DARKLUA_RULES do
						table.insert(rules, rule)
					end
					darklua.process(buildFile, darkluaOutputPath:toString(), {
						rules = rules,
					})
				end
			end
		end

		pesdeToml.target.environment = target
		fs.writeFile(targetDir.path:join("pesde.toml"), serde.encode("toml", pesdeToml, true))
	end
end

return multitarget
