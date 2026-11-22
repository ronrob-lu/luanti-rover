-- Drivable Moon Rover entity definition (Quaternius CC0 model)
-- Copyright (c) 2026 ronrob-lu (MIT License)

local core = rawget(_G, "core") or minetest
local S = moon_rover.S

local function get_player_api()
	return rawget(_G, "player_api")
end

local function move_towards(current, target, max_delta)
	if current < target then
		return math.min(current + max_delta, target)
	elseif current > target then
		return math.max(current - max_delta, target)
	end
	return target
end

local function get_drive_yaw(self)
	local offset = moon_rover.config.model_yaw_offset or 0
	return moon_rover.normalize_yaw((self.object:get_yaw() or 0) - offset)
end

local function set_drive_yaw(self, yaw)
	local offset = moon_rover.config.model_yaw_offset or 0
	self.object:set_yaw(moon_rover.normalize_yaw(yaw + offset))
end

local function is_node_walkable(pos)
	local node = core.get_node_or_nil(pos)
	if not node then
		return true
	end
	local def = core.registered_nodes[node.name]
	if not def then
		return true
	end
	return def.walkable == true
end

local function is_in_liquid(pos)
	local sample = {x = pos.x, y = pos.y + 0.35, z = pos.z}
	local node = core.get_node_or_nil(sample)
	if not node then
		return false
	end
	local def = core.registered_nodes[node.name]
	return def ~= nil and def.liquidtype ~= nil and def.liquidtype ~= "none"
end

local function has_headroom(pos)
	local feet = {x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5), z = math.floor(pos.z + 0.5)}
	local head = {x = feet.x, y = feet.y + 1, z = feet.z}
	return not is_node_walkable(feet) and not is_node_walkable(head)
end

local function find_dismount_pos(pos, yaw)
	local fwd = moon_rover.yaw_to_forward(yaw)
	local right = moon_rover.yaw_to_right(yaw)

	local candidates = {
		{x = pos.x + right.x * 1.7, y = pos.y + 0.2, z = pos.z + right.z * 1.7},
		{x = pos.x - right.x * 1.7, y = pos.y + 0.2, z = pos.z - right.z * 1.7},
		{x = pos.x - fwd.x * 2.0,   y = pos.y + 0.2, z = pos.z - fwd.z * 2.0},
		{x = pos.x + fwd.x * 2.0,   y = pos.y + 0.2, z = pos.z + fwd.z * 2.0},
	}

	for i = 1, #candidates do
		if has_headroom(candidates[i]) then
			return candidates[i]
		end
	end

	-- Fallback: place driver cleanly above the cabin roof
	return {x = pos.x, y = pos.y + 2.0, z = pos.z}
end

local function compute_seat_transform()
	local cfg = moon_rover.config
	local sp = cfg.seat_position
	local sr = cfg.seat_rotation or {x = 0, y = 0, z = 0}
	local offset = cfg.model_yaw_offset or 0
	local rot_y = (sr.y - math.deg(offset)) % 360

	if offset == 0 then
		return {x = sp.x, y = sp.y, z = sp.z}, {x = sr.x, y = rot_y, z = sr.z}
	end
	local c = math.cos(-offset)
	local s = math.sin(-offset)
	local rx = sp.x * c - sp.z * s
	local rz = sp.x * s + sp.z * c
	return {x = rx, y = sp.y, z = rz}, {x = sr.x, y = rot_y, z = sr.z}
end

local function has_blocking_horizontal_collision(moveresult)
	if not moveresult or not moveresult.collides then
		return false
	end
	local collisions = moveresult.collisions
	if type(collisions) ~= "table" then
		-- Simple mock/fallback moveresult without detailed collisions list
		return true
	end
	for i = 1, #collisions do
		local c = collisions[i]
		if c.axis == "x" or c.axis == "z" then
			-- Ignore collisions where stepheight lifted the rover onto a 1-block obstacle
			local old_y = c.old_pos and c.old_pos.y or 0
			local new_y = c.new_pos and c.new_pos.y or 0
			if new_y <= old_y + 0.05 then
				return true
			end
		end
	end
	return false
end

function moon_rover.board(self, player)
	if not player or not player:is_player() then
		return false
	end
	if self.driver then
		return false
	end
	if player:get_attach() then
		return false
	end

	local name = player:get_player_name()
	if moon_rover._active_drivers[name] then
		return false
	end

	local cfg = moon_rover.config
	local seat_pos, seat_rot = compute_seat_transform()

	self.driver = name
	self._board_cooldown = cfg.board_cooldown
	moon_rover._active_drivers[name] = self

	player:set_attach(self.object, "", seat_pos, seat_rot)
	player:set_eye_offset(cfg.eye_offset_first, cfg.eye_offset_third_back, cfg.eye_offset_third_front)
	if player.set_look_horizontal then
		player:set_look_horizontal(get_drive_yaw(self))
	end

	local papi = get_player_api()
	if papi then
		if papi.player_attached then
			papi.player_attached[name] = true
		end
		if papi.set_animation then
			core.after(0.1, function()
				if self.driver ~= name then
					return
				end
				local current = core.get_player_by_name(name)
				if current and current:get_attach() == self.object then
					papi.set_animation(current, "sit", 30)
				end
			end)
		end
	end

	moon_rover.run_hooks("on_board", self, player)
	return true
