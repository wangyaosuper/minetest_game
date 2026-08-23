minetest.set_gen_notify({dungeon = true, temple = true})

local function noise3d_integer(noise, pos)
	return math.abs(math.floor(noise:get_3d(pos) * 0x7fffffff))
end

local function random_sample(rand, list, count)
	local ret = {}
	for n = 1, count do
		if #list == 0 then
			break
		end
		local idx = rand:next(1, #list)
		table.insert(ret, list[idx])
		table.remove(list, idx)
	end
	return ret
end

local function find_walls(cpos, is_temple)
	local is_wall = function(node)
		return node.name ~= "air" and node.name ~= "ignore"
	end

	local dirs = {{x=1, z=0}, {x=-1, z=0}, {x=0, z=1}, {x=0, z=-1}}
	local get_node = minetest.get_node

	local ret = {}
	local mindist = {x=0, z=0}
	local min = function(a, b) return a ~= 0 and math.min(a, b) or b end
	for _, dir in ipairs(dirs) do
		for i = 1, 9 do -- 9 = max room size / 2
			local pos = vector.add(cpos, {x=dir.x*i, y=0, z=dir.z*i})

			-- continue in that direction until we find a wall-like node
			local node = get_node(pos)
			if is_wall(node) then
				local front_below = vector.subtract(pos, {x=dir.x, y=1, z=dir.z})
				local above = vector.add(pos, {x=0, y=1, z=0})

				-- check that it:
				--- is at least 2 nodes high (not a staircase)
				--- has a floor
				if is_wall(get_node(front_below)) and is_wall(get_node(above)) then
					table.insert(ret, {pos = pos, facing = {x=-dir.x, y=0, z=-dir.z}})
					if dir.z == 0 then
						mindist.x = min(mindist.x, i-1)
					else
						mindist.z = min(mindist.z, i-1)
					end
				end
				-- abort even if it wasn't a wall cause something is in the way
				break
			end
		end
	end

	local biome = minetest.get_biome_data(cpos)
	biome = biome and minetest.get_biome_name(biome.biome) or ""
	local type = "normal"
	if is_temple or biome:find("desert") == 1 then
		type = "desert"
	elseif biome:find("sandstone_desert") == 1 then
		type = "sandstone"
	elseif biome:find("icesheet") == 1 then
		type = "ice"
	end

	return {
		walls = ret,
		size = {x=mindist.x*2, z=mindist.z*2},
		type = type,
	}
end

local function get_dungeon_type(pos)
	local biome = minetest.get_biome_data(pos)
	biome = biome and minetest.get_biome_name(biome.biome) or ""
	local type = "normal"
	if biome:find("desert") == 1 then
		type = "desert"
	elseif biome:find("sandstone_desert") == 1 then
		type = "sandstone"
	elseif biome:find("icesheet") == 1 then
		type = "ice"
	end
	return type
end

local function populate_chest(pos, rand, dungeontype)
	local item_list = dungeon_loot._internal_get_loot(pos.y, dungeontype)
	-- take random (partial) sample of all possible items
	local sample_n = math.min(#item_list, dungeon_loot.STACKS_PER_CHEST_MAX)
	item_list = random_sample(rand, item_list, sample_n)

	-- apply chances / randomized amounts and collect resulting items
	local items = {}
	local has_flint = false
	for _, loot in ipairs(item_list) do
		if rand:next(0, 1000) / 1000 <= loot.chance then
			local itemdef = minetest.registered_items[loot.name]
			local amount = 1
			if loot.count ~= nil then
				amount = rand:next(loot.count[1], loot.count[2])
			end

			if loot.name == "default:flint" then
				has_flint = true
			end

			if not itemdef then
				minetest.log("warning", "Registered loot item " .. loot.name .. " does not exist")
			elseif itemdef.tool_capabilities then
				for n = 1, amount do
					local wear = rand:next(0.20 * 65535, 0.75 * 65535) -- 20% to 75% wear
					table.insert(items, ItemStack({name = loot.name, wear = wear}))
				end
			elseif itemdef.stack_max == 1 then
				for n = 1, amount do
					table.insert(items, loot.name)
				end
			else
				table.insert(items, ItemStack({name = loot.name, count = amount}))
			end
		end
	end

	-- Guaranteed: every chest must have flint
	if not has_flint then
		local flint_amount = rand:next(2, 5)
		table.insert(items, ItemStack({name = "default:flint", count = flint_amount}))
	end

	-- place items at random places in chest
	local inv = minetest.get_meta(pos):get_inventory()
	local listsz = inv:get_size("main")
	assert(listsz >= #items)
	for _, item in ipairs(items) do
		local index = rand:next(1, listsz)
		if inv:get_stack("main", index):is_empty() then
			inv:set_stack("main", index, item)
		else
			inv:add_item("main", item)
		end
	end
end

-- Measures how tall the cave is at (x,z) starting from y (air pos), returns height in nodes
local function measure_cave_height(get_node, x, y_start, z, max_scan)
	local h = 0
	for y = y_start, y_start + max_scan - 1 do
		if get_node({x=x, y=y, z=z}).name == "air" then
			h = h + 1
		else
			break
		end
	end
	return h
end

-- Returns {positions=..., large_cave_count=N} where N tall caves counted >=6 tall
local function find_cave_chest_positions(minp, maxp)
	local positions = {}
	local large_cave_positions = {}
	local get_node = minetest.get_node
	local is_solid = function(node)
		if node.name == "air" or node.name == "ignore" then
			return false
		end
		local def = minetest.registered_nodes[node.name]
		if not def then
			return true
		end
		return def.walkable ~= false
	end

	local y_start = math.min(maxp.y, -3)
	local y_end = math.max(minp.y, -31000)
	if y_start <= y_end then
		return {positions = positions, large_cave_positions = large_cave_positions}
	end

	-- Denser sampling: step 4 instead of 8, so we don't miss small-medium caves
	local step = 4
	for x = minp.x + 1, maxp.x - 1, step do
		for z = minp.z + 1, maxp.z - 1, step do
			-- scan vertically downward, find multiple floors not just one
			local floors_found_here = 0
			for y = y_start, y_end + 1, -1 do
				local feet = {x=x, y=y, z=z}
				local node = get_node(feet)
				if node.name == "air" then
					local below = get_node({x=x, y=y-1, z=z})
					if is_solid(below) then
						-- Check headroom: >=3 nodes of air above means a proper cave
						local h3 = get_node({x=x, y=y+1, z=z}).name == "air"
						local h4 = get_node({x=x, y=y+2, z=z}).name == "air"
						if h3 and h4 then
							local cave_h = 3 + measure_cave_height(get_node, x, y + 3, z, 12)
							local pos_vec = vector.new(feet)
							if cave_h >= 6 then
								-- tall/large cave
								table.insert(large_cave_positions, pos_vec)
							else
								table.insert(positions, pos_vec)
							end
							floors_found_here = floors_found_here + 1
							if floors_found_here >= 3 then
								break
							end
							-- skip a few nodes down to avoid same floor stacking
							y = y - 3
						end
					end
				end
			end
		end
	end

	return {
		positions = positions,
		large_cave_positions = large_cave_positions,
	}
end

minetest.register_on_generated(function(minp, maxp, blockseed)
	local gennotify = minetest.get_mapgen_object("gennotify")
	local poslist = gennotify["dungeon"] or {}
	local n_dungeons = #poslist
	for _, entry in ipairs(gennotify["temple"] or {}) do
		table.insert(poslist, entry)
	end

	local noise = minetest.get_perlin(10115, 4, 0.5, 1)
	local base_rand = PcgRandom(noise3d_integer(noise, {x=minp.x, y=minp.y, z=minp.z}))

	-- 1) Dungeons (engine-identified dungeons/temples) -- chests
	if #poslist > 0 then
		local rand = PcgRandom(noise3d_integer(noise, poslist[1]))

		local candidates = {}
		local num_process = math.min(#poslist, 10)
		for i = 1, num_process do
			local room = find_walls(poslist[i], i > n_dungeons)
			if math.min(room.size.x, room.size.z) >= 4 and #room.walls >= 3 then
				table.insert(candidates, room)
			end
		end

		local num_chests = rand:next(dungeon_loot.CHESTS_MIN, dungeon_loot.CHESTS_MAX)
		num_chests = math.min(#candidates, num_chests)
		local rooms = random_sample(rand, candidates, num_chests)

		for _, room in ipairs(rooms) do
			local wall = room.walls[rand:next(1, #room.walls)]
			local v, vi
			if wall.facing.x ~= 0 then
				v, vi = {x=0, y=0, z=1}, "z"
			else
				v, vi = {x=1, y=0, z=0}, "x"
			end
			local chestpos = vector.add(wall.pos, wall.facing)
			local off = rand:next(-math.floor(room.size[vi]/2) + 1, math.floor(room.size[vi]/2) - 1)
			chestpos = vector.add(chestpos, vector.multiply(v, off))

			if minetest.get_node(chestpos).name == "air" then
				local facedir = minetest.dir_to_facedir(vector.multiply(wall.facing, -1))
				minetest.add_node(chestpos, {name = "default:chest", param2 = facedir})
				populate_chest(chestpos, PcgRandom(noise3d_integer(noise, chestpos)), room.type)
			end
		end
	end

	-- 2) Caves & Large Caves (all underground chunks) -- chests
	if maxp.y < 0 and base_rand:next(0, 1000) / 1000 <= dungeon_loot.CAVE_CHEST_CHANCE then
		local cave_info = find_cave_chest_positions(minp, maxp)
		local cave_positions = cave_info.positions or {}
		local large_positions = cave_info.large_cave_positions or {}

		local function place_chests_from(list, max_n)
			if #list == 0 or max_n <= 0 then
				return
			end
			local n = math.min(#list, max_n)
			local chosen = random_sample(base_rand, list, n)
			for _, cpos in ipairs(chosen) do
				if minetest.get_node(cpos).name == "air" then
					local dtype = get_dungeon_type(cpos)
					local facedir = base_rand:next(0, 3)
					minetest.add_node(cpos, {name = "default:chest", param2 = facedir})
					populate_chest(cpos, PcgRandom(noise3d_integer(noise, cpos)), dtype)
				end
			end
		end

		-- Normal/small caves: 1 ~ CAVE_CHESTS_PER_CHUNK
		local regular_count = base_rand:next(
			math.max(1, dungeon_loot.CAVE_CHESTS_PER_CHUNK - 1),
			dungeon_loot.CAVE_CHESTS_PER_CHUNK)
		if maxp.y < -64 then
			regular_count = regular_count + 1
		end
		if maxp.y < -256 then
			regular_count = regular_count + 2
		end
		place_chests_from(cave_positions, regular_count)

		-- Large caves (>=6 nodes tall): extra chests
		local large_extra = dungeon_loot.LARGE_CAVE_CHESTS_EXTRA or 3
		if maxp.y < -128 then
			large_extra = large_extra + 1
		end
		if maxp.y < -512 then
			large_extra = large_extra + 2
		end
		place_chests_from(large_positions, large_extra)
	end
end)
