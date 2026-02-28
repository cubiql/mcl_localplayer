------------------------------------------------------------------------
-- Wielditem placement.
------------------------------------------------------------------------

local function get_placement_class_1 (item, name_of_pointed_thing)
	local itemname = type (item) == "string"
		and item
		or (item:is_empty () and "default" or item:get_name ())
	local place_def = mcl_localplayer.item_defs[itemname]
	while type (place_def) == "string" do
		place_def = mcl_localplayer.item_defs[place_def]
	end

	if place_def then
		local special_type = place_def[name_of_pointed_thing]
		if not special_type and place_def.inherit then
			special_type
				= get_placement_class_1 (place_def.inherit,
							 name_of_pointed_thing)
		end

		return special_type or place_def.default
	end

	return nil
end

local function get_placement_class (item, name_of_pointed_thing)
	local class = get_placement_class_1 (item, name_of_pointed_thing)
		or "undefined"

	if class == "food" then
		-- If it is not permissible to eat at present and the
		-- class is `food', return `undefined' in order that
		-- the offhand item may be selected if one exists.

		local _, hunger, _ = mcl_localplayer.get_player_vitals ()
		if hunger >= 20 and not mcl_localplayer.is_creative_enabled () then
			return "undefined"
		end
	end
	return class
end

local localplayer = mcl_localplayer.localplayer
local item_being_placed = nil
local offhand_placed = false
local item_class = nil
local item_use_time = 0.0
local item_enchantments = nil

function mcl_localplayer.handle_offhand_item (stack)
	localplayer.offhand_item = stack

	if mcl_localplayer.debug then
		print ("  New offhand item: " .. stack:to_string ())
	end

	if offhand_placed and item_being_placed
		and not stack:equals (item_being_placed) then
		mcl_localplayer.unuse_item ()
	end
end

local function enable_shield (offhand_p)
	if not offhand_p then
		mcl_localplayer.send_shieldctrl (2)
		localplayer.blocking = 2
	else
		mcl_localplayer.send_shieldctrl (1)
		localplayer.blocking = 1
	end
end

function mcl_localplayer.use_item_locally (itemstack, class, offhand)
	if item_being_placed then
		mcl_localplayer.unuse_item ()
	end

	if class == "shield" then
		if localplayer.shield_timeout <= 0 then
			enable_shield (offhand)
		end
	elseif class == "food" then
		local _, hunger, _ = mcl_localplayer.get_player_vitals ()
		if offhand or (hunger >= 20
				and not mcl_localplayer.is_creative_enabled ()) then
			return false
		end
	elseif class == "bow"
		or class == "food_edible_whilst_full" then
		if offhand then
			return false
		end
	elseif (class == "trident" and mcl_localplayer.proto >= 4) then
		item_enchantments = mcl_localplayer.get_enchantments (itemstack)
		if offhand or (item_enchantments["riptide"]
			       and mcl_localplayer.is_riptide_unavailable ()) then
			return false
		end
	end

	item_being_placed = itemstack
	item_class = class
	item_use_time = 0.0
	offhand_placed = offhand
	return true
end

function mcl_localplayer.use_shield_belatedly ()
	if item_class == "shield" then
		enable_shield (offhand_placed)
	end
end

function mcl_localplayer.disable_shield ()
	if item_class == "shield" and localplayer.blocking ~= 0 then
		mcl_localplayer.send_shieldctrl (0)
		localplayer.blocking = 0
	end
end

function mcl_localplayer.unuse_item ()
	item_being_placed = nil

	if item_class == "shield" then
		mcl_localplayer.send_shieldctrl (0)
		localplayer.blocking = 0
	end

	item_class = nil
	item_use_time = 0.0
end

function mcl_localplayer.intercept_wielditem_placement (item, pointed_thing)
	local control = core.localplayer:get_control ()
	local offhand = false
	if mcl_localplayer.proto < 1 then
		return false
	elseif pointed_thing.type == "node" and not control.sneak then
		local node = core.get_node_or_nil (pointed_thing.under)
		if node then
			local name = node.name
			local class = get_placement_class (item, name)
			if class == "default" then
				return false
			elseif class == "undefined" then
				-- What about the offhand item?
				class = get_placement_class (localplayer.offhand_item, name)
				if class == "default" or class == "undefined" then
					return false
				end
				item = localplayer.offhand_item
				offhand = true
			end

			return mcl_localplayer.use_item_locally (item, class, offhand)
		end
	elseif pointed_thing.type == "object" and not control.sneak then
		local name = pointed_thing.ref:get_name ()
		if name then
			local class = get_placement_class (item, name)
			if class == "default" then
				return false
			elseif class == "undefined" then
				-- What about the offhand item?
				class = get_placement_class (localplayer.offhand_item, name)
				if class == "default" or class == "undefined" then
					return false
				end
				item = localplayer.offhand_item
				offhand = true
			end

			return mcl_localplayer.use_item_locally (item, class, offhand)
		end
	else
		local class = get_placement_class (item, "default")
		if class == "default" then
			return false
		elseif class == "undefined" then
			class = get_placement_class (localplayer.offhand_item, "default")
			if class == "default" or class == "undefined" then
				return false
			end
			item = localplayer.offhand_item
			offhand = true
		end

		if offhand and control.sneak then
			return false
		end

		return mcl_localplayer.use_item_locally (item, class, offhand)
	end
