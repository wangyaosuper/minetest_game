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
					local wear = rand:next(0.20 * 65535, 0.75 * 65535)
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

-- Walkable floor that is not air/ignore, with reasonable fall-back definition
local function node_is_floor(node)
	if not node or node.name == "air" or node.name == "ignore" then
		return false
	end
	local def = minetest.registered_nodes[node.name]
	if not def then
		return true
	end
	if def.walkable == false then
		return false
	end
	return true
end

-- Measures how tall the cave is at (x,z) starting from a known-air feet position
local function measure_cave_height(get_node, x, y_start, z, max_scan)
	local h = 0
	for y = y_start, y_start + max_scan - 1 do
		local n = get_node({x=x, y=y, z=z})
		if n and n.name == "air" then
			h = h + 1
		else
			break
		end
	end
	return h
end

-- Scan a rectangular area (within a chunk or around a player) to find cave floors.
-- Returns {positions=regular_cave_floors, large_cave_positions=tall_cave_floors}
-- If rand is provided it picks random offset to avoid sampling same pattern each chunk.
local function find_cave_chest_positions(minp, maxp, rand)
	local positions = {}
	local large_cave_positions = {}
	local get_node = minetest.get_node
	local voxelmanip
	local va

	-- For performance, use VoxelManip if the region is larger than 6400 nodes
	local volume = (maxp.x - minp.x + 1) * (maxp.y - minp.y + 1) * (maxp.z - minp.z + 1)
	local use_vm = volume > 6400
	if use_vm then
		local ok, vm = pcall(minetest.get_voxel_manip)
		if ok and vm then
			voxelmanip = vm
			local e1, e2 = voxelmanip:read_from_map(minp, maxp)
			if e1 and e2 then
				va = VoxelArea:new({MinEdge=e1, MaxEdge=e2})
				local data = voxelmanip:get_data()
				local c_air = minetest.get_content_id("air")
				get_node = function(p)
					if not va:containsp(p.x, p.y, p.z) then
						return {name="ignore"}
					end
					local id = data[va:index(p.x, p.y, p.z)]
					if id == c_air then
						return {name="air"}
					else
						return {name="unknown"}
					end
				end
				node_is_floor = function(node)
					if not node or node.name == "air" or node.name == "ignore" then
						return false
					end
					return true
				end
			else
				use_vm = false
				get_node = minetest.get_node
			end
		else
			use_vm = false
		end
	end

	local y_top_scan = math.min(maxp.y, 5)
	local y_bot_scan = math.max(minp.y, -31000)
	if y_top_scan <= y_bot_scan then
		return {positions = positions, large_cave_positions = large_cave_positions}
	end

	local step = 3
	local x_start = minp.x + 1
	local x_stop = maxp.x - 1
	local z_start = minp.z + 1
	local z_stop = maxp.z - 1

	if rand then
		local off = rand:next(0, step - 1)
		x_start = x_start + off
		z_start = z_start + rand:next(0, step - 1)
	end

	for x = x_start, x_stop, step do
		for z = z_start, z_stop, step do
			-- Scan DOWNWARD: look for an air node where node BELOW is floor
			local floors_found_here = 0
			local y = y_top_scan
			while y > y_bot_scan do
				local feet = {x=x, y=y, z=z}
				local feet_node = get_node(feet)
				if feet_node.name == "air" then
					-- Check if below is a walkable floor
					local below = get_node({x=x, y=y-1, z=z})
					if node_is_floor(below) then
						-- Check headroom: feet+1 and feet+2 must both be air (3 nodes tall total)
						local h1 = get_node({x=x, y=y+1, z=z}).name == "air"
						local h2 = get_node({x=x, y=y+2, z=z}).name == "air"
						if h1 and h2 then
							local cave_h = 3 + measure_cave_height(get_node, x, y + 3, z, 18)
							local pos_vec = vector.new(feet)
							if cave_h >= 6 then
								table.insert(large_cave_positions, pos_vec)
							else
								table.insert(positions, pos_vec)
							end
							floors_found_here = floors_found_here + 1
							if floors_found_here >= 4 then
								break
							end
							y = y - 5
						else
							y = y - 1
						end
					else
						y = y - 1
					end
				else
					-- Not air, keep scanning down
					y = y - 1
				end
			end
		end
	end

	return {
		positions = positions,
		large_cave_positions = large_cave_positions,
	}
end

