#!/usr/bin/env lua
-- Comprehensive standalone unit tests for both Moon Rovers in the `moon_rover` Luanti mod
-- Run with: lua tests/test_rover.lua

local function approx(a, b, eps)
	eps = eps or 1e-4
	return math.abs(a - b) <= eps
end

-- Minimal JSON encoder/decoder handling both maps and arrays for staticdata round-trip tests
local function is_array(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
			return false
		end
		if k > n then n = k end
	end
	return n > 0
end

local function encode_json(val)
	local t = type(val)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		return val and "true" or "false"
	elseif t == "number" then
		return tostring(val)
	elseif t == "string" then
		return string.format("%q", val)
	elseif t == "table" then
		if is_array(val) then
			local parts = {}
			for i = 1, #val do
				parts[i] = encode_json(val[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		else
			local parts = {}
			for k, v in pairs(val) do
				parts[#parts + 1] = string.format("%q:%s", tostring(k), encode_json(v))
			end
			table.sort(parts)
			return "{" .. table.concat(parts, ",") .. "}"
		end
	end
	error("Unsupported type: " .. t)
end

local function decode_json(str)
	if not str or str == "" then return nil end
	local pos = 1
	local len = #str
	local function skip_ws()
		while pos <= len and str:sub(pos, pos):match("%s") do pos = pos + 1 end
	end
	local parse_val
	local function parse_str()
		pos = pos + 1 -- skip "
		local out = {}
		while pos <= len do
			local c = str:sub(pos, pos)
			if c == "\\" then
				pos = pos + 1
				local esc = str:sub(pos, pos)
				out[#out + 1] = esc
				pos = pos + 1
			elseif c == '"' then
				pos = pos + 1
				return table.concat(out)
			else
				out[#out + 1] = c
				pos = pos + 1
			end
		end
		error("Unterminated string")
	end
	parse_val = function()
		skip_ws()
		local c = str:sub(pos, pos)
		if c == '"' then
			return parse_str()
		elseif c == "{" then
			pos = pos + 1
			local obj = {}
			skip_ws()
			if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
			while true do
				skip_ws()
				local k = parse_str()
				skip_ws()
				assert(str:sub(pos, pos) == ":")
				pos = pos + 1
				obj[k] = parse_val()
				skip_ws()
				local sep = str:sub(pos, pos)
				pos = pos + 1
				if sep == "}" then return obj end
				assert(sep == ",")
			end
		elseif c == "[" then
			pos = pos + 1
			local arr = {}
			skip_ws()
			if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
			while true do
				arr[#arr + 1] = parse_val()
				skip_ws()
				local sep = str:sub(pos, pos)
				pos = pos + 1
				if sep == "]" then return arr end
				assert(sep == ",")
			end
		elseif str:sub(pos, pos + 3) == "true" then
			pos = pos + 4; return true
		elseif str:sub(pos, pos + 4) == "false" then
			pos = pos + 5; return false
		elseif str:sub(pos, pos + 3) == "null" then
			pos = pos + 4; return nil
		else
			local num_s = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
			assert(num_s, "Invalid JSON at " .. pos)
			pos = pos + #num_s
			return tonumber(num_s)
		end
	end
	return parse_val()
end

--------------------------------------------------------------------------------
-- Realistic Luanti ItemStack & Inventory Mock
--------------------------------------------------------------------------------

local ItemStack_mt
local function new_itemstack(spec, count_override)
	local name, count = "", 0
	if type(spec) == "table" and getmetatable(spec) == ItemStack_mt then
		name = spec._name
		count = count_override or spec._count
	elseif type(spec) == "string" and spec ~= "" then
		local n, c = spec:match("^%s*(%S+)%s+(%d+)%s*$")
		if n then
			name, count = n, tonumber(c)
		else
			name, count = spec:match("^%s*(%S+)%s*$") or "", 1
		end
		if count_override then count = count_override end
	end
	if count <= 0 or name == "" then
		name, count = "", 0
	end
	return setmetatable({_name = name, _count = count, _max = 99}, ItemStack_mt)
end

ItemStack_mt = {
	__index = {
		get_name = function(self) return self._name end,
		get_count = function(self) return self._count end,
		get_stack_max = function(self) return self._max end,
		is_empty = function(self) return self._count <= 0 or self._name == "" end,
		to_string = function(self)
			if self:is_empty() then return "" end
			if self._count == 1 then return self._name end
			return self._name .. " " .. self._count
		end,
		take_item = function(self, n)
			n = n or 1
			local taken = math.min(self._count, n)
			local name = self._name
			self._count = self._count - taken
			if self._count <= 0 then self._name = ""; self._count = 0 end
			return new_itemstack(name, taken)
		end,
		item_fits = function(self, other)
			other = new_itemstack(other)
			if other:is_empty() then return true end
			if self:is_empty() then return other._count <= self._max end
			return self._name == other._name and (self._count + other._count) <= self._max
		end,
		add_item = function(self, other)
			other = new_itemstack(other)
			if other:is_empty() then return new_itemstack("") end
			if self:is_empty() then
				local take = math.min(other._count, self._max)
				self._name = other._name
				self._count = take
				return new_itemstack(other._name, other._count - take)
			elseif self._name == other._name then
				local space = self._max - self._count
				local take = math.min(other._count, space)
				self._count = self._count + take
				return new_itemstack(other._name, other._count - take)
			end
			return other
		end,
	},
}

_G.ItemStack = new_itemstack

local function new_inventory(default_full)
	local lists = {}
	return {
		_lists = lists,
		_full = default_full or false,
		set_size = function(self, name, size)
			local l = lists[name] or {}
			for i = 1, size do
				if not l[i] then l[i] = new_itemstack("") end
			end
			lists[name] = l
		end,
		get_size = function(self, name) return lists[name] and #lists[name] or 0 end,
		get_list = function(self, name) return lists[name] end,
		get_stack = function(self, name, idx)
			local l = lists[name]
			if not l or not l[idx] then return new_itemstack("") end
			return new_itemstack(l[idx])
		end,
		set_stack = function(self, name, idx, stack)
			local l = lists[name]
			if l and idx >= 1 and idx <= #l then
				l[idx] = new_itemstack(stack)
			end
		end,
		is_empty = function(self, name)
			local l = lists[name]
			if not l then return true end
			for i = 1, #l do
				if not l[i]:is_empty() then return false end
			end
			return true
		end,
		contains_item = function(self, name, item)
			local req = new_itemstack(item)
			if req:is_empty() then return true end
			local l = lists[name]
			if not l then return false end
			local total = 0
			for i = 1, #l do
				if l[i]:get_name() == req:get_name() then
					total = total + l[i]:get_count()
				end
			end
			return total >= req:get_count()
		end,
		room_for_item = function(self, name, item)
			if self._full then return false end
			local req = new_itemstack(item)
			if req:is_empty() then return true end
			local l = lists[name]
			if not l then return false end
			local rem = req:get_count()
			for i = 1, #l do
				if l[i]:is_empty() then
					rem = rem - l[i]:get_stack_max()
				elseif l[i]:get_name() == req:get_name() then
					rem = rem - (l[i]:get_stack_max() - l[i]:get_count())
				end
				if rem <= 0 then return true end
			end
			return false
		end,
		add_item = function(self, name, item)
			local rem = new_itemstack(item)
			if self._full or rem:is_empty() then return rem end
			local l = lists[name]
			if not l then return rem end
			-- First stack into existing matching slots
			for i = 1, #l do
				if not l[i]:is_empty() and l[i]:get_name() == rem:get_name() then
					rem = l[i]:add_item(rem)
					if rem:is_empty() then return rem end
				end
			end
			-- Then empty slots
			for i = 1, #l do
				if l[i]:is_empty() then
					rem = l[i]:add_item(rem)
					if rem:is_empty() then return rem end
				end
			end
			return rem
		end,
		remove_item = function(self, name, item)
			local req = new_itemstack(item)
			if req:is_empty() then return new_itemstack("") end
			local l = lists[name]
			if not l then return new_itemstack("") end
			local taken_total = 0
			local want = req:get_count()
			for i = 1, #l do
				if l[i]:get_name() == req:get_name() then
					local t = l[i]:take_item(want - taken_total)
					taken_total = taken_total + t:get_count()
					if taken_total >= want then break end
				end
			end
			return new_itemstack(req:get_name(), taken_total)
		end,
	}
end

--------------------------------------------------------------------------------
-- Mock Luanti `core` & `player_api`
--------------------------------------------------------------------------------

local state = {
	entities = {},
	items = {},
	crafts = {},
	nodes = {},
	protected = false,
	creative = false,
	dropped_items = {},
	chat_messages = {},
	after_queue = {},
	leave_callbacks = {},
	die_callbacks = {},
	field_callbacks = {},
	players = {},
	spawned = {},
	detached_invs = {},
	shown_formspecs = {},
	world_objects = {},
}

local function node_key(pos)
	return string.format("%d,%d,%d", math.floor(pos.x + 0.5), math.floor(pos.y + 0.5), math.floor(pos.z + 0.5))
end

local function set_world_node(pos, name)
	state.nodes[node_key(pos)] = {name = name}
end

local function create_mock_object(pos, entity_def, entity_name)
	local obj
	local luaent = setmetatable({name = entity_name}, {__index = entity_def})
	obj = {
		_pos = {x = pos.x, y = pos.y, z = pos.z},
		_vel = {x = 0, y = 0, z = 0},
		_acc = {x = 0, y = 0, z = 0},
		_yaw = 0,
		_removed = false,
		_armor = {},
		_anim_range = nil,
		_anim_speed = 0,
		_anim_loop = false,
		_anim_calls = 0,
		_anim_speed_calls = 0,
		_luaent = luaent,
		get_pos = function(self) return {x = self._pos.x, y = self._pos.y, z = self._pos.z} end,
		set_pos = function(self, p) self._pos = {x = p.x, y = p.y, z = p.z} end,
		get_velocity = function(self) return {x = self._vel.x, y = self._vel.y, z = self._vel.z} end,
		set_velocity = function(self, v) self._vel = {x = v.x, y = v.y, z = v.z} end,
		get_acceleration = function(self) return self._acc end,
		set_acceleration = function(self, a) self._acc = {x = a.x, y = a.y, z = a.z} end,
		get_yaw = function(self) return self._yaw end,
		set_yaw = function(self, y) self._yaw = y end,
		set_armor_groups = function(self, g) self._armor = g end,
		set_animation = function(self, range, speed, blend, loop)
			self._anim_range = range
			self._anim_speed = speed
			self._anim_loop = loop
			self._anim_calls = self._anim_calls + 1
		end,
		set_animation_frame_speed = function(self, speed)
			self._anim_speed = speed
			self._anim_speed_calls = self._anim_speed_calls + 1
		end,
		get_luaentity = function(self) return self._luaent end,
		remove = function(self)
			self._removed = true
			if self._luaent.on_deactivate then
				self._luaent:on_deactivate(true)
			end
		end,
	}
	luaent.object = obj
	return obj, luaent
end

local function create_mock_player(name, opts)
	opts = opts or {}
	local inv = new_inventory(opts.inv_full)
	inv:set_size("main", 32)
	local p = {
		_name = name,
		_pos = {x = 0, y = 0, z = 0},
		_look_yaw = opts.look_yaw or 0,
		_attach = nil,
		_attach_pos = nil,
		_attach_rot = nil,
		_eye_first = {x = 0, y = 0, z = 0},
		_eye_third = {x = 0, y = 0, z = 0},
		_controls = {},
		_inv = inv,
		is_player = function() return true end,
		get_player_name = function(self) return self._name end,
		get_pos = function(self) return self._pos end,
		set_pos = function(self, pos) self._pos = {x = pos.x, y = pos.y, z = pos.z} end,
		get_look_horizontal = function(self) return self._look_yaw end,
		set_look_horizontal = function(self, y) self._look_yaw = y end,
		get_player_control = function(self) return self._controls end,
		get_inventory = function(self) return self._inv end,
		get_attach = function(self) return self._attach end,
		set_attach = function(self, parent, bone, pos, rot)
			self._attach = parent
			self._attach_pos = pos
			self._attach_rot = rot
		end,
		set_detach = function(self)
			self._attach = nil
			self._attach_pos = nil
			self._attach_rot = nil
		end,
		set_eye_offset = function(self, first, third_back, third_front)
			self._eye_first = first or {x = 0, y = 0, z = 0}
			self._eye_third = third_back or {x = 0, y = 0, z = 0}
		end,
	}
	state.players[name] = p
	return p
end

local registered_nodes = {
	["air"] = {walkable = false, buildable_to = true, liquidtype = "none", diggable = false},
	["default:stone"] = {walkable = true, buildable_to = false, liquidtype = "none", drop = "default:cobble"},
	["default:cobble"] = {walkable = true, buildable_to = false, liquidtype = "none"},
	["default:dirt"] = {walkable = true, buildable_to = false, liquidtype = "none"},
	["default:dirt_with_grass"] = {walkable = true, buildable_to = false, liquidtype = "none", drop = "default:dirt"},
	["default:tree"] = {walkable = true, buildable_to = false, liquidtype = "none", groups = {tree = 1, choppy = 2}},
	["default:wood"] = {walkable = true, buildable_to = false, liquidtype = "none", groups = {wood = 1}},
	["default:stone_with_coal"] = {walkable = true, liquidtype = "none", drop = "default:coal_lump"},
	["default:stone_with_iron"] = {walkable = true, liquidtype = "none", drop = "default:iron_lump"},
	["default:stone_with_diamond"] = {walkable = true, liquidtype = "none", drop = "default:diamond"},
	["default:water_source"] = {walkable = false, buildable_to = true, liquidtype = "source"},
	["wool:grey"] = {walkable = true, liquidtype = "none", groups = {wool = 1}},
	["wool:yellow"] = {walkable = true, liquidtype = "none", groups = {wool = 1}},
	["wool:white"] = {walkable = true, liquidtype = "none", groups = {wool = 1}},
	["flowers:dandelion_yellow"] = {walkable = false, liquidtype = "none", groups = {flower = 1}},
	["flowers:dandelion_white"] = {walkable = false, liquidtype = "none", groups = {flower = 1}},
	["farming:cotton_8"] = {walkable = false, liquidtype = "none", drop = "farming:cotton"},
	["default:chest"] = {
		walkable = true,
		buildable_to = false,
		on_metadata_inventory_put = function() end,
		on_rightclick = function(pos, node, clicker, itemstack)
			state.chest_opened = true
			return itemstack
		end,
	},
}

local registered_items = {
	["default:coal_lump"] = {groups = {coal = 1}},
	["default:iron_lump"] = {},
	["default:steel_ingot"] = {},
	["default:stick"] = {groups = {stick = 1}},
	["default:tree"] = registered_nodes["default:tree"],
	["default:wood"] = registered_nodes["default:wood"],
	["wool:grey"] = registered_nodes["wool:grey"],
	["wool:yellow"] = registered_nodes["wool:yellow"],
	["wool:white"] = registered_nodes["wool:white"],
}

_G.core = {
	registered_nodes = registered_nodes,
	registered_items = registered_items,
	get_item_group = function(name, grp)
		local def = registered_nodes[name] or registered_items[name]
		return (def and def.groups and def.groups[grp]) or 0
	end,
	get_current_modname = function() return "moon_rover" end,
	get_modpath = function(name)
		if name == "moon_rover" then return "." end
		return nil
	end,
	get_translator = function() return function(s) return s end end,
	formspec_escape = function(s) return tostring(s) end,
	register_entity = function(name, def) state.entities[name] = def end,
	register_craftitem = function(name, def)
		state.items[name] = def
		registered_items[name] = def
	end,
	register_craft = function(def) state.crafts[#state.crafts + 1] = def end,
	register_on_leaveplayer = function(fn) state.leave_callbacks[#state.leave_callbacks + 1] = fn end,
	register_on_dieplayer = function(fn) state.die_callbacks[#state.die_callbacks + 1] = fn end,
	register_on_player_receive_fields = function(fn) state.field_callbacks[#state.field_callbacks + 1] = fn end,
	get_node_or_nil = function(pos)
		return state.nodes[node_key(pos)] or {name = "air"}
	end,
	set_node = function(pos, node)
		state.nodes[node_key(pos)] = {name = node.name}
	end,
	remove_node = function(pos)
		state.nodes[node_key(pos)] = {name = "air"}
	end,
	get_node_drops = function(name)
		local def = registered_nodes[name]
		if def and def.drop then return {def.drop} end
		return {name}
	end,
	get_craft_result = function(input)
		local stack = input.items and input.items[1]
		local name = stack and stack:get_name() or ""
		if input.method == "cooking" then
			if name == "default:iron_lump" then
				return {item = new_itemstack("default:steel_ingot 1"), time = 3}
			elseif name == "default:cobble" then
				return {item = new_itemstack("default:stone 1"), time = 3}
			end
			return {item = new_itemstack(""), time = 0}
		elseif input.method == "fuel" then
			if name == "default:coal_lump" then
				return {item = new_itemstack(""), time = 40}
			elseif name == "default:stick" then
				return {item = new_itemstack(""), time = 1}
			elseif name == "default:wood" then
				return {item = new_itemstack(""), time = 7}
			elseif name == "default:tree" then
				return {item = new_itemstack(""), time = 30}
			end
			return {item = new_itemstack(""), time = 0}
		elseif input.method == "normal" then
			if name == "default:tree" then
				return {item = new_itemstack("default:wood 4")}
			elseif name == "default:wood" then
				return {item = new_itemstack("default:stick 4")}
			end
			return {item = new_itemstack("")}
		end
		return {item = new_itemstack(""), time = 0}
	end,
	create_detached_inventory = function(name, callbacks)
		local inv = new_inventory(false)
		state.detached_invs[name] = {inv = inv, callbacks = callbacks}
		return inv
	end,
	remove_detached_inventory = function(name)
		state.detached_invs[name] = nil
	end,
	show_formspec = function(pname, formname, fs)
		state.shown_formspecs[pname] = {formname = formname, formspec = fs}
	end,
	close_formspec = function(pname)
		state.shown_formspecs[pname] = nil
	end,
	get_objects_inside_radius = function(pos, radius)
		local res = {}
		for _, obj in ipairs(state.world_objects) do
			if not obj._removed then
				local p = obj:get_pos()
				local d = math.sqrt((p.x - pos.x)^2 + (p.y - pos.y)^2 + (p.z - pos.z)^2)
				if d <= radius then
					res[#res + 1] = obj
				end
			end
		end
		return res
	end,
	is_protected = function() return state.protected end,
	record_protection_violation = function() state.protection_violations = (state.protection_violations or 0) + 1 end,
	is_creative_enabled = function() return state.creative end,
	get_player_by_name = function(name) return state.players[name] end,
	chat_send_player = function(name, msg)
		state.chat_messages[#state.chat_messages + 1] = {player = name, msg = msg}
	end,
	add_item = function(pos, item)
		state.dropped_items[#state.dropped_items + 1] = {pos = pos, item = new_itemstack(item)}
	end,
	after = function(delay, fn)
		state.after_queue[#state.after_queue + 1] = fn
	end,
	add_entity = function(pos, name, staticdata)
		local def = state.entities[name]
		assert(def, "Entity not registered: " .. tostring(name))
		local obj, luaent = create_mock_object(pos, def, name)
		luaent:on_activate(staticdata or "", 0)
		state.spawned[#state.spawned + 1] = obj
		state.world_objects[#state.world_objects + 1] = obj
		return obj
	end,
	write_json = encode_json,
	parse_json = decode_json,
}

_G.player_api = {
	player_attached = {},
	_animations = {},
	set_animation = function(player, anim, speed)
		_G.player_api._animations[player:get_player_name()] = anim
	end,
}

-- Load the mod!
dofile("init.lua")

local passed = 0
local function run_test(name, fn)
	state.nodes = {}
	state.protected = false
	state.creative = false
	state.dropped_items = {}
	state.chat_messages = {}
	state.after_queue = {}
	state.players = {}
	state.spawned = {}
	state.detached_invs = {}
	state.shown_formspecs = {}
	state.world_objects = {}
	state.chest_opened = false
	state.protection_violations = 0
	_G.player_api.player_attached = {}
	_G.player_api._animations = {}
	moon_rover._active_drivers = {}
	moon_rover.auto._rovers_by_id = {}

	fn()
	passed = passed + 1
	print("PASS: " .. name)
end

-- Test 1: Both rovers registered with exact crafting recipes
run_test("both rovers registered with exact crafting recipes and stepheight >= 1.1", function()
	assert(state.entities["moon_rover:rover"] ~= nil)
	assert(state.entities["moon_rover:auto_rover"] ~= nil)
	assert(state.items["moon_rover:rover"] ~= nil)
	assert(state.items["moon_rover:auto_rover"] ~= nil)

	assert(state.entities["moon_rover:rover"].initial_properties.stepheight >= 1.1)
	assert(state.entities["moon_rover:auto_rover"].initial_properties.stepheight >= 1.1)
	assert(state.entities["moon_rover:rover"].initial_properties.mesh == "moon_rover.glb")
	assert(state.entities["moon_rover:auto_rover"].initial_properties.mesh == "moon_rover_auto.glb")

	assert(#state.crafts == 2, "expected 2 craft recipes")
	-- Recipe 1: Drivable Moon Rover (steel sign)
	local c1 = state.crafts[1]
	assert(c1.output == "moon_rover:rover")
	assert(c1.recipe[1][1] == "wool:grey" and c1.recipe[1][2] == "default:sign_wall_steel" and c1.recipe[1][3] == "wool:grey")
	assert(c1.recipe[2][1] == "" and c1.recipe[2][2] == "default:steel_ingot" and c1.recipe[2][3] == "")
	assert(c1.recipe[3][1] == "wool:grey" and c1.recipe[3][2] == "" and c1.recipe[3][3] == "wool:grey")

	-- Recipe 2: Autonomous Moon Rover (yellow wool instead of sign)
	local c2 = state.crafts[2]
	assert(c2.output == "moon_rover:auto_rover")
	assert(c2.recipe[1][1] == "wool:grey" and c2.recipe[1][2] == "wool:yellow" and c2.recipe[1][3] == "wool:grey")
	assert(c2.recipe[2][1] == "" and c2.recipe[2][2] == "default:steel_ingot" and c2.recipe[2][3] == "")
	assert(c2.recipe[3][1] == "wool:grey" and c2.recipe[3][2] == "" and c2.recipe[3][3] == "wool:grey")
end)

-- Test 2: Drivable rover forward-aligned seat rotation, wheel animation timeline, and 1-block step climb
run_test("drivable rover: forward-aligned driver seat, continuous tire animation, 1-block climb", function()
	local alice = create_mock_player("alice")
	local obj = _G.core.add_entity({x = 0, y = 0.52, z = 0}, "moon_rover:rover")
	local rover = obj:get_luaentity()

	-- Idle animation on spawn
	assert(obj._anim_range.x == 0 and obj._anim_range.y == 0)
	assert(obj._anim_loop == false)

	-- Boarding aligns player facing +Z forward (matching the rotated glTF rover mesh)
	rover:on_rightclick(alice)
	assert(alice:get_attach() == obj)
	assert(approx(alice._attach_rot.y, 0), "player faces +Z forward with rover")

	-- Accelerate forward -> continuous forward timeline 0.0..1.0
	alice._controls = {up = true}
	rover:on_step(0.1)
	assert(obj._anim_range.x == 0.0 and obj._anim_range.y == 1.0, "forward wheel animation range")
	assert(obj._anim_loop == true and obj._anim_speed > 0)

	-- Smooth speed change uses set_animation_frame_speed (doesn't reset animation phase)
	local calls_before = obj._anim_calls
	for _ = 1, 10 do rover:on_step(0.1) end
	assert(obj._anim_calls == calls_before, "did not spam set_animation in same direction")
	assert(obj._anim_speed_calls > 0, "updated animation speed smoothly")

	-- Climbing a 1-block obstacle via stepheight (new_pos.y > old_pos.y) preserves momentum!
	local speed_before_step = rover.speed
	assert(speed_before_step > 5.0)
	obj:set_velocity({x = 0, y = 0, z = 0})
	rover:on_step(0.05, {
		collides = true,
		collisions = {{axis = "z", old_pos = {x = 0, y = 0.5, z = 0}, new_pos = {x = 0, y = 1.5, z = 0.1}}},
	})
	assert(rover.speed >= speed_before_step, "1-block step climb must not zero speed")

	-- Real 2-block wall (new_pos.y == old_pos.y) DOES stop ghost momentum
	obj:set_velocity({x = 0, y = 0, z = 0})
	alice._controls = {}
	rover:on_step(0.05, {
		collides = true,
		collisions = {{axis = "z", old_pos = {x = 0, y = 1.5, z = 0}, new_pos = {x = 0, y = 1.5, z = 0}}},
	})
	assert(rover.speed < 0.1, "wall stops forward momentum")

	-- Reversing switches to reverse continuous timeline 1.2..2.2
	alice._controls = {down = true}
	for _ = 1, 5 do rover:on_step(0.1) end
	assert(obj._anim_range.x == 1.2 and obj._anim_range.y == 2.2, "reverse wheel animation range")
	assert(obj._anim_loop == true and obj._anim_speed > 0)
end)

-- Test 3: Autonomous rover 64-slot chest, UI pause/resume, and staticdata persistence
run_test("autonomous rover: 64-slot chest, formspec UI pause, and staticdata persistence", function()
	local alice = create_mock_player("alice")
	local obj = _G.core.add_entity({x = 0, y = 0.52, z = 0}, "moon_rover:auto_rover")
	local rover = obj:get_luaentity()

	local inv = rover:get_inv()
	assert(inv:get_size("main") == 64, "chest must have 64 slots")
	assert(inv:get_size("furnace_src") == 1)
	assert(inv:get_size("furnace_fuel") == 1)
	assert(inv:get_size("furnace_dst") == 1)

	-- Player puts steel ingot into chest and opens UI
	inv:add_item("main", new_itemstack("default:steel_ingot 2"))
	rover:on_rightclick(alice)
	assert(state.shown_formspecs["alice"] ~= nil, "formspec shown on right-click")
	assert(state.shown_formspecs["alice"].formspec:find("8,8", 1, true), "8x8 = 64 slot grid")

	-- While UI is open, rover stays paused (speed 0)
	rover:on_step(0.1)
	assert(rover.speed == 0, "rover pauses while player inspects chest")

	-- Toggle pause button & close UI
	local fname = state.shown_formspecs["alice"].formname
	for _, cb in ipairs(state.field_callbacks) do cb(alice, fname, {toggle_pause = "1"}) end
	assert(rover.state.paused == true)
	for _, cb in ipairs(state.field_callbacks) do cb(alice, fname, {quit = "true"}) end

	-- Persistence round-trip
	local saved = rover:get_staticdata()
	local obj2 = _G.core.add_entity({x = 0, y = 0.52, z = 0}, "moon_rover:auto_rover", saved)
	local rover2 = obj2:get_luaentity()
	assert(rover2.state.paused == true)
	assert(rover2:get_inv():contains_item("main", "default:steel_ingot 2"), "64-slot chest persisted")
end)

-- Test 4: Material value prioritization (valuable first, fallback to lower value)
run_test("autonomous rover: prioritizes valuable ores over dirt, falls back to less valuable", function()
	local obj = _G.core.add_entity({x = 0, y = 1.0, z = 0}, "moon_rover:auto_rover")
	local rover = obj:get_luaentity()

	-- Nearby dirt (dist 1) vs farther diamond ore (dist 4) + chest (forbidden!)
	set_world_node({x = 1, y = 1, z = 0}, "default:dirt")
	set_world_node({x = 4, y = 1, z = 0}, "default:stone_with_diamond")
	set_world_node({x = 2, y = 1, z = 0}, "default:chest")

	local tpos, tname = moon_rover.auto.scan_for_target(rover, {x = 0, y = 1, z = 0})
	assert(tname == "default:stone_with_diamond", "must prioritize valuable diamond ore over nearby dirt")
	assert(tpos.x == 4)

	-- Remove diamond ore -> falls back to stone (value 20) over dirt (value 12)
	set_world_node({x = 4, y = 1, z = 0}, "air")
	set_world_node({x = 3, y = 1, z = 0}, "default:stone")
	tpos, tname = moon_rover.auto.scan_for_target(rover, {x = 0, y = 1, z = 0})
	assert(tname == "default:stone", "prefers stone over dirt when no ores present")

	-- Remove stone -> falls back to dirt (never digs chest!)
	set_world_node({x = 3, y = 1, z = 0}, "air")
	tpos, tname = moon_rover.auto.scan_for_target(rover, {x = 0, y = 1, z = 0})
	assert(tname == "default:dirt", "falls back to lower-value dirt and ignores chest")
end)

-- Test 5: Tree chopping column + wood->planks->sticks + never-place-undug-blocks invariant
run_test("autonomous rover: chops full tree, crafts sticks, enforces never-place-undug-blocks", function()
	-- Ground floor
	for x = -3, 3 do
		for z = -3, 3 do
			set_world_node({x = x, y = 0, z = z}, "default:dirt_with_grass")
		end
	end
	-- 3-block tall tree within digging reach at (2, 1..3, 0)
	set_world_node({x = 2, y = 1, z = 0}, "default:tree")
	set_world_node({x = 2, y = 2, z = 0}, "default:tree")
	set_world_node({x = 2, y = 3, z = 0}, "default:tree")

	local obj = _G.core.add_entity({x = 0, y = 0.52, z = 0}, "moon_rover:auto_rover")
	local rover = obj:get_luaentity()

	-- Run autonomous steps long enough to scan, chop all 3 tree blocks, and craft sticks
	for _ = 1, 50 do
		rover:on_step(0.1)
	end

	assert(_G.core.get_node_or_nil({x = 2, y = 1, z = 0}).name == "air", "trunk 1 chopped")
	assert(_G.core.get_node_or_nil({x = 2, y = 2, z = 0}).name == "air", "trunk 2 chained & chopped")
	assert(_G.core.get_node_or_nil({x = 2, y = 3, z = 0}).name == "air", "trunk 3 chained & chopped")
	assert(rover:get_inv():contains_item("main", "default:stick 4"), "crafted sticks from chopped tree")
	assert((rover.state.dug_blocks["default:tree"] or 0) == 3, "recorded dug tree blocks")

	-- Never-place-undug-blocks rule:
	-- Even if a player puts default:cobble into the chest, rover CANNOT place it because it never dug cobble!
	rover:get_inv():add_item("main", new_itemstack("default:cobble 5"))
	assert(moon_rover.auto.can_place_block(rover, "default:cobble") == false, "must refuse undug block")
	assert(moon_rover.auto.place_dug_block(rover, {x = -2, y = 1, z = 0}, "default:cobble") == false)
	assert(_G.core.get_node_or_nil({x = -2, y = 1, z = 0}).name == "air")

	-- For a block it DID dig (default:tree, and still holds at least 1): allowed and decrements ledger!
	assert(moon_rover.auto.can_place_block(rover, "default:tree") == true)
	assert(moon_rover.auto.place_dug_block(rover, {x = -2, y = 1, z = 0}, "default:tree") == true)
	assert(_G.core.get_node_or_nil({x = -2, y = 1, z = 0}).name == "default:tree")
	assert(rover.state.dug_blocks["default:tree"] == 2)
end)

-- Test 6: Built-in Oven smelts iron_lump -> steel_ingot using fuel from chest
run_test("autonomous rover: built-in oven auto-smelts iron_lump into steel_ingot", function()
	local obj = _G.core.add_entity({x = 0, y = 0.52, z = 0}, "moon_rover:auto_rover")
	local rover = obj:get_luaentity()
	rover.state.paused = true -- keep stationary while testing oven

	local inv = rover:get_inv()
	inv:add_item("main", new_itemstack("default:iron_lump 1"))
	inv:add_item("main", new_itemstack("default:coal_lump 1"))

	-- Smelting time for iron_lump is 3.0s; run 4.0s of steps
	for _ = 1, 40 do
		rover:on_step(0.1)
	end

	assert(inv:contains_item("main", "default:steel_ingot 1"), "oven smelted iron_lump into steel_ingot")
	assert(not inv:contains_item("main", "default:iron_lump 1"), "iron_lump consumed")
	assert(not inv:contains_item("main", "default:coal_lump 1"), "coal_lump consumed as fuel")
end)

-- Test 7: Full Self-Replication Goal (uses player-supplied steel + gathered wool/dyes -> crafts & places new rover!)
run_test("autonomous rover: uses player-supplied steel + gathered materials to craft & place new rover", function()
	-- Flat stone ground around rover so deployment finds clear ground
	for x = -4, 4 do
		for z = -4, 4 do
			set_world_node({x = x, y = 0, z = z}, "default:stone")
		end
	end

	local obj = _G.core.add_entity({x = 0, y = 0.52, z = 0}, "moon_rover:auto_rover")
	local rover = obj:get_luaentity()
	rover.state.paused = true -- isolate crafting & deployment step

	local inv = rover:get_inv()
	-- Player supplies steel ingot (rover didn't find iron/steel!)
	inv:add_item("main", new_itemstack("default:steel_ingot 1"))
	-- Rover gathered cotton, flowers, and coal from the world:
	-- 20 cotton -> 5 wool:white; dandelion_yellow -> dye:yellow -> 1 wool:yellow;
	-- dandelion_white + 2 coal -> dye:white + dye:black -> dye:grey -> 4 wool:grey!
	inv:add_item("main", new_itemstack("farming:cotton 20"))
	inv:add_item("main", new_itemstack("flowers:dandelion_yellow 1"))
	inv:add_item("main", new_itemstack("flowers:dandelion_white 1"))
	inv:add_item("main", new_itemstack("default:coal_lump 3"))

	-- Run crafting ticks through the entire crafting chain -> crafts & deploys a brand-new rover!
	for _ = 1, 15 do
		moon_rover.auto.tick_crafting(rover)
	end

	assert(rover.state.replication_count == 1, "rover replicated itself once")
	assert(#state.spawned == 2, "a second autonomous rover entity was spawned in the world")
	assert(state.spawned[2]:get_luaentity().name == "moon_rover:auto_rover")
	assert(not inv:contains_item("main", "default:steel_ingot 1"), "steel ingot consumed")
	assert(not inv:contains_item("main", "wool:yellow 1"), "yellow wool consumed")
	assert(not inv:contains_item("main", "wool:grey 1"), "4 grey wool consumed")
end)

-- Test 8: Autonomous driving, dropped item vacuuming, and safe punch-to-pickup
run_test("autonomous rover: vacuums dropped items, animates wheels while roaming, sneak+punch pickup", function()
	for x = -6, 6 do
		for z = -6, 6 do
			set_world_node({x = x, y = 0, z = z}, "default:stone")
		end
	end

	local alice = create_mock_player("alice")
	local obj = _G.core.add_entity({x = 0, y = 0.52, z = 0}, "moon_rover:auto_rover")
	local rover = obj:get_luaentity()

	-- Drop a steel ingot nearby -> rover vacuums it automatically
	local drop_obj = create_mock_object({x = 1.0, y = 0.6, z = 0}, {itemstring = "default:steel_ingot 1"}, "__builtin:item")
	state.world_objects[#state.world_objects + 1] = drop_obj

	rover:on_step(0.1)
	assert(drop_obj._removed == true, "dropped item vacuumed")
	assert(rover:get_inv():contains_item("main", "default:steel_ingot 1"))
	assert(obj._anim_range.x == 0.0 and obj._anim_range.y == 1.0, "wheels animate forward while roaming")

	-- Normal punch while non-empty warns and does NOT remove rover
	rover:on_punch(alice)
	assert(obj._removed == false, "cannot accidentally delete non-empty chest rover")
	assert(#state.chat_messages >= 1)

	-- Sneak + punch drops stored contents and returns rover item
	alice._controls = {sneak = true}
	rover:on_punch(alice)
	assert(obj._removed == true, "sneak+punch picked up rover")
	assert(#state.dropped_items >= 1, "stored steel dropped safely")
	assert(alice:get_inventory():contains_item("main", "moon_rover:auto_rover"))
end)

-- Test 9: Autonomous rover drives over 1-block obstacles (even at y=0.4999) and steers around 2-block walls
run_test("autonomous rover: climbs 1-block obstacle ahead and avoids 2-block wall", function()
	for x = -3, 3 do
		for z = -3, 6 do
			set_world_node({x = x, y = 0, z = z}, "default:stone")
		end
	end
	-- 1-block step directly ahead (+Z at z=1, y=1) with open air above (y=2, y=3)
	-- and a high-value diamond target further along +Z at z=5 so rover drives straight over the 1-block step!
	set_world_node({x = 0, y = 1, z = 1}, "default:stone")
	set_world_node({x = 0, y = 1, z = 5}, "default:stone_with_diamond")

	local obj = _G.core.add_entity({x = 0, y = 0.4999, z = 0}, "moon_rover:auto_rover")
	local rover = obj:get_luaentity()
	obj:set_yaw(0)
	rover._scan_timer = 0
	rover:on_step(0.1)
	assert(rover._target_name == "default:stone_with_diamond")
	assert(approx(rover.speed, moon_rover.auto_config.drive_speed, 0.01), "drives full speed over 1-block step")
	assert(obj:get_velocity().z > 2.0, "moving forward over 1-block obstacle")

	-- Now stack a 2nd block (making a 2-block wall at z=1, y=1..2) -> slows & steers around!
	set_world_node({x = 0, y = 2, z = 1}, "default:stone")
	rover:on_step(0.1)
	assert(rover.speed < moon_rover.auto_config.drive_speed * 0.5, "avoids 2-block wall")
end)

print(string.format("\nALL %d TESTS PASSED!", passed))
