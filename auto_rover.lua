-- Autonomous Gathering, Smelting, Crafting & Self-Replicating Moon Rover (Kenney.nl CC0 model)
-- Copyright (c) 2026 ronrob-lu (MIT License)

local core = rawget(_G, "core") or minetest
local S = moon_rover.S

local AUTO_ENTITY_NAME = moon_rover.modname .. ":auto_rover"
local INV_PREFIX = "moon_rover_auto_"
local FORMSPEC_PREFIX = "moon_rover:auto_rover_ui:"

moon_rover.auto = {
	_rovers_by_id = {},
	_next_seq = 1,
}

--------------------------------------------------------------------------------
-- Helpers: Node classification, value ranking, inventory utilities
--------------------------------------------------------------------------------

local function pos_key(p)
	return string.format("%d,%d,%d", math.floor(p.x + 0.5), math.floor(p.y + 0.5), math.floor(p.z + 0.5))
end

local function round_pos(p)
	return {x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.6), z = math.floor(p.z + 0.5)}
end

local function get_item_group(name, group)
	if core.get_item_group then
		return core.get_item_group(name, group) or 0
	end
	local def = core.registered_items and core.registered_items[name]
		or core.registered_nodes and core.registered_nodes[name]
	if def and def.groups then
		return def.groups[group] or 0
	end
	return 0
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
	local node = core.get_node_or_nil(pos)
	if not node then
		return false
	end
	local def = core.registered_nodes[node.name]
	return def ~= nil and def.liquidtype ~= nil and def.liquidtype ~= "none"
end

local function get_drive_yaw(self)
	local offset = moon_rover.auto_config.model_yaw_offset or 0
	return moon_rover.normalize_yaw((self.object:get_yaw() or 0) - offset)
end

local function set_drive_yaw(self, yaw)
	local offset = moon_rover.auto_config.model_yaw_offset or 0
	self.object:set_yaw(moon_rover.normalize_yaw(yaw + offset))
end

local function count_item(inv, item_name)
	if not inv then
		return 0
	end
	local total = 0
	local list = inv:get_list("main")
	if not list then
		return 0
	end
	for i = 1, #list do
		local st = list[i]
		if st and not st:is_empty() and st:get_name() == item_name then
			total = total + st:get_count()
		end
	end
	return total
end