end

------------------------------------------------------------------------
-- Wieldmesh animations.  Eating, crossbows, and the like.
------------------------------------------------------------------------

local FOOD_POSITION = vector.new (0, -30, 55)
local FOOD_ROTATION = vector.new (-30, 10, 10)
local NORMAL_EAT_DELAY = 1.6

local wieldmesh_overridden = false

local function animate_wieldmesh (dtime)
	local proto = mcl_localplayer.proto
	item_use_time = item_use_time + dtime

	if item_class == "food" or item_class == "food_edible_whilst_full" then
		local stack = item_being_placed
		if not wieldmesh_overridden then
			core.camera:override_wieldmesh (FOOD_POSITION,
							FOOD_ROTATION,
							0.1 - item_use_time)
		end

		local time = math.max (0, item_use_time - 0.1)

		if time > 0 then
			local offset = math.sin (time * math.pi / 0.1) * 5.0
			local pos = vector.offset (FOOD_POSITION, 0, offset, 0)
			core.camera:override_wieldmesh (pos, FOOD_ROTATION, 0.0)
		end

		wieldmesh_overridden = true

		if item_use_time >= NORMAL_EAT_DELAY
			or (stack:get_name () == "mcl_ocean:dried_kelp"
				and item_use_time >= NORMAL_EAT_DELAY * 0.5) then
			local index = core.localplayer:get_wield_index ()
			item_use_time = 0.0
			core.camera:reset_wieldmesh_override (0.0)
			mcl_localplayer.send_eat_item (item_being_placed, index)
		end
	elseif proto >= 4 and item_class == "trident" then
		mcl_localplayer.animate_trident_wieldmesh (item_use_time)
	elseif proto < 4
		or not mcl_localplayer.animate_trident_wieldmesh (0.0) then
		if wieldmesh_overridden then
			wieldmesh_overridden = false
			core.camera:reset_wieldmesh_override (0.0)
		end
	end
end

function mcl_localplayer.is_using_food ()
	return item_class == "food"
		or item_class == "food_edible_whilst_full"
end

function mcl_localplayer.is_using_trident ()
	return item_class == "trident"
		and mcl_localplayer.proto >= 4
end

function mcl_localplayer.get_item_use_time ()
	return item_use_time
end

------------------------------------------------------------------------
-- Enchantment parser.
------------------------------------------------------------------------

function mcl_localplayer.get_enchantments (stack)
	local key = "mcl_enchanting:enchantments"
	local tbl = core.deserialize (stack:get_meta ():get_string (key))
	return tbl or {}
end

------------------------------------------------------------------------
-- Usable wielditems, in particular, bows and tridents.
------------------------------------------------------------------------

local current_wielditem = {
	slot = nil,
	name = nil,
}

local is_bow = {}
local is_crossbow = {}
local is_trident = {}
local bow_capabilities = {
	infinity = false,
	charge_time = 1.0,
}

local ammo_available = 0
local last_challenge = 0
local inventory = nil
local use_time = 0
local current_image = nil
local using_bow_visually = false

function mcl_localplayer.init_bows (bows)
	is_bow = bows
	is_crossbow = bows.is_crossbow
	bows.is_crossbow = nil
end

function mcl_localplayer.init_tridents (tridents)
	is_trident = tridents
end

local function do_release (usetime)
	if usetime > 0 then
		last_challenge = last_challenge + 1
		mcl_localplayer.send_release_useitem (usetime, last_challenge)
		if not bow_capabilities.infinity
			and not mcl_localplayer.is_creative_enabled () then
			ammo_available = math.max (ammo_available - 1, 0)
			if mcl_localplayer.debug then
				print (string.format ("Ammo count: %d", ammo_available))
			end
		end
	end
end

