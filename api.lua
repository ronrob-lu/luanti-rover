-- Moon Rover public API, shared configuration, animation helper, and extension hooks
-- Copyright (c) 2026 ronrob-lu (MIT License)

local core = rawget(_G, "core") or minetest
local modname = core.get_current_modname() or "moon_rover"
local modpath = core.get_modpath(modname) or "."

moon_rover = {
	modname = modname,
	modpath = modpath,
	S = (core.get_translator and core.get_translator(modname)) or function(s) return s end,
}

-- Continuous glTF tire-rotation timeline (seconds, LINEAR interpolation)
moon_rover.wheel_anim = {
	idle = {x = 0.0, y = 0.0},
	forward = {x = 0.0, y = 1.0},
	reverse = {x = 1.2, y = 2.2},
}

-- Tunable drivable Moon Rover (Quaternius) configuration
moon_rover.config = {
	-- Visual & model alignment
	mesh = "moon_rover.glb",
	textures = {"moon_rover_atlas.png"},
	visual_size = {x = 1, y = 1, z = 1},
	model_yaw_offset = 0,
	wheel_circumference = 2.57,   -- nodes per full wheel revolution (r ~ 0.41n)

	-- Physical bounds (in nodes; wheel bottoms rest at y = 0)
	collisionbox = {-1.0, 0.0, -1.0, 1.0, 1.85, 1.0},
	selectionbox = {-1.25, 0.0, -1.25, 1.25, 2.1, 1.25, rotate = true},
	stepheight = 1.15,            -- climbs 1-block obstacles cleanly
	gravity = 9.81,

	-- Driving & steering feel
	max_speed = 8.0,              -- nodes/s forward
	max_reverse_speed = 3.5,      -- nodes/s reverse
	max_water_speed = 2.0,        -- nodes/s when submerged in liquid
	acceleration = 6.5,           -- nodes/s^2 forward throttle
	reverse_acceleration = 4.5,   -- nodes/s^2 reverse throttle
	brake_deceleration = 14.0,    -- nodes/s^2 active braking / handbrake
	rolling_drag = 3.5,           -- nodes/s^2 coasting deceleration
	unoccupied_drag = 8.0,        -- nodes/s^2 deceleration without driver
	water_drag = 10.0,            -- nodes/s^2 drag in liquid
	turn_speed = 1.8,             -- rad/s steering while driving
	pivot_turn_speed = 1.1,       -- rad/s in-place skid-steer when stopped

	-- Driver seat & camera offsets (Luanti 1/10-node attachment/eye units)
	seat_position = {x = 0, y = 5, z = 2},
	seat_rotation = {x = 0, y = 0, z = 0},    -- model & driver both face Luanti +Z forward
	eye_offset_first = {x = 0, y = 2, z = 0},
	eye_offset_third_back = {x = 0, y = 8, z = -5},
	eye_offset_third_front = {x = 0, y = 8, z = 5},
	board_cooldown = 0.35,        -- seconds before sneak can dismount
}

-- Tunable Autonomous Moon Rover (Kenney.nl) configuration
moon_rover.auto_config = {
	mesh = "moon_rover_auto.glb",
	textures = {"moon_rover_auto_atlas.png"},
	visual_size = {x = 1, y = 1, z = 1},
	model_yaw_offset = 0,
	wheel_circumference = 1.09,   -- nodes per full wheel revolution (r ~ 0.173n)

	collisionbox = {-0.55, 0.0, -0.55, 0.55, 1.45, 0.55},
	selectionbox = {-0.65, 0.0, -0.65, 0.65, 1.55, 0.65, rotate = true},
	stepheight = 1.15,            -- climbs 1-block obstacles cleanly
	gravity = 9.81,

	-- Autonomous movement & gathering
	drive_speed = 2.8,            -- nodes/s autonomous cruising speed
	turn_speed = 2.4,             -- rad/s autonomous turn rate
	scan_radius = 8,              -- horizontal search radius (nodes)
	scan_height_down = 1,         -- vertical scan range below rover
	scan_height_up = 5,           -- vertical scan range above rover (trees/cliff ores)
	scan_interval = 1.0,          -- seconds between world scans
	gather_reach_xz = 2.5,        -- horizontal dig reach
	gather_reach_y = 4.5,         -- vertical dig reach (for chopping tree trunks)
	dig_time_base = 0.55,         -- base seconds to dig a block
	pickup_radius = 2.6,          -- dropped item vacuum radius
	craft_interval = 1.2,         -- seconds between crafting/replication checks
	stuck_timeout = 2.5,          -- seconds without progress before switching target

	-- Inventory & self-replication limits
	chest_size = 64,              -- 64-slot chest (8x8)
	target_sticks = 16,           -- keeps sticks stocked from chopped trees
	max_nearby_rovers = 8,        -- local density cap to prevent runaway lag
	nearby_rover_radius = 32,     -- radius for local density check
}