local function find_item_in_group(inv, group_name, min_count)
	if not inv then
		return nil, 0
	end
	min_count = min_count or 1
	local list = inv:get_list("main")
	if not list then
		return nil, 0
	end
	local counts = {}
	local order = {}
	for i = 1, #list do
		local st = list[i]
		if st and not st:is_empty() then
			local n = st:get_name()
			if get_item_group(n, group_name) > 0 then
				if not counts[n] then
					counts[n] = 0
					order[#order + 1] = n
				end
				counts[n] = counts[n] + st:get_count()
			end
		end
	end
	for i = 1, #order do
		local n = order[i]
		if counts[n] >= min_count then
			return n, counts[n]
		end
	end
	return nil, 0
end

local function count_empty_slots(inv)
	if not inv then
		return 0
	end
	local list = inv:get_list("main")
	if not list then
		return 0
	end
	local empty = 0
	for i = 1, #list do
		if not list[i] or list[i]:is_empty() then
			empty = empty + 1
		end
	end
	return empty
end

local function is_inventory_completely_empty(inv)
	if not inv then
		return true
	end
	for _, listname in ipairs({"main", "furnace_src", "furnace_fuel", "furnace_dst"}) do
		if not inv:is_empty(listname) then
			return false
		end
	end
	return true
end

-- Static base value table (higher = gathered first; fallback to lower-value when none nearby)
local BASE_NODE_VALUES = {
	["default:stone_with_diamond"] = 100,
	["default:diamondblock"]       = 100,
	["default:stone_with_mese"]    = 95,
	["default:mese"]               = 95,
	["default:stone_with_gold"]    = 85,
	["default:steelblock"]         = 85,
	["default:stone_with_iron"]    = 80,
	["default:stone_with_copper"]  = 65,
	["default:stone_with_tin"]     = 65,
	["default:stone_with_coal"]    = 60,
	["wool:yellow"]                = 58,
	["wool:grey"]                  = 58,
	["wool:white"]                 = 52,
	["farming:cotton_8"]           = 52,
	["farming:cotton_wild"]        = 52,
	["default:obsidian"]           = 40,
	["default:cactus"]             = 35,
	["default:papyrus"]            = 35,
	["default:stone"]              = 20,
	["default:desert_stone"]       = 20,
	["default:cobble"]             = 20,
	["default:mossycobble"]        = 20,
	["default:sandstone"]          = 20,
	["default:desert_sandstone"]   = 20,
	["default:silver_sandstone"]   = 20,
	["default:clay"]               = 18,
	["default:gravel"]             = 18,
	["default:sand"]               = 18,
	["default:desert_sand"]        = 18,
	["default:silver_sand"]        = 18,
	["default:dirt_with_grass"]    = 12,
	["default:dirt_with_dry_grass"] = 12,
	["default:dirt_with_snow"]     = 12,
	["default:dirt_with_rainforest_litter"] = 12,
	["default:dirt_with_coniferous_litter"] = 12,
	["default:dirt"]               = 12,
	["default:snow"]               = 12,
	["default:snowblock"]          = 12,
}

local FORBIDDEN_NAME_PATTERNS = {
	"chest", "furnace", "door", "bed", "sign", "locked",
	"protector", "bookshelf", "vessel", "bones", "spawner",
}

function moon_rover.auto.is_gatherable_node(node_name)
	if not node_name or node_name == "air" or node_name == "ignore" then
		return false
	end
	local def = core.registered_nodes and core.registered_nodes[node_name]
	if not def then
		return false
	end
	if def.diggable == false then
		return false
	end
	if def.liquidtype and def.liquidtype ~= "none" then
		return false
	end
	if get_item_group(node_name, "unbreakable") > 0 or get_item_group(node_name, "immortal") > 0 then
		return false
	end
	-- Do not vandalize containers / interactive player base structures
	if def.on_metadata_inventory_put or def.on_metadata_inventory_take then
		return false
	end
	local lower = string.lower(node_name)
	for i = 1, #FORBIDDEN_NAME_PATTERNS do
		if string.find(lower, FORBIDDEN_NAME_PATTERNS[i], 1, true) then
			return false
		end
	end
	return true
end

function moon_rover.auto.score_node(node_name, self)
	if not moon_rover.auto.is_gatherable_node(node_name) then
		return nil
	end

	local base = BASE_NODE_VALUES[node_name]
	if not base then
		if get_item_group(node_name, "ore") > 0 or string.find(node_name, "_with_", 1, true) then
			base = 70
		elseif get_item_group(node_name, "tree") > 0 then
			base = 55
		elseif get_item_group(node_name, "wool") > 0 then
			base = 45
		elseif get_item_group(node_name, "flower") > 0 then
			base = 46
		elseif get_item_group(node_name, "leaves") > 0 or get_item_group(node_name, "flora") > 0
				or get_item_group(node_name, "grass") > 0 then
			base = 10
		else
			base = 14
		end
	end

	local score = base
	local inv = self and self:get_inv() or nil
	if inv then
		local grey_wool = count_item(inv, "wool:grey")
		local yellow_wool = count_item(inv, "wool:yellow")
		local steel = count_item(inv, "default:steel_ingot")
		local iron_lump = count_item(inv, "default:iron_lump")
		local sticks = count_item(inv, "default:stick")

		-- Boost materials directly advancing self-replication
		if grey_wool < 4 then
			if node_name == "wool:grey" then
				score = score + 50
			elseif node_name == "wool:white" or node_name == "farming:cotton_8" or node_name == "farming:cotton_wild" then
				score = score + 35
			elseif node_name == "flowers:dandelion_white" or node_name == "flowers:tulip_black" then
				score = score + 35
			elseif node_name == "default:stone_with_coal" then
				score = score + 20
			end
		end

		if yellow_wool < 1 then
			if node_name == "wool:yellow" then
				score = score + 55
			elseif node_name == "flowers:dandelion_yellow" then
				score = score + 40
			elseif node_name == "wool:white" or node_name == "farming:cotton_8" or node_name == "farming:cotton_wild" then
				score = score + 30
			end
		end

		if steel < 1 and iron_lump < 1 then
			if node_name == "default:stone_with_iron" or node_name == "default:steelblock" then
				score = score + 40
			end
		end

		if sticks < moon_rover.auto_config.target_sticks and get_item_group(node_name, "tree") > 0 then
			score = score + 15
		end

		-- Encourage material variety & avoid flooding all 64 slots with one low-value block
		if base <= 20 then
			local held = count_item(inv, node_name)
			if held >= 297 then
				score = score - 25
			elseif held >= 99 then
				score = score - 10
			end
		end

		-- When nearly full (<= 4 free slots), preserve remaining space for high-value / goal items
		local empty_slots = count_empty_slots(inv)
		if empty_slots <= 4 and score < 55 then
			if not inv:contains_item("main", node_name) then
				return nil
			end
		end
	end

	return score
end

--------------------------------------------------------------------------------
-- Strict "never place blocks not dug before" ledger
--------------------------------------------------------------------------------

function moon_rover.auto.record_dug_block(self, node_name)
	self.state.dug_blocks = self.state.dug_blocks or {}
	self.state.dug_blocks[node_name] = (self.state.dug_blocks[node_name] or 0) + 1
	self.state.total_dug = (self.state.total_dug or 0) + 1
end

function moon_rover.auto.can_place_block(self, node_name)
	if not self or not self.state or not self.state.dug_blocks then
		return false
	end
	if (self.state.dug_blocks[node_name] or 0) <= 0 then
		return false
	end
	local inv = self:get_inv()
	if not inv or not inv:contains_item("main", node_name) then
		return false
	end
	return true
end

function moon_rover.auto.place_dug_block(self, pos, node_name)
	if not moon_rover.auto.can_place_block(self, node_name) then
		return false
	end
	if core.is_protected and core.is_protected(pos, self.state.owner or "") then
		return false
	end
	local inv = self:get_inv()
	local removed = inv:remove_item("main", ItemStack(node_name .. " 1"))
	if removed:is_empty() then
		return false
	end
	self.state.dug_blocks[node_name] = self.state.dug_blocks[node_name] - 1
	core.set_node(pos, {name = node_name})
	return true
end

--------------------------------------------------------------------------------
-- Detached 64-slot Chest + Oven Inventory & Formspec UI
--------------------------------------------------------------------------------

local function generate_rover_id()
	local seq = moon_rover.auto._next_seq
	moon_rover.auto._next_seq = seq + 1
	return string.format("%d_%d_%d", os.time(), seq, math.random(1000, 9999))
end

local function serialize_inv(inv)
	if not inv then
		return {}
	end
	local out = {}
	for _, listname in ipairs({"main", "furnace_src", "furnace_fuel", "furnace_dst"}) do
		local list = inv:get_list(listname)
		if list then
			local saved = {}
			for i = 1, #list do
				local st = list[i]
				if st and not st:is_empty() then
					saved[#saved + 1] = {slot = i, item = st:to_string()}
				end
			end
			out[listname] = saved
		end
	end
	return out
end

local function restore_inv(inv, data)
	if not inv or type(data) ~= "table" then
		return
	end
	for _, listname in ipairs({"main", "furnace_src", "furnace_fuel", "furnace_dst"}) do
		local entries = data[listname]
		if type(entries) == "table" then
			for i = 1, #entries do
				local e = entries[i]
				if e and e.slot and e.item then
					inv:set_stack(listname, e.slot, ItemStack(e.item))
				end
			end
		end
	end
end

local function build_formspec(self)
	local esc = core.formspec_escape or function(s) return s end
	local inv_name = INV_PREFIX .. self.rover_id
	local inv = self:get_inv()
	local f = self.state.furnace or {}

	local grey = count_item(inv, "wool:grey")
	local yellow = count_item(inv, "wool:yellow")
	local steel = count_item(inv, "default:steel_ingot")
	local sticks = count_item(inv, "default:stick")
	local reps = self.state.replication_count or 0
	local dug = self.state.total_dug or 0
	local status = self.state.paused and S("Paused") or (self._status or S("Roaming"))

	local fuel_pct = 0
	if (f.fuel_total or 0) > 0 and (f.fuel_time or 0) > 0 then
		fuel_pct = math.min(100, math.floor((f.fuel_time / f.fuel_total) * 100))
	end
	local cook_pct = 0
	if (f.cook_total or 0) > 0 and (f.cook_time or 0) > 0 then
		cook_pct = math.min(100, math.floor((f.cook_time / f.cook_total) * 100))
	end

	local pause_label = self.state.paused and S("Resume AI") or S("Pause AI")

	return table.concat({
		"formspec_version[4]",
		"size[18.0,10.2]",
		"style_type[list;size=0.9;spacing=0.1]",

		-- Header
		"label[0.4,0.45;" .. esc(S("Autonomous Moon Rover — 64-Slot Chest & Oven")) .. "]",
		"label[9.2,0.45;" .. esc(S("Status: ") .. status) .. "]",

		-- Left: 64-slot chest (8x8)
		"label[0.4,0.9;" .. esc(S("Rover Storage (64 slots)")) .. "]",
		"list[detached:" .. esc(inv_name) .. ";main;0.4,1.2;8,8;]",

		-- Top-right: Built-in Oven
		"box[9.2,1.1;8.4,3.1;#20242c]",
		"label[9.4,1.45;" .. esc(S("Built-in Oven")) .. "]",
		"label[9.4,1.95;" .. esc(S("Input")) .. "]",
		"list[detached:" .. esc(inv_name) .. ";furnace_src;9.4,2.2;1,1;]",
		"label[10.7,1.95;" .. esc(S("Fuel")) .. "]",
		"list[detached:" .. esc(inv_name) .. ";furnace_fuel;10.7,2.2;1,1;]",
		"label[12.0,2.25;" .. esc(string.format("Burn: %d%%", fuel_pct)) .. "]",
		"label[12.0,2.75;" .. esc(string.format("Cook: %d%%", cook_pct)) .. "]",
		"label[14.2,1.95;" .. esc(S("Output")) .. "]",
		"list[detached:" .. esc(inv_name) .. ";furnace_dst;14.2,2.2;1,1;]",

		-- Replication progress & controls
		"label[9.4,3.55;" .. esc(string.format(
			"Self-Replication Goal: Grey Wool %d/4 | Yellow Wool %d/1 | Steel %d/1",
			grey, yellow, steel
		)) .. "]",
		"label[9.4,3.95;" .. esc(string.format(
			"Sticks: %d | Dug Blocks: %d | New Rovers Deployed: %d",
			sticks, dug, reps
		)) .. "]",

		"button[15.4,1.35;2.0,0.7;toggle_pause;" .. esc(pause_label) .. "]",
		"button[15.4,2.25;2.0,0.7;refresh;" .. esc(S("Refresh")) .. "]",

		-- Bottom-right: Player Inventory (8x4)
		"label[9.2,4.7;" .. esc(S("Player Inventory (put steel / wool / fuel into Rover Storage)")) .. "]",
		"list[current_player;main;9.2,5.0;8,4;]",
		"listring[detached:" .. esc(inv_name) .. ";main]",
		"listring[current_player;main]",
	})
end

local function refresh_viewers(self)
	if not self._viewers or not core.show_formspec then
		return
	end
	local fs = nil
	for pname in pairs(self._viewers) do
		local p = core.get_player_by_name(pname)
		if p then
			fs = fs or build_formspec(self)
			core.show_formspec(pname, FORMSPEC_PREFIX .. self.rover_id, fs)
		else
			self._viewers[pname] = nil
		end
	end
end

local function has_open_viewers(self)
	if not self._viewers then
		return false
	end
	for pname in pairs(self._viewers) do
		if core.get_player_by_name(pname) then
			return true
		else
			self._viewers[pname] = nil
		end
	end
	return false
end

local function ensure_detached_inventory(self)
	local inv_name = INV_PREFIX .. self.rover_id
	local rover_id = self.rover_id

	local function allow_access(player)
		local r = moon_rover.auto._rovers_by_id[rover_id]
		if not r or not r.object then
			return false
		end
		local pos = r.object:get_pos()
		if pos and core.is_protected and player and player:is_player() then
			if core.is_protected(pos, player:get_player_name()) then
				return false
			end
		end
		return true
	end

	local function on_change()
		local r = moon_rover.auto._rovers_by_id[rover_id]
		if r then
			r._craft_timer = 0
			r._ui_dirty = true
		end
	end

	local inv = core.create_detached_inventory(inv_name, {
		allow_move = function(inv_ref, from_list, from_index, to_list, to_index, count, player)
			if not allow_access(player) then return 0 end
			if to_list == "furnace_dst" then return 0 end
			return count
		end,
		allow_put = function(inv_ref, listname, index, stack, player)
			if not allow_access(player) then return 0 end
			if listname == "furnace_dst" then return 0 end
			return stack:get_count()
		end,
		allow_take = function(inv_ref, listname, index, stack, player)
			if not allow_access(player) then return 0 end
			return stack:get_count()
		end,
		on_move = on_change,
		on_put = on_change,
		on_take = on_change,
	})

	inv:set_size("main", moon_rover.auto_config.chest_size)
	inv:set_size("furnace_src", 1)
	inv:set_size("furnace_fuel", 1)
	inv:set_size("furnace_dst", 1)
	return inv
end

--------------------------------------------------------------------------------
-- Built-in Oven (Smelting) Engine
--------------------------------------------------------------------------------

local function get_cooking_result(stack)
	if not stack or stack:is_empty() or not core.get_craft_result then
		return nil
	end
	local res = core.get_craft_result({method = "cooking", width = 1, items = {stack}})
	if res and res.time and res.time > 0 and res.item and not res.item:is_empty() then
		return res
	end
	return nil
end

local function get_fuel_result(stack)
	if not stack or stack:is_empty() or not core.get_craft_result then
		return nil
	end
	local name = stack:get_name()
	-- Never burn wool or crafted rovers as oven fuel
	if get_item_group(name, "wool") > 0 or name == AUTO_ENTITY_NAME or name == (moon_rover.modname .. ":rover") then
		return nil
	end
	local res = core.get_craft_result({method = "fuel", width = 1, items = {stack}})
	if res and res.time and res.time > 0 then
		return res
	end
	return nil
end

local function select_fuel_slot_from_main(inv)
	local list = inv:get_list("main")
	if not list then return nil end

	local best_slot = nil
	local best_prio = -1
	for i = 1, #list do
		local st = list[i]
		if st and not st:is_empty() then
			local fuel = get_fuel_result(st)
			if fuel then
				local name = st:get_name()
				local prio = 10
				if name == "default:coal_lump" then
					prio = 100
				elseif name == "default:stick" then
					prio = 80
				elseif get_item_group(name, "wood") > 0 then
					prio = 60
				elseif get_item_group(name, "tree") > 0 then
					prio = 40
				end
				if prio > best_prio then
					best_prio = prio
					best_slot = i
				end
			end
		end
	end
	return best_slot
end

local function select_cookable_slot_from_main(inv, has_abundant_fuel)
	local list = inv:get_list("main")
	if not list then return nil end

	local best_slot = nil
	local best_prio = -1
	for i = 1, #list do
		local st = list[i]
		if st and not st:is_empty() then
			local cook = get_cooking_result(st)
			if cook then
				local name = st:get_name()
				local prio = 0
				if name == "default:iron_lump" then
					prio = 100
				elseif string.find(name, "_lump", 1, true) then
					prio = 70
				elseif has_abundant_fuel and (name == "default:cobble" or name == "default:sand" or name == "default:clay_lump") then
					prio = 20
				end
				if prio > best_prio then
					best_prio = prio
					best_slot = i
				end
			end
		end
	end
	return best_slot
end

function moon_rover.auto.tick_oven(self, dt)
	local inv = self:get_inv()
	if not inv then
		return
	end

	local f = self.state.furnace
	if not f then
		f = {fuel_time = 0, fuel_total = 0, cook_time = 0, cook_total = 0}
		self.state.furnace = f
	end

	-- 1. Pull completed output into 64-slot chest
	local dst = inv:get_stack("furnace_dst", 1)
	if not dst:is_empty() and inv:room_for_item("main", dst) then
		inv:add_item("main", dst)
		inv:set_stack("furnace_dst", 1, ItemStack(""))
		self._ui_dirty = true
	end

	-- 2. Auto-load input from main chest when oven input is empty
	local src = inv:get_stack("furnace_src", 1)
	if src:is_empty() then
		local fuel_stack = inv:get_stack("furnace_fuel", 1)
		local has_fuel = (f.fuel_time > 0) or (not fuel_stack:is_empty() and get_fuel_result(fuel_stack) ~= nil)
			or (select_fuel_slot_from_main(inv) ~= nil)
		if has_fuel then
			local abundant_fuel = count_item(inv, "default:coal_lump") >= 2 or count_item(inv, "default:stick") >= 8
			local slot = select_cookable_slot_from_main(inv, abundant_fuel)
			if slot then
				local take = inv:get_stack("main", slot)
				local one = take:take_item(1)
				inv:set_stack("main", slot, take)
				inv:set_stack("furnace_src", 1, one)
				src = one
				self._ui_dirty = true
			end
		end
	end

	local cook_res = get_cooking_result(src)
	if not cook_res then
		f.cook_time = 0
		f.cook_total = 0
		if f.fuel_time > 0 then
			f.fuel_time = math.max(0, f.fuel_time - dt)
		end
		return
	end

	f.cook_total = cook_res.time

	-- 3. Refuel oven if needed
	if f.fuel_time <= 0 then
		local fuel_stack = inv:get_stack("furnace_fuel", 1)
		if fuel_stack:is_empty() then
			local fslot = select_fuel_slot_from_main(inv)
			if fslot then
				local take = inv:get_stack("main", fslot)
				local one = take:take_item(1)
				inv:set_stack("main", fslot, take)
				inv:set_stack("furnace_fuel", 1, one)
				fuel_stack = one
			end
		end

		local fuel_res = get_fuel_result(fuel_stack)
		if fuel_res then
			fuel_stack:take_item(1)
			inv:set_stack("furnace_fuel", 1, fuel_stack)
			f.fuel_time = fuel_res.time
			f.fuel_total = fuel_res.time
			self._ui_dirty = true
		else
			-- Out of fuel
			return
		end
	end

	-- 4. Advance burning & cooking
	local active_dt = math.min(dt, f.fuel_time)
	f.fuel_time = math.max(0, f.fuel_time - active_dt)
	f.cook_time = f.cook_time + active_dt

	if f.cook_time >= cook_res.time then
		dst = inv:get_stack("furnace_dst", 1)
		local out_item = cook_res.item
		local can_put_dst = dst:is_empty() or (dst:get_name() == out_item:get_name() and dst:item_fits(out_item))
		if can_put_dst then
			src:take_item(1)
			inv:set_stack("furnace_src", 1, src)
			if dst:is_empty() then
				inv:set_stack("furnace_dst", 1, out_item)
			else
				dst:add_item(out_item)
				inv:set_stack("furnace_dst", 1, dst)
			end
			f.cook_time = 0
			-- Immediately pull to main chest if space exists
			local new_dst = inv:get_stack("furnace_dst", 1)
			if not new_dst:is_empty() and inv:room_for_item("main", new_dst) then
				inv:add_item("main", new_dst)
				inv:set_stack("furnace_dst", 1, ItemStack(""))
			end
			self._craft_timer = 0
			self._ui_dirty = true
		end
	end
end

--------------------------------------------------------------------------------
-- Built-in Crafting & Self-Replication Engine
--------------------------------------------------------------------------------

local function try_consume_and_add(inv, inputs, output_str)
	-- Verify all inputs exist
	for i = 1, #inputs do
		local req = inputs[i]
		if count_item(inv, req.name) < req.count then
			return false
		end
	end

	-- Check output fits (allow if at least 1 slot will free up or already room)
	local out_stack = ItemStack(output_str)
	if out_stack:is_empty() then
		return false
	end

	-- Remove exact ingredients
	local removed_list = {}
	for i = 1, #inputs do
		local req = inputs[i]
		local rem = inv:remove_item("main", ItemStack(req.name .. " " .. req.count))
		removed_list[#removed_list + 1] = rem
		if rem:get_count() < req.count then
			-- Rollback cleanly if partial removal ever occurred
			for j = 1, #removed_list do
				inv:add_item("main", removed_list[j])
			end
			return false
		end
	end

	if not inv:room_for_item("main", out_stack) then
		for j = 1, #removed_list do
			inv:add_item("main", removed_list[j])
		end
		return false
	end

	inv:add_item("main", out_stack)
	return true
end

local function craft_single_item_via_engine(inv, item_name, fallback_output)
	local out_str = fallback_output
	if core.get_craft_result then
		local res = core.get_craft_result({
			method = "normal",
			width = 1,
			items = {ItemStack(item_name)},
		})
		if res and res.item and not res.item:is_empty() then
			out_str = res.item:to_string()
		end
	end
	if not out_str then
		return false
	end
	return try_consume_and_add(inv, {{name = item_name, count = 1}}, out_str)
end

local function count_nearby_auto_rovers(pos, radius)
	if not core.get_objects_inside_radius then
		return 1
	end
	local objs = core.get_objects_inside_radius(pos, radius)
	local count = 0
	for i = 1, #objs do
		local ent = objs[i]:get_luaentity()
		if ent and ent.name == AUTO_ENTITY_NAME then
			count = count + 1
		end
	end
	return count
end

local function find_deploy_pos(self, pos)
	local yaw = get_drive_yaw(self)
	local fwd = moon_rover.yaw_to_forward(yaw)
	local right = moon_rover.yaw_to_right(yaw)
	local dirs = {
		{x = fwd.x * 2.0,   z = fwd.z * 2.0},
		{x = right.x * 2.0, z = right.z * 2.0},
		{x = -right.x * 2.0, z = -right.z * 2.0},
		{x = -fwd.x * 2.0,  z = -fwd.z * 2.0},
	}

	for i = 1, #dirs do
		local cx = math.floor(pos.x + dirs[i].x + 0.5)
		local cz = math.floor(pos.z + dirs[i].z + 0.5)
		for dy = 0, 1 do
			local cy = math.floor(pos.y + 0.6) + dy
			local ground = {x = cx, y = cy - 1, z = cz}
			local feet = {x = cx, y = cy, z = cz}
			local head = {x = cx, y = cy + 1, z = cz}
			if is_node_walkable(ground) and not is_node_walkable(feet) and not is_node_walkable(head)
					and not is_in_liquid(feet) then
				if not (core.is_protected and core.is_protected(feet, self.state.owner or "")) then
					return {x = cx, y = cy - 0.48, z = cz}
				end
			end
		end
	end
	return nil
end

function moon_rover.auto.tick_crafting(self)
	local inv = self:get_inv()
	if not inv then
		return false
	end

	local cfg = moon_rover.auto_config
	local did_work = false

	-- 1. Chopped trees -> Planks -> Sticks
	local sticks = count_item(inv, "default:stick")
	local plank_name = find_item_in_group(inv, "wood", 1)
	local tree_name, tree_count = find_item_in_group(inv, "tree", 1)

	if tree_name and (tree_count >= 2 or (not plank_name and sticks < cfg.target_sticks)) then
		if craft_single_item_via_engine(inv, tree_name, "default:wood 4") then
			did_work = true
			plank_name = find_item_in_group(inv, "wood", 1)
		end
	end

	if plank_name and sticks < cfg.target_sticks then
		if craft_single_item_via_engine(inv, plank_name, "default:stick 4") then
			did_work = true
		end
	end

	-- 2. Uncraft steelblock -> 9 steel ingots if needed
	if count_item(inv, "default:steel_ingot") < 1 and count_item(inv, "default:steelblock") >= 1 then
		if try_consume_and_add(inv, {{name = "default:steelblock", count = 1}}, "default:steel_ingot 9") then
			did_work = true
		end
	end

	-- 3. Goal-directed wool & dye crafting for self-replication (4 wool:grey + 1 wool:yellow + 1 steel)
	local need_grey = count_item(inv, "wool:grey") < 4
	local need_yellow = count_item(inv, "wool:yellow") < 1

	if (need_grey or need_yellow) and count_item(inv, "farming:cotton") >= 4 then
		if try_consume_and_add(inv, {{name = "farming:cotton", count = 4}}, "wool:white 1") then
			did_work = true
		end
	end

	if need_yellow then
		if count_item(inv, "dye:yellow") < 1 and count_item(inv, "flowers:dandelion_yellow") >= 1 then
			if try_consume_and_add(inv, {{name = "flowers:dandelion_yellow", count = 1}}, "dye:yellow 4") then
				did_work = true
			end
		end
		if count_item(inv, "wool:white") >= 1 and count_item(inv, "dye:yellow") >= 1 then
			if try_consume_and_add(inv, {
				{name = "wool:white", count = 1},
				{name = "dye:yellow", count = 1},
			}, "wool:yellow 1") then
				did_work = true
			end
		end
	end

	if need_grey then
		if count_item(inv, "dye:grey") < 1 then
			if count_item(inv, "dye:white") < 1 and count_item(inv, "flowers:dandelion_white") >= 1 then
				if try_consume_and_add(inv, {{name = "flowers:dandelion_white", count = 1}}, "dye:white 4") then
					did_work = true
				end
			end
			if count_item(inv, "dye:black") < 1 then
				if count_item(inv, "flowers:tulip_black") >= 1 then
					if try_consume_and_add(inv, {{name = "flowers:tulip_black", count = 1}}, "dye:black 4") then
						did_work = true
					end
				elseif count_item(inv, "default:coal_lump") >= 2 then
					if try_consume_and_add(inv, {{name = "default:coal_lump", count = 1}}, "dye:black 4") then
						did_work = true
					end
				end
			end
			if count_item(inv, "dye:white") >= 1 and count_item(inv, "dye:black") >= 1 then
				if try_consume_and_add(inv, {
					{name = "dye:white", count = 1},
					{name = "dye:black", count = 1},
				}, "dye:grey 2") then
					did_work = true
				end
			end
		end
		if count_item(inv, "wool:white") >= 1 and count_item(inv, "dye:grey") >= 1 then
			if try_consume_and_add(inv, {
				{name = "wool:white", count = 1},
				{name = "dye:grey", count = 1},
			}, "wool:grey 1") then
				did_work = true
			end
		end
	end

	-- 4. Ultimate Goal: Craft a new Autonomous Moon Rover (self!)
	if count_item(inv, "wool:grey") >= 4
			and count_item(inv, "wool:yellow") >= 1
			and count_item(inv, "default:steel_ingot") >= 1 then
		local crafted = try_consume_and_add(inv, {
			{name = "wool:grey", count = 4},
			{name = "wool:yellow", count = 1},
			{name = "default:steel_ingot", count = 1},
		}, AUTO_ENTITY_NAME .. " 1")
		if crafted then
			did_work = true
			self._status = S("Crafted new Moon Rover!")
		end
	end

	-- 5. Deploy crafted Autonomous Moon Rover into the world
	if count_item(inv, AUTO_ENTITY_NAME) >= 1 then
		local pos = self.object and self.object:get_pos()
		if pos and count_nearby_auto_rovers(pos, cfg.nearby_rover_radius) < cfg.max_nearby_rovers then
			local deploy_pos = find_deploy_pos(self, pos)
			if deploy_pos then
				local removed = inv:remove_item("main", ItemStack(AUTO_ENTITY_NAME .. " 1"))
				if not removed:is_empty() then
					local child_static = ""
					if core.write_json then
						child_static = core.write_json({
							version = 1,
							state = {owner = self.state.owner or ""},
						}) or ""
					end
					local child = core.add_entity(deploy_pos, AUTO_ENTITY_NAME, child_static)
					if child then
						child:set_yaw(moon_rover.normalize_yaw(get_drive_yaw(self) + math.pi * 0.5))
						self.state.replication_count = (self.state.replication_count or 0) + 1
						self._status = S("Deployed new Moon Rover!")
						did_work = true
					else
						-- Refund item if spawn failed
						inv:add_item("main", removed)
					end
				end
			end
		end
	end

	if did_work then
		self._ui_dirty = true
	end
	return did_work
end

--------------------------------------------------------------------------------
-- World Scanner, Dropped Item Vacuum & Gathering Execution
--------------------------------------------------------------------------------

local function vacuum_nearby_items(self, pos)
	if not core.get_objects_inside_radius then
		return
	end
	local inv = self:get_inv()
	if not inv then
		return
	end
	local objs = core.get_objects_inside_radius(pos, moon_rover.auto_config.pickup_radius)
	for i = 1, #objs do
		local obj = objs[i]
		local ent = obj:get_luaentity()
		if ent and ent.name == "__builtin:item" and ent.itemstring and ent.itemstring ~= "" then
			local stack = ItemStack(ent.itemstring)
			if not stack:is_empty() and inv:room_for_item("main", stack) then
				local leftover = inv:add_item("main", stack)
				if leftover:is_empty() then
					obj:remove()
				else
					ent.itemstring = leftover:to_string()
				end
				self._craft_timer = 0
				self._ui_dirty = true
			end
		end
	end
end

function moon_rover.auto.scan_for_target(self, pos)
	local cfg = moon_rover.auto_config
	local origin = round_pos(pos)
	local now = self._elapsed or 0
	local blacklist = self._blacklist or {}

	local best_pos = nil
	local best_name = nil
	local best_score = -1e9

	local r = cfg.scan_radius
	for dy = -cfg.scan_height_down, cfg.scan_height_up do
		for dz = -r, r do
			for dx = -r, r do
				-- Never dig directly underneath our own wheels
				if not (dx == 0 and dz == 0 and dy < 0) then
					local p = {x = origin.x + dx, y = origin.y + dy, z = origin.z + dz}
					local key = pos_key(p)
					if not (blacklist[key] and blacklist[key] > now) then
						local node = core.get_node_or_nil(p)
						if node then
							local val = moon_rover.auto.score_node(node.name, self)
							if val then
								if not (core.is_protected and core.is_protected(p, self.state.owner or "")) then
									local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
									local eff = val - dist * 2.5
									if eff > best_score then
										best_score = eff
										best_pos = p
										best_name = node.name
									end
								end
							end
						end
					end
				end
			end
		end
	end

	return best_pos, best_name, best_score
end

local function dig_target_node(self, target_pos)
	local inv = self:get_inv()
	if not inv then
		return false
	end
	local node = core.get_node_or_nil(target_pos)
	if not node or not moon_rover.auto.is_gatherable_node(node.name) then
		return false
	end
	if core.is_protected and core.is_protected(target_pos, self.state.owner or "") then
		return false
	end

	local drops = (core.get_node_drops and core.get_node_drops(node.name, "")) or {node.name}
	-- Verify at least the primary drop fits in the 64-slot chest before digging
	if #drops > 0 and not inv:room_for_item("main", ItemStack(drops[1])) then
		return false
	end

	local dug_name = node.name
	core.remove_node(target_pos)
	moon_rover.auto.record_dug_block(self, dug_name)

	for i = 1, #drops do
		local st = ItemStack(drops[i])
		if not st:is_empty() then
			local leftover = inv:add_item("main", st)
			if not leftover:is_empty() and core.add_item then
				core.add_item(target_pos, leftover)
			end
		end
	end

	self._craft_timer = 0
	self._ui_dirty = true

	-- Smart tree chopping: immediately chain onto trunk block above!
	if get_item_group(dug_name, "tree") > 0 then
		local above = {x = target_pos.x, y = target_pos.y + 1, z = target_pos.z}
		local above_node = core.get_node_or_nil(above)
		if above_node and get_item_group(above_node.name, "tree") > 0
				and not (core.is_protected and core.is_protected(above, self.state.owner or "")) then
			self._target_pos = above
			self._target_name = above_node.name
			self._dig_progress = 0
			return true
		end
	end

	return true
end

--------------------------------------------------------------------------------
-- Autonomous Driving & Obstacle/Hazard Avoidance
--------------------------------------------------------------------------------

local function is_ahead_safe(pos, yaw)
	local fwd = moon_rover.yaw_to_forward(yaw)
	local ahead_x = pos.x + fwd.x * 1.4
	local ahead_z = pos.z + fwd.z * 1.4
	local base_y = math.floor(pos.y + 0.6)

	local feet = {x = ahead_x, y = base_y, z = ahead_z}
	local step_up = {x = ahead_x, y = base_y + 1, z = ahead_z}
	local step_head = {x = ahead_x, y = base_y + 2, z = ahead_z}
	local drop_1 = {x = ahead_x, y = base_y - 1, z = ahead_z}
	local drop_2 = {x = ahead_x, y = base_y - 2, z = ahead_z}

	-- Avoid liquids
	if is_in_liquid(feet) or is_in_liquid(drop_1) then
		return false
	end

	-- 1-block obstacle ahead: safe to drive over if 2 blocks of air above it!
	if is_node_walkable(feet) then
		if not is_node_walkable(step_up) and not is_node_walkable(step_head) then
			return true
		end
		return false
	end

	-- Avoid cliffs deeper than 1 block
	if not is_node_walkable(drop_1) and not is_node_walkable(drop_2) then
		return false
	end

	return true
end

local function steer_towards(current_yaw, desired_yaw, max_turn)
	local diff = moon_rover.normalize_yaw(desired_yaw - current_yaw)
	if math.abs(diff) <= max_turn then
		return desired_yaw, 0
	end
	if diff > 0 then
		return moon_rover.normalize_yaw(current_yaw + max_turn), diff - max_turn
	else
		return moon_rover.normalize_yaw(current_yaw - max_turn), diff + max_turn
	end
end

--------------------------------------------------------------------------------
-- Autonomous Rover Entity Definition
--------------------------------------------------------------------------------

local AutoRoverEntity = {
	initial_properties = {
		physical = true,
		collide_with_objects = true,
		collisionbox = moon_rover.auto_config.collisionbox,
		selectionbox = moon_rover.auto_config.selectionbox,
		visual = "mesh",
		mesh = moon_rover.auto_config.mesh,
		visual_size = moon_rover.auto_config.visual_size,
		textures = moon_rover.auto_config.textures,
		stepheight = moon_rover.auto_config.stepheight,
		backface_culling = false,
		static_save = true,
		hp_max = 100,
	},

	rover_id = nil,
	state = nil,
	speed = 0,
	_inv = nil,
	_viewers = nil,
	_elapsed = 0,
	_scan_timer = 0,
	_craft_timer = 0,
	_ui_timer = 0,
	_ui_dirty = false,
	_roam_timer = 0,
	_roam_yaw = 0,
	_target_pos = nil,
	_target_name = nil,
	_dig_progress = 0,
	_stuck_timer = 0,
	_last_progress_pos = nil,
	_blacklist = nil,
	_status = "Roaming",
	_anim_mode = nil,
	_anim_speed = 0,
}

function AutoRoverEntity:get_inv()
	if not self._inv and self.rover_id then
		self._inv = ensure_detached_inventory(self)
	end
	return self._inv
end

function AutoRoverEntity:on_activate(staticdata, dtime_s)
	self.speed = 0
	self._viewers = {}
	self._elapsed = 0
	self._scan_timer = 0.2
	self._craft_timer = 0.5
	self._ui_timer = 0
	self._ui_dirty = false
	self._roam_timer = 0
	self._target_pos = nil
	self._target_name = nil
	self._dig_progress = 0
	self._stuck_timer = 0
	self._last_progress_pos = self.object:get_pos()
	self._blacklist = {}
	self._status = S("Roaming")
	self._anim_mode = nil
	self._anim_speed = 0

	self.state = {
		owner = "",
		paused = false,
		replication_count = 0,
		total_dug = 0,
		dug_blocks = {},
		furnace = {fuel_time = 0, fuel_total = 0, cook_time = 0, cook_total = 0},
	}

	local saved_inv = nil
	if staticdata and staticdata ~= "" and core.parse_json then
		local decoded = core.parse_json(staticdata)
		if type(decoded) == "table" then
			if type(decoded.rover_id) == "string" and decoded.rover_id ~= "" then
				self.rover_id = decoded.rover_id
			end
			if type(decoded.state) == "table" then
				for k, v in pairs(decoded.state) do
					self.state[k] = v
				end
			end
			saved_inv = decoded.inventory
		end
	end

	if not self.rover_id then
		self.rover_id = generate_rover_id()
	end

	moon_rover.auto._rovers_by_id[self.rover_id] = self
	self._inv = ensure_detached_inventory(self)
	if saved_inv then
		restore_inv(self._inv, saved_inv)
	end

	self._roam_yaw = get_drive_yaw(self)
	self.object:set_armor_groups({immortal = 1})
	self.object:set_acceleration({x = 0, y = -moon_rover.auto_config.gravity, z = 0})
	moon_rover.update_wheel_animation(self, 0, moon_rover.auto_config.wheel_circumference)
end

function AutoRoverEntity:get_staticdata()
	if not core.write_json then
		return ""
	end
	return core.write_json({
		version = 1,
		rover_id = self.rover_id,
		state = self.state or {},
		inventory = serialize_inv(self._inv),
	}) or ""
end

function AutoRoverEntity:on_deactivate(removal)
	if self._viewers and core.close_formspec then
		for pname in pairs(self._viewers) do
			core.close_formspec(pname, FORMSPEC_PREFIX .. (self.rover_id or ""))
		end
	end
	self._viewers = {}
	if self.rover_id then
		if moon_rover.auto._rovers_by_id[self.rover_id] == self then
			moon_rover.auto._rovers_by_id[self.rover_id] = nil
		end
		if core.remove_detached_inventory then
			core.remove_detached_inventory(INV_PREFIX .. self.rover_id)
		end
	end
	self._inv = nil
end

function AutoRoverEntity:on_rightclick(clicker)
	if not clicker or not clicker:is_player() then
		return
	end
	local name = clicker:get_player_name()
	local pos = self.object:get_pos()
	if pos and core.is_protected and core.is_protected(pos, name) then
		if core.record_protection_violation then
			core.record_protection_violation(pos, name)
		end
		return
	end

	self._viewers[name] = true
	if core.show_formspec then
		core.show_formspec(name, FORMSPEC_PREFIX .. self.rover_id, build_formspec(self))
	end
end

function AutoRoverEntity:on_punch(puncher, time_from_last_punch, tool_capabilities, dir, damage)
	if not puncher or not puncher:is_player() then
		return true
	end
	local name = puncher:get_player_name()
	local pos = self.object:get_pos()
	if pos and core.is_protected and core.is_protected(pos, name) then
		if core.record_protection_violation then
			core.record_protection_violation(pos, name)
		end
		return true
	end

	local inv = self:get_inv()
	local empty = is_inventory_completely_empty(inv)
	local ctrl = puncher:get_player_control() or {}

	if not empty and not ctrl.sneak then
		if core.chat_send_player then
			core.chat_send_player(
				name,
				S("Rover chest is not empty. Empty it first, or hold Sneak + punch to drop contents and pick up.")
			)
		end
		return true
	end

	-- Drop stored items on Sneak+punch
	if not empty and pos and core.add_item then
		for _, listname in ipairs({"main", "furnace_src", "furnace_fuel", "furnace_dst"}) do
			local list = inv:get_list(listname)
			if list then
				for i = 1, #list do
					local st = list[i]
					if st and not st:is_empty() then
						core.add_item(pos, st)
					end
				end
			end
		end
	end

	local pinv = puncher:get_inventory()
	local is_creative = core.is_creative_enabled and core.is_creative_enabled(name)
	if pinv then
		if not (is_creative and pinv:contains_item("main", AUTO_ENTITY_NAME)) then
			local leftover = pinv:add_item("main", AUTO_ENTITY_NAME)
			if leftover and not leftover:is_empty() and pos and core.add_item then
				core.add_item(pos, leftover)
			end
		end
	elseif pos and core.add_item then
		core.add_item(pos, AUTO_ENTITY_NAME)
	end

	self.object:remove()
	return true
end

function AutoRoverEntity:on_step(dtime, moveresult)
	local dt = math.min(math.max(dtime or 0, 0), 0.1)
	if dt <= 0 then
		return
	end

	local cfg = moon_rover.auto_config
	self._elapsed = (self._elapsed or 0) + dt

	local pos = self.object:get_pos()
	if not pos then
		return
	end
	local vel = self.object:get_velocity() or {x = 0, y = 0, z = 0}

	-- Always tick oven & periodic crafting/replication even while UI is open
	moon_rover.auto.tick_oven(self, dt)

	self._craft_timer = (self._craft_timer or 0) - dt
	if self._craft_timer <= 0 then
		self._craft_timer = cfg.craft_interval
		moon_rover.auto.tick_crafting(self)
	end

	-- Vacuum dropped items within reach
	vacuum_nearby_items(self, pos)

	-- Refresh open chest UIs periodically
	self._ui_timer = (self._ui_timer or 0) + dt
	if has_open_viewers(self) and (self._ui_dirty or self._ui_timer >= 0.5) then
		self._ui_dirty = false
		self._ui_timer = 0
		refresh_viewers(self)
	end

	-- Pause movement if manually paused or while a player has the chest UI open
	if self.state.paused or has_open_viewers(self) then
		self.speed = 0
		self.object:set_velocity({x = 0, y = vel.y, z = 0})
		moon_rover.update_wheel_animation(self, 0, cfg.wheel_circumference)
		return
	end

	-- Validate current target
	if self._target_pos then
		local tnode = core.get_node_or_nil(self._target_pos)
		if not tnode or not moon_rover.auto.is_gatherable_node(tnode.name) then
			self._target_pos = nil
			self._target_name = nil
			self._dig_progress = 0
		end
	end

	-- Periodically scan for higher-value / closer targets
	self._scan_timer = (self._scan_timer or 0) - dt
	if self._scan_timer <= 0 then
		self._scan_timer = cfg.scan_interval
		local cand_pos, cand_name = moon_rover.auto.scan_for_target(self, pos)
		if cand_pos then
			-- Switch if no target or new target has meaningfully higher value
			if not self._target_pos then
				self._target_pos = cand_pos
				self._target_name = cand_name
				self._dig_progress = 0
				self._stuck_timer = 0
				self._last_progress_pos = {x = pos.x, y = pos.y, z = pos.z}
			else
				local cur_score = moon_rover.auto.score_node(self._target_name, self) or 0
				local new_score = moon_rover.auto.score_node(cand_name, self) or 0
				if new_score > cur_score + 15 then
					self._target_pos = cand_pos
					self._target_name = cand_name
					self._dig_progress = 0
					self._stuck_timer = 0
					self._last_progress_pos = {x = pos.x, y = pos.y, z = pos.z}
				end
			end
		end
	end

	local yaw = get_drive_yaw(self)

	-- Case 1: Have a target node -> approach and gather
	if self._target_pos then
		local dx = self._target_pos.x - pos.x
		local dz = self._target_pos.z - pos.z
		local dy = self._target_pos.y - pos.y
		local dist_xz = math.sqrt(dx * dx + dz * dz)

		if dist_xz <= cfg.gather_reach_xz and dy >= -1.6 and dy <= cfg.gather_reach_y then
			-- In digging range: stop wheels and harvest the node
			self.speed = 0
			self.object:set_velocity({x = 0, y = vel.y, z = 0})
			moon_rover.update_wheel_animation(self, 0, cfg.wheel_circumference)

			if dist_xz > 0.1 then
				local face_yaw = moon_rover.atan2(-dx, dz)
				yaw = steer_towards(yaw, face_yaw, cfg.turn_speed * dt)
				set_drive_yaw(self, yaw)
			end

			self._status = S("Gathering: ") .. (self._target_name or "")
			self._dig_progress = (self._dig_progress or 0) + dt
			if self._dig_progress >= cfg.dig_time_base then
				local prev_target = self._target_pos
				local dug = dig_target_node(self, prev_target)
				-- If dig_target_node chained onto next tree trunk above, keep _target_pos; else clear
				if self._target_pos == prev_target then
					if not dug then
						self._blacklist[pos_key(prev_target)] = self._elapsed + 15
					end
					self._target_pos = nil
					self._target_name = nil
					self._dig_progress = 0
				end
			end
			return
		end

		-- Drive toward target
		local desired_yaw = moon_rover.atan2(-dx, dz)
		yaw = steer_towards(yaw, desired_yaw, cfg.turn_speed * dt)
		set_drive_yaw(self, yaw)

		-- Check stuck timeout
		if self._last_progress_pos then
			local moved = math.sqrt(
				(pos.x - self._last_progress_pos.x)^2 +
				(pos.z - self._last_progress_pos.z)^2
			)
			if moved >= 0.35 then
				self._last_progress_pos = {x = pos.x, y = pos.y, z = pos.z}
				self._stuck_timer = 0
			else
				self._stuck_timer = (self._stuck_timer or 0) + dt
				if self._stuck_timer >= cfg.stuck_timeout then
					self._blacklist[pos_key(self._target_pos)] = self._elapsed + 15
					self._target_pos = nil
					self._target_name = nil
					self._stuck_timer = 0
					self._roam_yaw = moon_rover.normalize_yaw(yaw + math.pi * 0.65)
					self._roam_timer = 2.0
				end
			end
		end

		if self._target_pos then
			if is_ahead_safe(pos, yaw) then
				self.speed = cfg.drive_speed
				self._status = S("Moving to: ") .. (self._target_name or "")
			else
				-- Steer around cliff/liquid/2-high wall
				yaw = moon_rover.normalize_yaw(yaw + cfg.turn_speed * dt)
				set_drive_yaw(self, yaw)
				self.speed = cfg.drive_speed * 0.35
			end
			local fwd = moon_rover.yaw_to_forward(yaw)
			self.object:set_velocity({x = fwd.x * self.speed, y = vel.y, z = fwd.z * self.speed})
			moon_rover.update_wheel_animation(self, self.speed, cfg.wheel_circumference)
			return
		end
	end

	-- Case 2: Autonomous Roaming (exploring for materials)
	self._status = S("Roaming")
	self._roam_timer = (self._roam_timer or 0) - dt
	if self._roam_timer <= 0 then
		self._roam_timer = 2.5 + math.random() * 3.0
		self._roam_yaw = moon_rover.normalize_yaw(yaw + (math.random() - 0.5) * 1.6)
	end

	if not is_ahead_safe(pos, yaw) then
		self._roam_yaw = moon_rover.normalize_yaw(yaw + 1.2)
		self._roam_timer = 1.5
		self.speed = 0
	else
		self.speed = cfg.drive_speed * 0.85
	end

	yaw = steer_towards(yaw, self._roam_yaw, cfg.turn_speed * dt)
	set_drive_yaw(self, yaw)
	local fwd = moon_rover.yaw_to_forward(yaw)
	self.object:set_velocity({x = fwd.x * self.speed, y = vel.y, z = fwd.z * self.speed})
	moon_rover.update_wheel_animation(self, self.speed, cfg.wheel_circumference)
end

core.register_entity(AUTO_ENTITY_NAME, AutoRoverEntity)

--------------------------------------------------------------------------------
-- Formspec Field Handling & Player Leave Cleanup
--------------------------------------------------------------------------------

if core.register_on_player_receive_fields then
	core.register_on_player_receive_fields(function(player, formname, fields)
		if string.sub(formname, 1, #FORMSPEC_PREFIX) ~= FORMSPEC_PREFIX then
			return false
		end
		local rover_id = string.sub(formname, #FORMSPEC_PREFIX + 1)
		local rover = moon_rover.auto._rovers_by_id[rover_id]
		local pname = player:get_player_name()

		if not rover then
			return true
		end

		if fields.quit then
			if rover._viewers then
				rover._viewers[pname] = nil
			end
			return true
		end

		if fields.toggle_pause then
			rover.state.paused = not rover.state.paused
			refresh_viewers(rover)
		elseif fields.refresh then
			refresh_viewers(rover)
		end

		return true
	end)
end

if core.register_on_leaveplayer then
	core.register_on_leaveplayer(function(player)
		local pname = player:get_player_name()
		for _, rover in pairs(moon_rover.auto._rovers_by_id) do
			if rover._viewers then
				rover._viewers[pname] = nil
			end
		end
	end)
end