end

function moon_rover.dismount(self, options)
	options = options or {}
	local name = self.driver
	if not name then
		return false
	end

	self.driver = nil
	self._board_cooldown = 0
	if moon_rover._active_drivers[name] == self then
		moon_rover._active_drivers[name] = nil
	end

	local player = options.player or core.get_player_by_name(name)
	if player then
		if player:get_attach() == self.object then
			player:set_detach()
		end
		player:set_eye_offset({x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})

		local papi = get_player_api()
		if papi then
			if papi.player_attached then
				papi.player_attached[name] = false
			end
			if papi.set_animation then
				papi.set_animation(player, "stand", 30)
			end
		end

		if not options.skip_reposition then
			local pos = self.object and self.object:get_pos()
			if pos then
				local exit_pos = find_dismount_pos(pos, get_drive_yaw(self))
				player:set_pos(exit_pos)
			end
		end
	end

	moon_rover.run_hooks("on_dismount", self, player, name)
	return true
end

local RoverEntity = {
	initial_properties = {
		physical = true,
		collide_with_objects = true,
		collisionbox = moon_rover.config.collisionbox,
		selectionbox = moon_rover.config.selectionbox,
		visual = "mesh",
		mesh = moon_rover.config.mesh,
		visual_size = moon_rover.config.visual_size,
		textures = moon_rover.config.textures,
		stepheight = moon_rover.config.stepheight,
		backface_culling = true,
		use_texture_alpha = false,
		static_save = true,
		hp_max = 100,
	},

	driver = nil,
	speed = 0,
	state = nil,
	_board_cooldown = 0,
	_anim_mode = nil,
	_anim_speed = 0,
}

function RoverEntity:on_activate(staticdata, dtime_s)
	self.driver = nil
	self.speed = 0
	self._board_cooldown = 0
	self._anim_mode = nil
	self._anim_speed = 0
	self.state = {}

	if staticdata and staticdata ~= "" and core.parse_json then
		local decoded = core.parse_json(staticdata)
		if type(decoded) == "table" and type(decoded.state) == "table" then
			self.state = decoded.state
		end
	end

	self.object:set_armor_groups({immortal = 1})
	self.object:set_acceleration({x = 0, y = -moon_rover.config.gravity, z = 0})
	moon_rover.update_wheel_animation(self, 0, moon_rover.config.wheel_circumference)

	moon_rover.run_hooks("on_activate", self, staticdata, dtime_s)
end

function RoverEntity:get_staticdata()
	moon_rover.run_hooks("on_get_staticdata", self)
	if core.write_json then
		return core.write_json({
			version = 1,
			state = self.state or {},
		}) or ""
	end
	return ""
end

function RoverEntity:on_deactivate(removal)
	if self.driver then
		moon_rover.dismount(self, {skip_reposition = true})
	end
end

function RoverEntity:on_detach_child(child)
	if child and child:is_player() and child:get_player_name() == self.driver then
		moon_rover.dismount(self, {player = child, skip_reposition = true})
	end
end

function RoverEntity:on_rightclick(clicker)
	if not clicker or not clicker:is_player() then
		return
	end

	if moon_rover.run_hooks("on_rightclick", self, clicker) then
		return
	end

	local name = clicker:get_player_name()
	if self.driver == name then
		moon_rover.dismount(self, {player = clicker})
	elseif not self.driver then
		moon_rover.board(self, clicker)
	elseif core.chat_send_player then
		core.chat_send_player(name, S("This Moon Rover is already occupied."))
	end
end

function RoverEntity:on_punch(puncher, time_from_last_punch, tool_capabilities, dir, damage)
	if not puncher or not puncher:is_player() then
		return true
	end

	local name = puncher:get_player_name()
	if self.driver and self.driver ~= name then
		return true
	end

	local pos = self.object:get_pos()
	if pos and core.is_protected and core.is_protected(pos, name) then
		if core.record_protection_violation then
			core.record_protection_violation(pos, name)
		end
		return true
	end

	if moon_rover.run_hooks("on_punch", self, puncher, time_from_last_punch, tool_capabilities, dir, damage) then
		return true
	end

	if self.driver == name then
		moon_rover.dismount(self, {player = puncher, skip_reposition = true})
	end

	local inv = puncher:get_inventory()
	local is_creative = core.is_creative_enabled and core.is_creative_enabled(name)
	local item_name = moon_rover.modname .. ":rover"

	if inv then
		if not (is_creative and inv:contains_item("main", item_name)) then
			local leftover = inv:add_item("main", item_name)
			if leftover and not leftover:is_empty() and pos and core.add_item then
				core.add_item(pos, leftover)
			end
		end
	elseif pos and core.add_item then
		core.add_item(pos, item_name)
	end

	self.object:remove()
	return true
end

