-- This file only exists because pathfs doesn't re-export it's internal types
-- So this is just a stripped down version of https://github.com/jiwonz/lune-pathfs/blob/main/src/types.luau

local luauPath = require("../luau_packages/luau_path")
local Path = luauPath.Path
local gt = require("../luau_packages/greentea")

export type Components = typeof(Path.new(""):components())

local PathType = gt.build(gt.custom(luauPath.Path.is, "Path") :: luauPath.Path)
local Components = getmetatable(Path.from("a"):components() :: any).__index :: Components & {
	new: (path: string, prefix: any?, hasPhysicalRoot: boolean) -> Components,
	is: (value: unknown) -> boolean,
}
local ComponentsType = gt.build(gt.custom(Components.is, "Components") :: Components)
local AsPathType = gt.build(gt.union(gt.string(), PathType:type(), ComponentsType:type()))

return {
	PathType = PathType,
	Components = Components,
	ComponentsType = ComponentsType,
	AsPathType = AsPathType,
}