local function get_image_for_dtime (info, use_time)
	local scale = bow_capabilities.charge_time
	if info.charge_time_half * scale > use_time then
		return info.texture_0, info.texture_0_wielditem
	elseif info.charge_time_full * scale > use_time then
		return info.texture_1, info.texture_1_wielditem
	else
		return info.texture_2, info.texture_2_wielditem
	end
end

local BOW_FOV_FACTOR = "mcl_localplayer:bow_fov_factor"

function mcl_localplayer.item_globalstep (dtime)
	local stack = core.localplayer:get_wielded_item ()
	-- Read player controls.
	local controls = core.localplayer:get_control ()
	local allow_bows = mcl_localplayer.proto < 1

	if item_being_placed then
		allow_bows = not offhand_placed and item_class == "bow"
		local stack_unchanged_p = stack:equals (item_being_placed)

		if item_class == "trident" and mcl_localplayer.proto >= 4
			and stack_unchanged_p and not controls.place then
			if item_use_time > 0.50 then
				mcl_localplayer.send_release_trident_item ()
			end
			mcl_localplayer.unuse_item ()
		elseif (not offhand_placed and not stack_unchanged_p)
			or not controls.place then
			-- Allow uninterrupted eating of a single
			-- stack of food.
			local old_name = item_being_placed:get_name ()
			local old_count = item_being_placed:get_count ()
			if (item_class ~= "food"
			    and item_class ~= "food_edible_whilst_full")
				or old_name ~= stack:get_name ()
				or old_count ~= (stack:get_count () + 1) then
				mcl_localplayer.unuse_item ()
			else
				item_being_placed = stack
			end
		end

		if item_class == "food" then
			local _, hunger, _
				= mcl_localplayer.get_player_vitals ()
			if hunger >= 20
				and not mcl_localplayer.is_creative_enabled () then
				mcl_localplayer.unuse_item ()
			end
		end
	end

	animate_wieldmesh (dtime)

	local index = core.localplayer:get_wield_index ()
	local name = stack:get_name ()
	local info = is_bow[name]

	if name ~= current_wielditem.name or index ~= current_wielditem.slot then
		local old_stack = current_wielditem.slot
		if old_stack then
			-- Clear metadata overrides on the previous wielditem.
			inventory:set_stack_meta ("main", old_stack, nil)
		end
		-- Switch to this new wielditem.
		current_wielditem.slot = index
		current_wielditem.name = name
		ammo_available = 0
		use_time = 0
		using_bow_visually = is_crossbow[name]

		if info then
			last_challenge = last_challenge + 1
			mcl_localplayer.send_get_ammo (last_challenge)
		end

		if current_image then
			mcl_localplayer.clear_fov_factor (BOW_FOV_FACTOR)
			current_image = nil

			if old_stack then
				inventory:set_stack_meta ("main", old_stack, nil)
				mcl_localplayer.send_visual_wielditem ("")
			end
		end
	end

	mcl_localplayer.check_spyglass ()

	if not allow_bows and use_time == 0 then
		return
	end

	if info then
		if ammo_available <= 0
			and not mcl_localplayer.is_creative_enabled () then
			use_time = 0
		else
			if controls.place then
				use_time = use_time + dtime
			else
				do_release (use_time)
				use_time = 0
			end
		end
		if use_time > 0 then
			local image, wield = get_image_for_dtime (info, use_time)
			if image ~= current_image then
				local stack = ItemStack ()
				local meta = stack:get_meta ()
				meta:set_string ("inventory_image", image)
				inventory:set_stack_meta ("main", index, stack)
				current_image = image
				core.camera:update_wield_item (false)
				mcl_localplayer.send_visual_wielditem (wield)
			end
			-- Crossbow usage doesn't adjust the FOV in
			-- Minecraft.
			if not info.texture_loaded then
				local pct = math.min (1.0, use_time / info.charge_time_full)
				mcl_localplayer.add_fov_factor (BOW_FOV_FACTOR, -0.2 * pct)
			end
		else
			if current_image then
				current_image = nil
				inventory:set_stack_meta ("main", index, nil)
				core.camera:update_wield_item (false)
				mcl_localplayer.clear_fov_factor (BOW_FOV_FACTOR)
				mcl_localplayer.send_visual_wielditem ("")
			end
		end
	end
end

function mcl_localplayer.do_ammoctrl (ammo, challenge)
	if challenge < last_challenge then
		-- Reject this outdated server response.
		return false
	end

	if mcl_localplayer.debug then
		print (string.format ("Ammo count: %d -> %d",
				ammo_available, ammo))
	end
	ammo_available = ammo
end

