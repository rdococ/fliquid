minetest.register_node("fliquid:sponge", {
	description = "Fsponge",
	tiles = {"default_dirt.png^[colorize:#ffff00:128"},
	groups = {crumbly = 3, soil = 1, fsponge = 1, fliquid_active = 1},
	sounds = default.node_sound_dirt_defaults()
})

fliquid.register_on_update(function (pos, liquidType)
	if not fliquid.get_liquid_type(pos) then return end
	
	local neighbors = fliquid.get_neighbors(pos)
	
	for _, neighbor in pairs(neighbors) do
		if minetest.get_item_group(minetest.get_node(neighbor).name, "fsponge") > 0 then
			fliquid.set_level(pos, 0)
			return
		end
	end
end)

minetest.register_node("fliquid:spring", {
	description = "Fspring",
	tiles = {"default_dirt.png^[colorize:#00ffff:128"},
	groups = {crumbly = 3, soil = 1, fspring = 1},
	sounds = default.node_sound_dirt_defaults()
})

minetest.register_abm({
	label = "Fliquid springs",
	
	nodenames = {"group:fspring"},
	
	interval = 1,
	chance = 1,
	
	action = function (pos)
		local neighbors = fliquid.get_neighbors(pos)
	
		for _, neighbor in pairs(neighbors) do
			if fliquid.can_flow_into(neighbor, "fliquid:water") then
				fliquid.add_level(neighbor, fliquid.full_level, "fliquid:water")
			end
		end
	end
})

fliquid.register_liquid("fliquid:very_compressible", {
	description = "Finite Very Compressible Liquid",
	
	tiles = {
		{
			name = "default_lava_source_animated.png^[colorize:#ff00ff:128",
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
	
	walkable = false,
	pointable = false,
	climbable = true,
	buildable_to = true,
	
	drowning = 1,
	post_effect_color = {a = 103, r = 255, g = 0, b = 255},
	
	fliquid = {
		compressibility = 2,
		viscosity = 0,
		surface_tension = 1/32
	}
})

fliquid.register_liquid("fliquid:very_viscous", {
	description = "Finite Very Viscous Liquid",
	
	tiles = {
		{
			name = "default_lava_source_animated.png^[colorize:#00ff00:128",
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
	
	walkable = false,
	pointable = false,
	climbable = true,
	buildable_to = true,
	
	drowning = 1,
	post_effect_color = {a = 103, r = 0, g = 255, b = 0},
	
	fliquid = {
		compressibility = 1/4,
		viscosity = 0.95,
		surface_tension = 1/2
	}
})