-- Place a chest block at the given position with populated loot, checking that
-- the position is still air, and there's a floor underneath.
local function try_place_chest(cpos, rand_or_seed)
	if not cpos or cpos.y >= 0 then
		return false
	end
	local node_feet = minetest.get_node(cpos)
	if node_feet.name ~= "air" then
		return false
	end
	local below = minetest.get_node({x=cpos.x, y=cpos.y-1, z=cpos.z})
	if not node_is_floor(below) then
		return false
	end
	-- Make sure there's at least 2 nodes of headroom
	if minetest.get_node({x=cpos.x, y=cpos.y+1, z=cpos.z}).name ~= "air" then
		return false
	end
	local noise = minetest.get_perlin(10115, 4, 0.5, 1)
	local seed_int = type(rand_or_seed) == "number" and rand_or_seed
		or noise3d_integer(noise, cpos)
	local rand = PcgRandom(seed_int)

	local facedir = rand:next(0, 3)
	minetest.add_node(cpos, {name = "default:chest", param2 = facedir})
	populate_chest(cpos, rand, get_dungeon_type(cpos))
	return true
end

minetest.register_on_generated(function(minp, maxp, blockseed)
	local gennotify = minetest.get_mapgen_object("gennotify")
	local poslist = gennotify["dungeon"] or {}
	local n_dungeons = #poslist
	for _, entry in ipairs(gennotify["temple"] or {}) do
		table.insert(poslist, entry)
	end

	local noise = minetest.get_perlin(10115, 4, 0.5, 1)
	local base_rand = PcgRandom(noise3d_integer(noise, {x=minp.x, y=minp.y, z=minp.z}) + (blockseed or 0))

	-- 1) Dungeons (engine-identified dungeons/temples) -- chests
	if #poslist > 0 then
		local rand = PcgRandom(noise3d_integer(noise, poslist[1]) + (blockseed or 0))

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

	-- 2) Caves & Large Caves (every single underground chunk) -- chests
	if maxp.y < 10 then
		local chance_ok = dungeon_loot.CAVE_CHEST_CHANCE >= 1.0
			or base_rand:next(0, 1000) / 1000 <= dungeon_loot.CAVE_CHEST_CHANCE
		if chance_ok then
			local cave_info = find_cave_chest_positions(minp, maxp, base_rand)
			local cave_positions = cave_info.positions or {}
			local large_positions = cave_info.large_cave_positions or {}

			local function place_chests_from(list, max_n)
				if not list or #list == 0 or max_n <= 0 then
					return 0
				end
				local n = math.min(#list, max_n)
				local chosen = random_sample(base_rand, list, n)
				local placed = 0
				for _, cpos in ipairs(chosen) do
					if try_place_chest(cpos, nil) then
						placed = placed + 1
					end
				end
				return placed
			end

			-- Regular/small caves
			local regular_count = base_rand:next(
				math.max(1, dungeon_loot.CAVE_CHESTS_PER_CHUNK - 1),
				dungeon_loot.CAVE_CHESTS_PER_CHUNK)
			if maxp.y < -64 then
				regular_count = regular_count + 2
			end
			if maxp.y < -256 then
				regular_count = regular_count + 3
			end
			place_chests_from(cave_positions, regular_count)

			-- Large caves (>=6 nodes tall): extra chests
			local large_extra = dungeon_loot.LARGE_CAVE_CHESTS_EXTRA or 4
			if maxp.y < -128 then
				large_extra = large_extra + 2
			end
			if maxp.y < -512 then
				large_extra = large_extra + 3
			end
			place_chests_from(large_positions, large_extra)
		end
	end
end)

-- ============================================================
-- LBM + ABM: Place chests in already-generated cave chunks that
--            were generated before this mod was added/enabled.
-- ============================================================

-- Remember which block positions we've already seeded with chests so we
-- don't attempt to place chests in them repeatedly.
local SEEN_KEY = "dungeon_loot:cave_seeded"
if not dungeon_loot._seeded_blocks then
	dungeon_loot._seeded_blocks = {}
end

-- Map block hash
local function mb_hash(x, y, z)
	return (x + 32768) * 65537 ^ 2 + (y + 32768) * 65537 + (z + 32768)
end

