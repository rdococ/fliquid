local settings = minetest.settings

local approximateEquilibrium = settings:get_bool("fliquid_approximate_equilibrium", true)
local simulationSpeed = tonumber(settings:get("fliquid_simulation_speed") or 10)
local maxUpdatesPerSecond = tonumber(settings:get("fliquid_max_updates_per_second") or 10000)
local useMetadata = settings:get_bool("fliquid_use_metadata", true)
local performDisplacement = settings:get_bool("fliquid_displace_liquids", true)

local supportCompression = settings:get_bool("fliquid_support_compression", false)
local convertLiquids = settings:get_bool("fliquid_convert_liquids", false)

local defaults = {compressibility = 1/8, viscosity = 0, surface_tension = 1}
local fullLevel = 64

local registeredUpdateCallbacks = {}

local function id(...) return ... end

local function sign(number)
	return (number > 0 and 1) or (number == 0 and 0) or -1
end

local function getNode(posOrNode)
	if posOrNode.x ~= nil then return minetest.get_node(posOrNode), true end
	return posOrNode, false
end

local function isLiquidType(posOrNode, liquidType)
	local node = getNode(posOrNode)
	local def = minetest.registered_nodes[node.name]
	
	if not def then return false end
	if liquidType == nil then return false end
	
	return def.fliquid_type == liquidType
end

local function canFlowInto(posOrNode, liquidType)
	local node = getNode(posOrNode)
	local def = minetest.registered_nodes[node.name]
	
	if not def then return false end
	if def.liquidtype == "source" then return false end
	
	return isLiquidType(posOrNode, liquidType)
	        or minetest.get_item_group(node.name, "fliquid") < 1
	        and (not def.walkable or minetest.get_item_group(node.name, "oddly_allows_fliquid") > 0)
	        and minetest.get_item_group(node.name, "oddly_blocks_fliquid") < 1
end

local function getLiquidType(posOrNode)
	local node = getNode(posOrNode)
	local def = minetest.registered_nodes[node.name]
	
	if not def then return end
	
	return def.fliquid_type
end

local function getLiquidProperties(liquidType)
	local def = minetest.registered_nodes[liquidType]
	
	if not def then return end
	
	return def.fliquid
end

local function setLevel(pos, level, liquidType)
	if not liquidType then liquidType = getLiquidType(pos) end
	if not isLiquidType(pos, liquidType) then
		if not canFlowInto(pos, liquidType) then return level end
		
		local drops = minetest.get_node_drops(minetest.get_node(pos), "")
		for _, item in pairs(drops) do
			minetest.add_item(pos, item)
		end
		
		minetest.set_node(pos, {name = liquidType .. "_fullish"})
	end
	
	if level == 0 then
		minetest.remove_node(pos)
		return 0
	end
	
	if useMetadata then
		local meta = minetest.get_meta(pos)
		
		-- This function seems to clear metadata, so call it beforehand
		minetest.set_node_level(pos, math.min(math.ceil(level), 127))
		
		meta:set_int("use_meta", 1)
		meta:set_float("level", level)
		
		return 0
	end
	
	local excess = minetest.set_node_level(pos, math.min(level, 127))
	return excess
end

local function getLevel(posOrNode, liquidType)
	if not liquidType then liquidType = getLiquidType(posOrNode) end
	local node, wasPos = getNode(posOrNode)
	
	if not isLiquidType(posOrNode, liquidType) then return 0 end
	if not wasPos then return node.param2 end
	
	if convertLiquids and node.name == getLiquidProperties(liquidType).infinite_counterpart then
		minetest.set_node(posOrNode, {name = liquidType})
		setLevel(posOrNode, 64, liquidType)
		return 64
	end
	
	if useMetadata then
		local meta = minetest.get_meta(posOrNode)
		return meta:get_int("use_meta") > 0 and meta:get_float("level") or minetest.get_node_level(posOrNode)
	end
	
	return minetest.get_node_level(posOrNode)
end