function RoverEntity:on_step(dtime, moveresult)
	local dt = math.min(math.max(dtime or 0, 0), 0.1)
	if dt <= 0 then
		return
	end

	local cfg = moon_rover.config
	if self._board_cooldown > 0 then
		self._board_cooldown = math.max(0, self._board_cooldown - dt)
	end

	local driver = nil
	if self.driver then
		driver = core.get_player_by_name(self.driver)
		if not driver then
			moon_rover.dismount(self, {skip_reposition = true})
		end
	end

	local ctrl = driver and driver:get_player_control() or nil
	if driver and ctrl and ctrl.sneak and self._board_cooldown <= 0 then
		moon_rover.dismount(self, {player = driver})
		driver = nil
		ctrl = nil
	end

	local pos = self.object:get_pos()
	local vel = self.object:get_velocity() or {x = 0, y = 0, z = 0}
	local yaw = get_drive_yaw(self)

	-- Idle fast-path when completely parked and unoccupied
	if not driver and self.speed == 0 and math.abs(vel.x) < 0.01 and math.abs(vel.z) < 0.01 then
		moon_rover.update_wheel_animation(self, 0, cfg.wheel_circumference)
		moon_rover.run_hooks("on_step", self, dt, moveresult)
		return
	end

	-- Sync stored speed down if a real wall (not a 1-block step-up) stopped horizontal motion
	local fwd = moon_rover.yaw_to_forward(yaw)
	if has_blocking_horizontal_collision(moveresult) then
		local proj = vel.x * fwd.x + vel.z * fwd.z
		if math.abs(proj) < math.abs(self.speed) - 0.5 then
			self.speed = proj
		end
	end

	-- Steering (car-like reverse steering + in-place skid-steer when stationary)
	if driver and ctrl then
		local steer = (ctrl.left and 1 or 0) - (ctrl.right and 1 or 0)
		if steer ~= 0 then
			if self.speed < -0.2 then
				steer = -steer
			end
			local speed_ratio = math.min(math.abs(self.speed) / 2.0, 1.0)
			local turn_rate = cfg.pivot_turn_speed + (cfg.turn_speed - cfg.pivot_turn_speed) * speed_ratio
			yaw = moon_rover.normalize_yaw(yaw + steer * turn_rate * dt)
			set_drive_yaw(self, yaw)
			fwd = moon_rover.yaw_to_forward(yaw)
		end
	end

	-- Liquid check
	local submerged = pos ~= nil and is_in_liquid(pos)
	local max_fwd = submerged and math.min(cfg.max_speed, cfg.max_water_speed) or cfg.max_speed
	local max_rev = submerged and math.min(cfg.max_reverse_speed, cfg.max_water_speed) or cfg.max_reverse_speed
	local coast_drag = submerged and cfg.water_drag or (driver and cfg.rolling_drag or cfg.unoccupied_drag)

	-- Throttle, braking, and rolling resistance
	if driver and ctrl and ctrl.jump then
		self.speed = move_towards(self.speed, 0, cfg.brake_deceleration * dt)
	elseif driver and ctrl and ctrl.up and not ctrl.down then
		if self.speed < 0 then
			self.speed = move_towards(self.speed, 0, cfg.brake_deceleration * dt)
		else
			local rate = submerged and (cfg.acceleration * 0.5) or cfg.acceleration
			self.speed = move_towards(self.speed, max_fwd, rate * dt)
		end
	elseif driver and ctrl and ctrl.down and not ctrl.up then
		if self.speed > 0 then
			self.speed = move_towards(self.speed, 0, cfg.brake_deceleration * dt)
		else
			local rate = submerged and (cfg.reverse_acceleration * 0.5) or cfg.reverse_acceleration
			self.speed = move_towards(self.speed, -max_rev, rate * dt)
		end
	else
		self.speed = move_towards(self.speed, 0, coast_drag * dt)
	end

	-- Snap negligible creep to full stop
	if math.abs(self.speed) < 0.05 and not (driver and ctrl and (ctrl.up or ctrl.down)) then
		self.speed = 0
	end

	-- Clamp if entering water at high speed
	if self.speed > max_fwd then
		self.speed = move_towards(self.speed, max_fwd, cfg.water_drag * dt)
	elseif self.speed < -max_rev then
		self.speed = move_towards(self.speed, -max_rev, cfg.water_drag * dt)
	end

	self.object:set_velocity({
		x = fwd.x * self.speed,
		y = vel.y,
		z = fwd.z * self.speed,
	})
	self.object:set_acceleration({x = 0, y = -cfg.gravity, z = 0})
	moon_rover.update_wheel_animation(self, self.speed, cfg.wheel_circumference)

	moon_rover.run_hooks("on_step", self, dt, moveresult)
end

core.register_entity(moon_rover.modname .. ":rover", RoverEntity)

-- Cleanly detach players if they leave or die while driving
local function cleanup_player_driver(player)
	if not player then
		return
	end
	local name = player:get_player_name()
	local rover = moon_rover._active_drivers[name]
	if rover then
		moon_rover.dismount(rover, {player = player, skip_reposition = true})
	end
end

if core.register_on_leaveplayer then
	core.register_on_leaveplayer(cleanup_player_driver)
end

if core.register_on_dieplayer then
	core.register_on_dieplayer(cleanup_player_driver)
end
