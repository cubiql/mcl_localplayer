------------------------------------------------------------------------
-- Usable wielditems, in particular, bows.
------------------------------------------------------------------------

local current_wielditem = {
	slot = nil,
	name = nil,
}

local is_bow = {}
local is_crossbow = {}
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
	local index = core.localplayer:get_wield_index () + 1
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

	if info then
		if ammo_available <= 0
			and not mcl_localplayer.is_creative_enabled () then
			use_time = 0
		else
			-- Read player controls.
			local controls = core.localplayer:get_control ()
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
	mcl_localplayer.check_spyglass (controls)
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
		if is_bow[name] then
			return true
		end
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
		spyglass_enabled = controls.zoom or controls.use
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