function mcl_localplayer.do_bow_capabilities (challenge, caps)
	if challenge < last_challenge then
		-- Reject this outdated server response.
		return false
	end
	bow_capabilities.infinity = caps.infinity
	bow_capabilities.charge_time = caps.charge_time
	if mcl_localplayer.debug then
		print (string.format ("Bow capabilities:\n  infinity: %s\n  charge_time: %s",
				caps.infinity, caps.charge_time))
	end
end

function mcl_localplayer.is_using_bow ()
	return use_time > 0
end

function mcl_localplayer.is_using_bow_visually ()
	return use_time > 0 or using_bow_visually
end

-- Trident mechanics.

function mcl_localplayer.is_riptide_unavailable ()
	return not localplayer:is_underwater ()
		and not localplayer.riptide_eligible
end

-- Trident animations.

local TRIDENT_POSITION = vector.new (0, -35, -40)
local TRIDENT_ROTATION = vector.new (0, 0, 0)
local TRIDENT_POSITION_INITIAL = vector.new (65, 35, 35)
local TRIDENT_ROTATION_INITIAL = vector.new (75, 0, 90)
local TRIDENT_POSITION_FINAL = vector.new (65, 55, 15)
local v = vector.zero ()
local trident_phase = 0

function mcl_localplayer.animate_trident_wieldmesh (dtime)
	if dtime == 0.0 and is_trident[current_wielditem.name] then
		core.camera:override_wieldmesh (TRIDENT_POSITION, TRIDENT_ROTATION, 0.0, true)
		trident_phase = 0
		wieldmesh_overridden = true
		return true
	elseif dtime > 0.0 and dtime <= 0.10 then
		if trident_phase == 0 then
			core.camera:override_wieldmesh (TRIDENT_POSITION_INITIAL,
							TRIDENT_ROTATION_INITIAL,
							0.10 - dtime, false)
			wieldmesh_overridden = true
			trident_phase = 1
		end
		return true
	elseif dtime > 0.10 and dtime <= 0.50 then
		if trident_phase == 1 then
			core.camera:override_wieldmesh (TRIDENT_POSITION_FINAL,
							TRIDENT_ROTATION_INITIAL,
							0.50 - dtime, false)
			wieldmesh_overridden = true
			trident_phase = 2
		end
		return true
	elseif dtime > 0.50 then
		v.x = TRIDENT_POSITION_FINAL.x
		v.y = TRIDENT_POSITION_FINAL.y
		v.z = TRIDENT_POSITION_FINAL.z
			+ math.sin ((dtime - 0.50) * math.pi * 8) * 1.0
		core.camera:override_wieldmesh (v, TRIDENT_ROTATION_INITIAL,
						0.0, false)
		wieldmesh_overridden = true
		trident_phase = 3
		return true
	end
	return false
end

------------------------------------------------------------------------
-- Wielditem initialization.
------------------------------------------------------------------------

core.register_globalstep (function (dtime)
	if mcl_localplayer.localplayer_initialized then
		if not inventory then
			inventory = core.localplayer:get_inventory ()
		end
		mcl_localplayer.item_globalstep (dtime)
	end
end)

core.register_on_item_use (function (item, pointed_thing)
	if mcl_localplayer.localplayer_initialized then
		local name = item:get_name ()
		if is_bow[name] then
			return true
		end
	end
	return false
end)

core.register_on_item_place (function (item, pointed_thing)
	if mcl_localplayer.localplayer_initialized then
		local name = item:get_name ()
		if is_bow[name] and mcl_localplayer.proto < 1 then
			return true
		end

		return mcl_localplayer.intercept_wielditem_placement (item, pointed_thing)
	end
	return false
end)

------------------------------------------------------------------------
-- Spyglass.
------------------------------------------------------------------------

local SPYGLASS_FOV_MODIFIER = "mcl_localplayer:spyglass"
local spyglass_active = nil

local spyglass_hud = {
	type = "image",
	position = {x = 0.5, y = 0.5},
	scale = {x = -100, y = -100},
	text = "mcl_spyglass_scope.png",
}

function mcl_localplayer.check_spyglass ()
	local spyglass_enabled
		= current_wielditem.name == "mcl_spyglass:spyglass"
	if spyglass_enabled then
		local controls = core.localplayer:get_control ()
		spyglass_enabled = controls.zoom or controls.place
	end
	if spyglass_enabled then
		if not spyglass_active then
			mcl_localplayer.add_fov_factor (SPYGLASS_FOV_MODIFIER, -20.0)
			spyglass_active = core.localplayer:hud_add (spyglass_hud)
		end
	elseif spyglass_active then
		mcl_localplayer.clear_fov_factor (SPYGLASS_FOV_MODIFIER)
		core.localplayer:hud_remove (spyglass_active)
		spyglass_active = nil
	end
end