local function addLevel(pos, level, liquidType)
	return setLevel(pos, getLevel(pos, liquidType) + level, liquidType)
end

local function takeLevel(pos, level, liquidType)
	local oldLevel = getLevel(pos, liquidType)
	local newLevel = math.max(oldLevel - level, 0)
	
	setLevel(pos, newLevel, liquidType)
	return oldLevel - newLevel
end

local getNeighbors
do
	local NESW = {{x = 0,  y = 0, z = -1}, {x = 1,  y = 0, z = 0}, {x = 0,  y = 0, z = 1}, {x = -1, y = 0, z = 0}}
	local NESWUD = {{x = 0,  y = 0,  z = -1}, {x = 1,  y = 0,  z = 0}, {x = 0,  y = 0,  z = 1}, {x = -1, y = 0,  z = 0}, {x = 0,  y = 1,  z = 0}, {x = 0,  y = -1, z = 0}}
	getNeighbors = function (pos, horizontal)
		return horizontal and
			{vector.add(pos, NESW[1]), vector.add(pos, NESW[2]), vector.add(pos, NESW[3]), vector.add(pos, NESW[4])} or 
			{vector.add(pos, NESW[1]), vector.add(pos, NESW[2]), vector.add(pos, NESW[3]), vector.add(pos, NESW[4]), vector.add(pos, NESWUD[5]), vector.add(pos, NESWUD[6])}
	end
end

local function updateLiquidState(pos, liquidType)
	if not liquidType then liquidType = getLiquidType(pos) end
	if not isLiquidType(pos, liquidType) then return end
	
	local node = minetest.get_node(pos)
	
	-- Use displayed node level here
	local myLevel = minetest.get_node_level(pos, liquidType)
	local below = vector.add(pos, {x = 0, y = -1, z = 0})
	
	if myLevel < fullLevel / 2 then
		minetest.swap_node(pos, {name = liquidType .. "_emptyish", param1 = node.param1, param2 = node.param2})
	elseif myLevel < fullLevel then
		minetest.swap_node(pos, {name = liquidType .. "_fullish", param1 = node.param1, param2 = node.param2})
	else
		minetest.swap_node(pos, {name = liquidType, param1 = node.param1, param2 = node.param2})
	end
end

local scheduleUpdate
do
	local updates, t = 0, 0

	minetest.register_globalstep(function (dtime)
		t = t + dtime
		if t >= 1 then t = 0; updates = 0 end
	end)

	scheduleUpdate = function (pos, liquidType)
		if updates >= maxUpdatesPerSecond then return end
		
		local node = minetest.get_node(pos)
		if getLiquidType(pos) and (not liquidType or isLiquidType(pos, liquidType)) then
			local timer = minetest.get_node_timer(pos)
			if not timer:is_started() then
				updates = updates + 1
				timer:start(math.floor(updates / 1000) / simulationSpeed)
			end
		end
	end
end

local function nodeChanged(pos)
	scheduleUpdate(pos)
	for _, neighbor in pairs(getNeighbors(pos, false)) do
		scheduleUpdate(neighbor)
	end
end

