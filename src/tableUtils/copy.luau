-- From: https://github.com/CavefulGames/luau-table-helper/blob/main/src/lib/init.luau
-- TODO: Remove when https://github.com/CavefulGames/luau-table-helper/pull/6 gets merged & released

local function copy<T>(t: T, deep: boolean?): T
	if not deep then
		return (table.clone(t :: any) :: any) :: T
	end
	local function deepCopy(tbl: { any })
		local tCopy = table.clone(tbl)
		for k, v in tCopy do
			if type(v) == "table" then
				tCopy[k] = deepCopy(v)
			end
		end
		return tCopy
	end
	return deepCopy(t :: any) :: T
end

return copy
