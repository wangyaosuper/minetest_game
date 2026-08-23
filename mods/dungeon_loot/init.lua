dungeon_loot = {}

dungeon_loot.CHESTS_MIN = 6
dungeon_loot.CHESTS_MAX = 9
dungeon_loot.STACKS_PER_CHEST_MAX = 8
dungeon_loot.CAVE_CHESTS_PER_CHUNK = 3
dungeon_loot.LARGE_CAVE_CHESTS_EXTRA = 4
dungeon_loot.CAVE_CHEST_CHANCE = 1.0

dofile(minetest.get_modpath("dungeon_loot") .. "/loot.lua")
dofile(minetest.get_modpath("dungeon_loot") .. "/mapgen.lua")
