-- Moon Rover mod for Luanti
-- Copyright (c) 2026 ronrob-lu (MIT License)
-- 3D models by Quaternius & Kenney.nl (CC0 1.0 Universal)

local core = rawget(_G, "core") or minetest
local modpath = core.get_modpath(core.get_current_modname() or "moon_rover") or "."

dofile(modpath .. "/api.lua")
dofile(modpath .. "/entity.lua")
dofile(modpath .. "/auto_rover.lua")
dofile(modpath .. "/craft.lua")
