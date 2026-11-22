-- Craftable & placeable Moon Rover items + crafting recipes
-- Copyright (c) 2026 ronrob-lu (MIT License)

local core = rawget(_G, "core") or minetest
local S = moon_rover.S

local DRIVABLE_NAME = moon_rover.modname .. ":rover"
local AUTO_NAME = moon_rover.modname .. ":auto_rover"

local function is_space_clear_for_rover(pos)
	for dy = 0, 1 do
		local check_pos = {x = pos.x, y = pos.y + dy, z = pos.z}
		local node = core.get_node_or_nil(check_pos)
		if not node then
			return false
		end
		local def = core.registered_nodes[node.name]
		if def and def.walkable and not def.buildable_to then
			return false
		end
	end
	return true
end

local function make_rover_on_place(entity_name, yaw_offset, with_owner_staticdata)
	return function(itemstack, placer, pointed_thing)
		if not pointed_thing or pointed_thing.type ~= "node" then
			return itemstack
		end

		local under = pointed_thing.under
		local above = pointed_thing.above

		-- Respect right-click handlers on pointed nodes (chests, doors, etc.) unless sneaking
		local under_node = core.get_node_or_nil(under)
		local under_def = under_node and core.registered_nodes[under_node.name]
		if under_def and under_def.on_rightclick and
				not (placer and placer:is_player() and placer:get_player_control().sneak) then
			return under_def.on_rightclick(under, under_node, placer, itemstack, pointed_thing) or itemstack
		end

		local placer_name = (placer and placer:is_player()) and placer:get_player_name() or ""
		if core.is_protected and core.is_protected(above, placer_name) then
			if core.record_protection_violation then
				core.record_protection_violation(above, placer_name)
			end
			return itemstack
		end

		if not is_space_clear_for_rover(above) then
			if placer_name ~= "" and core.chat_send_player then
				core.chat_send_player(placer_name, S("Not enough room to deploy the Moon Rover here."))
			end
			return itemstack
		end

		local spawn_pos = {
			x = above.x,
			y = above.y - 0.48,
			z = above.z,
		}

		local staticdata = ""
		if with_owner_staticdata and placer_name ~= "" and core.write_json then
			staticdata = core.write_json({
				version = 1,
				state = {owner = placer_name},
			}) or ""
		end

		local obj = core.add_entity(spawn_pos, entity_name, staticdata)
		if not obj then
			return itemstack
		end

		if placer and placer:is_player() and placer.get_look_horizontal then
			local look_yaw = placer:get_look_horizontal() or 0
			obj:set_yaw(moon_rover.normalize_yaw(look_yaw + (yaw_offset or 0)))
		end

		local is_creative = core.is_creative_enabled and core.is_creative_enabled(placer_name)
		if not is_creative then
			itemstack:take_item(1)
		end

		return itemstack
	end
end

-- 1. Drivable Moon Rover (Quaternius CC0)
core.register_craftitem(DRIVABLE_NAME, {
	description = S("Moon Rover"),
	inventory_image = "moon_rover_inv.png",
	wield_image = "moon_rover_inv.png",
	stack_max = 1,
	on_place = make_rover_on_place(DRIVABLE_NAME, moon_rover.config.model_yaw_offset, false),
})

core.register_craft({
	output = DRIVABLE_NAME,
	recipe = {
		{"wool:grey", "default:sign_wall_steel", "wool:grey"},
		{"",          "default:steel_ingot",     ""},
		{"wool:grey", "",                        "wool:grey"},
	},
})

-- 2. Autonomous Moon Rover (Kenney.nl CC0)
core.register_craftitem(AUTO_NAME, {
	description = S("Autonomous Moon Rover"),
	inventory_image = "moon_rover_auto_inv.png",
	wield_image = "moon_rover_auto_inv.png",
	stack_max = 1,
	on_place = make_rover_on_place(AUTO_NAME, moon_rover.auto_config.model_yaw_offset, true),
})

core.register_craft({
	output = AUTO_NAME,
	recipe = {
		{"wool:grey", "wool:yellow",         "wool:grey"},
		{"",          "default:steel_ingot", ""},
		{"wool:grey", "",                    "wool:grey"},
	},
})
