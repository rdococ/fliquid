local settings = minetest.settings
local convertLiquids = settings:get_bool("fliquid_convert_liquids", false)

fliquid.register_liquid("fliquid:water", {
	description = "Finite Water",
	
	tiles = {
		{
			name = "default_water_source_animated.png",
			backface_culling = false,
			animation = {
				type = "vertical_frames",
				aspect_w = 16,
				aspect_h = 16,
				length = 2.0,
			},
		}
	},
	
	paramtype = "light",
	use_texture_alpha = "blend",
	
	groups = {water = 3, cools_lava = 1, puts_out_fire = 1},
	
	walkable = false,
	pointable = false,
	climbable = true,
	buildable_to = true,
	
	drowning = 1,
	post_effect_color = {a = 103, r = 66, g = 55, b = 90},
	
	fliquid = {
		compressibility = 1/8,
		viscosity = 0,
		surface_tension = 1/64,
		infinite_counterpart = "default:water_source",
	}
})

fliquid.register_liquid("fliquid:lava", {
	description = "Finite Lava",
	
	tiles = {
		{
			name = "default_lava_source_animated.png",
			backface_culling = false,
			animation = {
				type = "vertical_frames",
				aspect_w = 16,
				aspect_h = 16,
				length = 2.0,
			},
		}
	},
	
	paramtype = "light",
	light_source = default.LIGHT_MAX - 1,
	
	use_texture_alpha = "blend",
	
	groups = {finite_lava = 1, lava = 3, igniter = 1},
	
	walkable = false,
	pointable = false,
	climbable = true,
	buildable_to = true,
	
	drowning = 1,
	damage_per_second = 4 * 2,
	post_effect_color = {a = 191, r = 255, g = 64, b = 0},
	
	fliquid = {
		compressibility = 1/16,
		viscosity = 0.75,
		surface_tension = 1/4,
		infinite_counterpart = "default:lava_source",
	}
})

if minetest.settings:get_bool("enable_lavacooling") ~= false then
	minetest.register_abm({
		label = "Lava cooling",
		nodenames = {"group:finite_lava"},
		neighbors = {"group:cools_lava", "group:water"},
		interval = 1,
		chance = 1,
		catch_up = false,
		action = function (pos, node)
			local oldLevel = fliquid.get_level(pos)
			local levelLeft = oldLevel
			
			for _, neighbor in pairs(fliquid.get_neighbors(pos)) do
				if fliquid.is_liquid_type(neighbor, "fliquid:water") then
					-- One block of water is needed to cool one block of lava
					levelLeft = levelLeft - fliquid.take_level(neighbor, fliquid.full_level)
				else
					local neighborName = minetest.get_node(neighbor).name
					
					if minetest.get_item_group(neighborName, "group:cools_lava") > 0 or minetest.get_item_group(neighborName, "group:water") > 0 then
						-- Other cools_lava blocks are currently counted as one full block
						levelLeft = levelLeft - fliquid.full_level
					end
				end
			end
			
			if levelLeft <= 0 then
				-- If the oldLevel was >= fullLevel, become obsidian, otherwise just become stone
				minetest.set_node(pos, {name = (oldLevel >= fliquid.full_level and "default:obsidian" or "default:stone")})
				fliquid.changed(pos)
			else
				fliquid.set_level(pos, levelLeft)
			end
		end,
	})
end