local function updateLiquid(pos)
	local node = minetest.get_node(pos)
	
	local liquidType = getLiquidType(pos)
	local properties = getLiquidProperties(liquidType)
	
	local compressibility = supportCompression and properties.compressibility or 0
	local flowSpeed = 1 - properties.viscosity
	local surfaceTensionLevel = properties.surface_tension * fullLevel
	
	updateLiquidState(pos, liquidType)
	
	-- Calculate these only once, because we're likely to need them
	local horizNeighbors = getNeighbors(pos, true)
	local allNeighbors = getNeighbors(pos, false)
	
	local above = allNeighbors[5]
	local below = allNeighbors[6]
	
	local oldLevel = getLevel(pos, liquidType)
	
	-- Try to give as much level to the block below as possible
	-- Retain the hardExcess (> the maximum levelled node level of 127)
	-- Goal: to get below level to full level + my level * a compressibility factor
	if canFlowInto(below, liquidType) then
		local myLevel = getLevel(pos, liquidType)
		local belowLevel = getLevel(below, liquidType)
		
		local totalVolume = myLevel + belowLevel
		--   (MaxValue * MaxValue + sum * MaxCompression) / (MaxValue + MaxCompression)
		-- local newLevel = math.max((fullLevel * fullLevel + totalVolume * compressionAmount) / (fullLevel + compressionAmount), fullLevel)
		--   belowNewLevel = fullLevel + (myNewLevel * compressibility)
		-- local newLevel = math.max((compressibility * totalVolume + fullLevel) / (compressibility + 1), fullLevel)
		--   belowNewLevel = myNewLevel * (1 + compressibility)
		local newLevel = math.max((compressibility + 1) * totalVolume / (compressibility + 2), fullLevel)
		local roundedFlow = (useMetadata and id or math.ceil)(math.min(newLevel - belowLevel, myLevel))
		
		if roundedFlow > 0 then
			local hardExcess = addLevel(below, roundedFlow, liquidType)
			setLevel(pos, myLevel + hardExcess - roundedFlow, liquidType)
			
			updateLiquidState(below, liquidType)
			updateLiquidState(pos, liquidType)
			
			-- Their water level increased, so they need to spread out
			scheduleUpdate(below, liquidType)
			-- Our water level decreased, so tell my neighbours to spread
			for _, neighbor in pairs(allNeighbors) do
				scheduleUpdate(neighbor, liquidType)
			end
		elseif roundedFlow < 0 then
			-- Whoops - they actually need to spread into us!
			scheduleUpdate(below, liquidType)
		end
	end
	
	-- If we have more than a full block of liquid, try to give the excess to the block above
	-- Retain the hardExcess (> the maximum levelled node level of 127)
	if canFlowInto(above, liquidType) then
		local myLevel = getLevel(pos, liquidType)
		local aboveLevel = getLevel(above, liquidType)
		
		local totalVolume = myLevel + aboveLevel
		--   (MaxValue * MaxValue + sum * MaxCompression) / (MaxValue + MaxCompression)
		-- local newLevel = math.min(totalVolume - ((fullLevel * fullLevel + totalVolume * compressionAmount) / (fullLevel + compressionAmount)), myLevel - fullLevel)
		--   belowNewLevel = fullLevel + (myNewLevel * compressibility)
		-- local newLevel = math.min((totalVolume - fullLevel) / (compressibility + 1), myLevel - fullLevel)
		--   aboveNewLevel = myNewLevel / (1 + compressibility)
		local newLevel = math.min(totalVolume / (compressibility + 2), myLevel - fullLevel)
		local roundedFlow = (useMetadata and id or math.floor)(math.min(newLevel - aboveLevel, myLevel - fullLevel))
		
		if roundedFlow > 0 then
			local hardExcess = addLevel(above, roundedFlow, liquidType)
			setLevel(pos, myLevel + hardExcess - roundedFlow, liquidType)
			
			updateLiquidState(above, liquidType)
			updateLiquidState(pos, liquidType)
			
			-- Their water level increased, so they need to spread out
			scheduleUpdate(above, liquidType)
			-- Our water level decreased, so tell my neighbours to spread
			for _, neighbor in pairs(allNeighbors) do
				scheduleUpdate(neighbor, liquidType)
			end
		elseif roundedFlow < 0 then
			-- Whoops - they actually need to spread into us!
			scheduleUpdate(above, liquidType)
		end
	end
	
	-- Spread into each of the neighboring nodes
	-- Make sure to take viscosity/flowSpeed into account
	do
		local spreadInto = {}
		local volume = 0
		
		local shuffle = {1, 2, 3, 4}
		
		for i = 1, 4 do
			local j = math.random(1, #shuffle)
			local neighbor = horizNeighbors[shuffle[j]]
			table.remove(shuffle, j)
			
			local neighborNode = minetest.get_node(neighbor)
			
			if canFlowInto(neighbor, liquidType) then
				local myLevel = getLevel(pos, liquidType)
				local neighborLevel = getLevel(neighbor, liquidType)
				
				local totalVolume = myLevel + neighborLevel
				-- Target: belowNewLevel = myNewlevel
				local newLevel = (myLevel + neighborLevel) / 2
				
				local fullSpeedFlow = math.min(newLevel - neighborLevel, myLevel)
				
				local roundedFlow = fullSpeedFlow * flowSpeed
				-- Randomize whether we use floor or ceil here - easy way to support "sub-level" flow speeds
				roundedFlow = (useMetadata and id or math.random(1, 2) == 1 and math.ceil or math.floor)(math.abs(roundedFlow)) * sign(roundedFlow)
				
				if (not approximateEquilibrium or math.abs(fullSpeedFlow) > (useMetadata and 0.0001 or 0.5)) then
					if fullSpeedFlow > 0 and ((getLevel(below, liquidType) > 0 or myLevel > surfaceTensionLevel) or neighborLevel > 0) then
						local hardExcess = addLevel(neighbor, roundedFlow, liquidType)
						setLevel(pos, myLevel + hardExcess - roundedFlow, liquidType)
						
						updateLiquidState(neighbor, liquidType)
						updateLiquidState(pos, liquidType)
						
						scheduleUpdate(neighbor, liquidType)
						scheduleUpdate(pos, liquidType)
						for _, aNeighbor in pairs(allNeighbors) do
							scheduleUpdate(aNeighbor, liquidType)
						end
					elseif fullSpeedFlow < 0 then
						-- Whoops - they actually need to spread into us!
						scheduleUpdate(neighbor, liquidType)
					end
				end
			end
		end
	end
	
	-- Call any hooked up callbacks
	for _, callback in pairs(registeredUpdateCallbacks) do
		callback(pos, liquidType)
	end
end

local function displaceLiquid(pos, oldLevel, oldLiquidType)
	local liquidType = oldLiquidType or getLiquidType(pos)
	local levelLeft = oldLevel or getLevel(pos, liquidType)
	
	do
		local spreadInto = {}
		local volume = 0
		
		local shuffle = {1, 2, 3, 4, 5, 6}
		
		for i = 1, 6 do
			local j = math.random(1, #shuffle)
			local neighbor = getNeighbors(pos, false)[shuffle[j]]
			table.remove(shuffle, j)
			
			if canFlowInto(neighbor, liquidType) then
				levelLeft = addLevel(neighbor, levelLeft, liquidType)
				scheduleUpdate(neighbor, liquidType)
			end
		end
	end
	
	return levelLeft
end

-- Schedule update when a node is removed
minetest.register_on_dignode(nodeChanged)

-- Do the same thing here, but only if the node placed permits flow
minetest.register_on_placenode(function (pos, newnode, placer, oldnode, itemstack, pointed_thing)
	if not canFlowInto(pos) then return end
	nodeChanged(pos)
end)

-- Hacky solution to enable liquid displacement with useMetadata = true
do
	local old_place = minetest.item_place_node
	
	function minetest.item_place_node(itemstack, placer, pointed_thing, ...)
		if not performDisplacement or pointed_thing.type ~= "node" then return old_place(itemstack, placer, pointed_thing, ...) end
		
		local above, below = pointed_thing.above, pointed_thing.under
		
		local liquidAbove, liquidBelow = getLiquidType(above), getLiquidType(below)
		local levelAbove, levelBelow = getLevel(above), getLevel(below)
		
		local itemstack, pos = old_place(itemstack, placer, pointed_thing, ...)
		
		if pos and above and vector.equals(pos, above) and liquidAbove then
			displaceLiquid(pos, levelAbove, liquidAbove)
		elseif pos and below and liquidBelow then
			displaceLiquid(pos, levelBelow, liquidBelow)
		end
		
		return itemstack, pos
	end
end

local function copy(tbl, record)
	if not record then record = {} end
	if record[tbl] then return record[tbl] end
	if type(tbl) ~= "table" then return tbl end
	
	local newtbl = {}
	record[tbl] = newtbl
	for k, v in pairs(tbl) do newtbl[k] = copy(v, record) end
	
	return newtbl
end

local function withDefaults(tbl, defs)
	if not tbl then tbl = {} end
	local defs = copy(defs)
	for k, v in pairs(defs) do
		if tbl[k] == nil then tbl[k] = defs[k] end
	end
	return tbl
end

local function registerLiquid(name, def)
	-- Properties required of all nodes generated for this liquid
	def.paramtype2 = "leveled"
	def.description = def.description or name
	def.leveled_max = def.leveled_max or 127
	def.drop = ""
	
	def.fliquid_type = name
	def.fliquid = withDefaults(def.fliquid, defaults)
	def.groups = withDefaults(def.groups, {fliquid = 1})
	
	-- Override old_on_place to set level and schedule update
	local old_on_place = def.on_place or minetest.item_place_node
	def.on_place = function (itemstack, placer, pointed_thing)
		local itemstack, pos = old_on_place(itemstack, placer, pointed_thing)
		
		if not pos then return itemstack end
		
		setLevel(pos, 64, name)
		nodeChanged(pos)
		
		return itemstack
	end
	
	-- Override the node timer entirely
	-- (we'll be triggering it anyway so it will mess up any extra timing mechanisms applied)
	def.on_timer = updateLiquid
	
	if convertLiquids and def.fliquid.infinite_counterpart then
		local infiniteSource = def.fliquid.infinite_counterpart
		local infiniteFlowing = minetest.registered_nodes[infiniteSource].liquid_alternative_flowing
		
		minetest.register_abm({
			label = "Convert infinite liquid to finite liquid upon spreading",
			
			nodenames = {infiniteFlowing},
			neighbors = {},
			
			interval = 1,
			chance = 1,
			catch_up = false,
			
			action = function (pos, node)
				minetest.set_node(pos, {name = name, param2 = 64})
				setLevel(pos, 64, name)
				nodeChanged(pos)
			end
		})
	end
	
	-- Full state - render as cube, swimmable, drownable
	-- This is what you see in the creative inventory, because its inventory image is a full cube
	local fullDef = copy(def)
	fullDef.drawtype = "liquid"
	fullDef.description = def.description
	minetest.register_node(name, fullDef)
	
	-- Mostly full state - swimmable, drownable
	local fullishDef = copy(def)
	fullishDef.drawtype = "nodebox"
	fullishDef.node_box = {type = "leveled", fixed = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}}
	fullishDef.description = def.description .. " (nearly full)"
	fullishDef.groups.not_in_creative_inventory = 1
	minetest.register_node(name .. "_fullish", fullishDef)
	
	-- Mostly empty state - unswimmable, undrownable
	local emptyishDef = copy(fullishDef)
	emptyishDef.climbable = false
	emptyishDef.drowning = nil
	emptyishDef.post_effect_color = nil
	emptyishDef.description = def.description .. " (nearly empty)"
	emptyishDef.groups.not_in_creative_inventory = 1
	minetest.register_node(name .. "_emptyish", emptyishDef)
	
	return name
end

local function updateWrapper(func)
	return function (pos, ...)
		local result = func(pos, ...)
		nodeChanged(pos)
		
		return result
	end
end

local function registerOnUpdate(f)
	table.insert(registeredUpdateCallbacks, f)
end

fliquid = {
	changed         = nodeChanged,
	
	schedule        = scheduleUpdate,
	update          = updateLiquid,
	
	get_neighbors   = getNeighbors,
	
	is_liquid_type  = isLiquidType,
	get_liquid_type = getLiquidType,
	
	full_level      = fullLevel,
	
	get_level       = updateWrapper(getLevel),
	set_level       = updateWrapper(setLevel),
	add_level       = updateWrapper(addLevel),
	take_level      = updateWrapper(takeLevel),
	
	displace = displaceLiquid,
	
	register_liquid = registerLiquid,
	register_on_update = registerOnUpdate,
}