-- Active driver lookup: [player_name] = rover_luaentity
moon_rover._active_drivers = {}

-- Extension hooks for modular rover capabilities
moon_rover._hooks = {
	on_activate = {},
	on_step = {},
	on_board = {},
	on_dismount = {},
	on_rightclick = {},
	on_punch = {},
	on_get_staticdata = {},
}

function moon_rover.register_hook(event, fn)
	assert(type(fn) == "function", "moon_rover.register_hook expects a function")
	local list = moon_rover._hooks[event]
	if not list then
		error("Unknown moon_rover hook event: " .. tostring(event))
	end
	list[#list + 1] = fn
end

function moon_rover.run_hooks(event, ...)
	local list = moon_rover._hooks[event]
	if not list then
		return nil
	end
	for i = 1, #list do
		local res = list[i](...)
		if res ~= nil then
			return res
		end
	end
	return nil
end

function moon_rover.get_rover_for_player(player_name)
	return moon_rover._active_drivers[player_name]
end

function moon_rover.normalize_yaw(yaw)
	local two_pi = math.pi * 2
	yaw = yaw % two_pi
	if yaw > math.pi then
		yaw = yaw - two_pi
	end
	return yaw
end

function moon_rover.yaw_to_forward(yaw)
	return {x = -math.sin(yaw), y = 0, z = math.cos(yaw)}
end

function moon_rover.yaw_to_right(yaw)
	return {x = math.cos(yaw), y = 0, z = math.sin(yaw)}
end

-- Cross-version atan2 (LuaJIT/5.1 math.atan2 and Lua 5.3+ 2-arg math.atan)
moon_rover.atan2 = math.atan2 or math.atan

-- Drive the continuous glTF tire-rotation animation proportionally to ground speed.
-- Uses set_animation on direction/mode transitions and set_animation_frame_speed
-- when speed changes smoothly so tire phase never resets mid-roll.
function moon_rover.update_wheel_animation(self, speed, wheel_circumference)
	local obj = self.object
	if not obj or not obj.set_animation then
		return
	end

	local circ = (wheel_circumference and wheel_circumference > 0) and wheel_circumference or 2.0
	local abs_speed = math.abs(speed or 0)

	local mode
	local anim_speed = 0.0
	if abs_speed < 0.08 then
		mode = "idle"
		anim_speed = 0.0
	elseif speed > 0 then
		mode = "forward"
		anim_speed = math.max(0.15, abs_speed / circ)
	else
		mode = "reverse"
		anim_speed = math.max(0.15, abs_speed / circ)
	end

	if self._anim_mode ~= mode then
		self._anim_mode = mode
		self._anim_speed = anim_speed
		local range = moon_rover.wheel_anim[mode]
		obj:set_animation(range, anim_speed, 0.0, mode ~= "idle")
	elseif mode ~= "idle" and math.abs((self._anim_speed or 0) - anim_speed) >= 0.15 then
		self._anim_speed = anim_speed
		if obj.set_animation_frame_speed then
			obj:set_animation_frame_speed(anim_speed)
		else
			obj:set_animation(moon_rover.wheel_anim[mode], anim_speed, 0.0, true)
		end
	end
end
