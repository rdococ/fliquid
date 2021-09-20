local settings = minetest.settings
local experimentalBlocks = settings:get_bool("fliquid_experimental_blocks", false)

local MP = minetest.get_modpath(minetest.get_current_modname())

dofile(MP .. "/core.lua")

if minetest.get_modpath("default") then
	dofile(MP .. "/default.lua")
end

if experimentalBlocks then
	dofile(MP .. "/experimental.lua")
end