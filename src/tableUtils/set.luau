-- From: https://github.com/CavefulGames/luau-table-helper/blob/main/src/lib/init.luau
-- TODO: Remove when https://github.com/CavefulGames/luau-table-helper/pull/6 gets merged & released

local function set(t: {}, path: { any }, value: any)
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

return set