local function maybe_seed_cave_area(minp, maxp)
	local h = mb_hash(math.floor(minp.x/16), math.floor(minp.y/16), math.floor(minp.z/16))
	if dungeon_loot._seeded_blocks[h] then
		return
	end
	dungeon_loot._seeded_blocks[h] = true

	if maxp.y > -1 and minp.y >= 0 then
		return
	end

	local noise = minetest.get_perlin(10115, 4, 0.5, 1)
	local base_rand = PcgRandom(noise3d_integer(noise, minp) + h)

	local chance_ok = dungeon_loot.CAVE_CHEST_CHANCE >= 1.0
		or base_rand:next(0, 1000) / 1000 <= dungeon_loot.CAVE_CHEST_CHANCE
	if not chance_ok then
		return
	end

	local cave_info = find_cave_chest_positions(minp, maxp, base_rand)
	local cave_positions = cave_info.positions or {}
	local large_positions = cave_info.large_cave_positions or {}

	local function place_subset(list, max_n)
		if not list or #list == 0 or max_n <= 0 then
			return
		end
		local n = math.min(#list, max_n)
		local chosen = random_sample(base_rand, list, n)
		for _, cpos in ipairs(chosen) do
			try_place_chest(cpos, nil)
		end
	end

	local regular_count = base_rand:next(
		math.max(1, dungeon_loot.CAVE_CHESTS_PER_CHUNK - 1),
		dungeon_loot.CAVE_CHESTS_PER_CHUNK)
	if maxp.y < -64 then regular_count = regular_count + 2 end
	if maxp.y < -256 then regular_count = regular_count + 3 end
	place_subset(cave_positions, regular_count)

	local large_extra = dungeon_loot.LARGE_CAVE_CHESTS_EXTRA or 4
	if maxp.y < -128 then large_extra = large_extra + 2 end
	if maxp.y < -512 then large_extra = large_extra + 3 end
	place_subset(large_positions, large_extra)
end

-- ABM: whenever a player walks around stone/cobble floors underground, if
-- that area has not yet been seeded for cave chests, seed it now.
minetest.register_abm({
	label = "dungeon_loot: cave chest seeder (existing chunks)",
	nodenames = {"group:stone", "group:cracky", "default:cobble",
		"default:mossycobble", "default:desert_cobble"},
	neighbors = {"air"},
	interval = 17,
	chance = 120,
	catch_up = false,
	action = function(pos, node)
		if pos.y >= -2 then
			return
		end
		-- Only seed when a player is relatively close
		local any_nearby = false
		for _, p in ipairs(minetest.get_connected_players()) do
			if vector.distance(p:get_pos(), pos) < 48 then
				any_nearby = true
				break
			end
		end
		if not any_nearby then
			return
		end
		-- Run seeding over an 80-node region around this floor position,
		-- clamped downwards to avoid scanning the sky.
		local r = 40
		local cx = math.floor(pos.x / 16) * 16
		local cy = math.max(math.floor(pos.y / 16) * 16 - 16, -3000)
		local cz = math.floor(pos.z / 16) * 16
		maybe_seed_cave_area(
			{x=cx - r, y=math.min(cy - 8, -10), z=cz - r},
			{x=cx + r, y=cy + 32, z=cz + r})
	end,
})

-- Server admin command: seed the whole area around you (or specified radius)
-- with cave chests, useful for instantly populating already-explored caves.
minetest.register_chatcommand("seedcavechests", {
	description = "Place cave chests in an 80-node radius (or specify N) around you",
	params = "[radius]",
	privs = {server = true},
	func = function(name, param)
		local player = minetest.get_player_by_name(name)
		if not player then
			return false, "Player not found"
		end
		local r = tonumber(param) or 80
		r = math.max(8, math.min(500, r))
		local p = player:get_pos()
		local minp = {x = math.floor(p.x - r), y = math.max(math.floor(p.y - r), -8000), z = math.floor(p.z - r)}
		local maxp = {x = math.floor(p.x + r), y = math.min(math.floor(p.y + r), -1), z = math.floor(p.z + r)}

		local noise = minetest.get_perlin(10115, 4, 0.5, 1)
		local base_rand = PcgRandom(noise3d_integer(noise, minp) + os.time())

		local cave_info = find_cave_chest_positions(minp, maxp, base_rand)
		local cave_positions = cave_info.positions or {}
		local large_positions = cave_info.large_cave_positions or {}

		local placed = 0
		local target_reg = math.ceil(#cave_positions * 0.5)
		local target_large = math.ceil(#large_positions * 0.8)

		for _, cpos in ipairs(random_sample(base_rand, cave_positions, target_reg)) do
			if try_place_chest(cpos, nil) then placed = placed + 1 end
		end
		for _, cpos in ipairs(random_sample(base_rand, large_positions, target_large)) do
			if try_place_chest(cpos, nil) then placed = placed + 1 end
		end

		return true, ("Scanned %d regular + %d large cave floors, placed %d chests."):format(
			#cave_positions, #large_positions, placed)
	end,
})
