
-- 注册一个名为 my_monster:stone_golem 的攻击性生物
mobs:register_mob("my_monster:hungry", {
	-- 1. 基本属性
	nametag = "饥饿的怪物",             -- 生物头顶显示的名字
	type = "monster",            -- 【核心】类型为"monster"，会主动攻击玩家和NPC
	passive = false,             -- 为false表示它会主动攻击，而非被动反击
	hp_min = 15,                 -- 最小生命值
	hp_max = 25,                 -- 最大生命值 (生成时随机)
	armor = 80,                  -- 护甲值，100为无护甲，越低护甲越高
	damage = 4,                  -- 每次近战攻击造成的伤害点数

	-- 2. 外观与物理
	visual = "mesh",             -- 使用3D模型
	visual_size = {x = 1, y = 1},-- 模型大小
	mesh = "hungry.b3d",-- 模型文件 (你需要在models文件夹中提供)
	textures = {                 -- 材质贴图
		"hungry.png",  -- 你需要提供这张图片文件
	},
	spawn = {
		spawn_chance = 0.9,
		active_object_count = 10,
		ymin = 0, 
		ymax = 31000,
		biomes = {"grassland", "coniferous_forest"}
	},
	collisionbox = {-0.5, -1.0, -0.5, 0.5, 0.8, 0.5}, -- 碰撞箱大小
	makes_footstep_sound = true, -- 是否发出脚步声

	-- 3. 移动与行为
	walk_velocity = 1,           -- 走路速度
	run_velocity = 3,            -- 追击玩家时的跑步速度
	jump = true,                 -- 允许跳跃
	jump_height = 1,             -- 跳跃高度
	view_range = 10,             -- 视线范围 (能看到多远的玩家)
	attack_type = "dogfight",    -- 攻击类型为近战"缠斗"
	reach = 3,                   -- 近战攻击距离
	group_attack = true,         -- 同类生物会互相帮助，共同攻击目标

	-- 4. 其他特性
	knock_back = true,           -- 被攻击时会后退
	fall_damage = true,          -- 会受到摔落伤害
	water_damage = 2,            -- 在水中每秒受到2点伤害
	lava_damage = 8,             -- 在岩浆中每秒受到8点伤害
	light_damage = 0,            -- 不受到光照伤害
	spawn_on = {"default:stone", "default:cobble","default:grassland", "default:coniferous_forest"}, -- 会在石头和圆石上生成

	-- 5. 回调函数 (可选，用于更高级的行为)
	on_spawn = function(self)
		-- 在生物生成时执行，比如可以在这里设置属性
		-- 返回 true 表示此函数只会运行一次
		return true
	end,
	do_custom = function(self, dtime)
		-- 在每个服务器刻都会执行，用于实现高度自定义的逻辑
		-- 例如：检查身边环境，释放特殊技能等
	end,
})


mobs:spawn({
	name = "my_monster:hungry",
	nodes = {
		"default:snow", "default:ice", "default:stone",
		"default:dry_dirt_with_dry_grass", "ethereal:dry_dirt",
		"default:stone", "default:cobble","default:grassland", "default:coniferous_forest"
	},
	chance = 1,
	min_height = 0,
	active_object_count = 10,
})