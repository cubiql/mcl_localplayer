mcl_localplayer = {
	debug = true,
}
local modname = core.get_current_modname ()
print ("*** Loading Mineclonia CSM")

dofile (minetest.get_modpath (modname) .. "/miniflowlib.lua")
dofile (minetest.get_modpath (modname) .. "/player.lua")
dofile (minetest.get_modpath (modname) .. "/items.lua")

------------------------------------------------------------------------
-- Client-server communication.
------------------------------------------------------------------------

local PROTO_VERSION = 0

-- Serverbound messages.
local SERVERBOUND_HELLO = 'aa'
local SERVERBOUND_PLAYERPOSE = 'ab'
local SERVERBOUND_MOVEMENT_STATE = 'ac'
local SERVERBOUND_MOVEMENT_EVENT = 'ad'
local SERVERBOUND_PLAYERANIM = 'ae'
local SERVERBOUND_DAMAGE = 'af'
local SERVERBOUND_GET_AMMO = 'ag'
local SERVERBOUND_RELEASE_USEITEM = 'ah'
local SERVERBOUND_VISUAL_WIELDITEM = 'ai'

-- Clientbound messages.
local CLIENTBOUND_HELLO = 'AA'
local CLIENTBOUND_PLAYER_CAPABILITIES = 'AB'
local CLIENTBOUND_ROCKET_USE = 'AC'
local CLIENTBOUND_REGISTER_ATTRIBUTE_MODIFIER = 'AD'
local CLIENTBOUND_REMOVE_ATTRIBUTE_MODIFIER = 'AE'
local CLIENTBOUND_REGISTER_STATUS_EFFECT = 'AF'
local CLIENTBOUND_REMOVE_STATUS_EFFECT = 'AG'
local CLIENTBOUND_POSECTRL = 'AH'
local CLIENTBOUND_SHIELDCTRL = 'AI'
local CLIENTBOUND_AMMOCTRL = 'AJ'
local CLIENTBOUND_BOW_CAPABILITIES = 'AK'

-- Payload parameters.
local MAX_PAYLOAD = 65533

function mcl_localplayer.send (message)
	assert (#message <= 65536)
	if mcl_localplayer.debug then
		print (" client->server " .. message .. "\n")
	end
	mcl_localplayer.modchannel:send_all (message)
end

function mcl_localplayer.send_playerpose (pose)
	mcl_localplayer.send (SERVERBOUND_PLAYERPOSE .. pose)
end

function mcl_localplayer.send_movement_state (state)
	local json = core.write_json (state)
	mcl_localplayer.send (SERVERBOUND_MOVEMENT_STATE .. json)
end

function mcl_localplayer.send_movement_event (event)
	mcl_localplayer.send (SERVERBOUND_MOVEMENT_EVENT .. event)
end

function mcl_localplayer.send_playeranim (animname)
	mcl_localplayer.send (SERVERBOUND_PLAYERANIM .. animname)
end

function mcl_localplayer.send_damage (damage)
	local damage = core.write_json (damage)
	mcl_localplayer.send (SERVERBOUND_DAMAGE .. damage)
end

function mcl_localplayer.send_get_ammo (challenge)
	mcl_localplayer.send (SERVERBOUND_GET_AMMO .. challenge)
end

function mcl_localplayer.send_release_useitem (usetime, challenge)
	local msg = SERVERBOUND_RELEASE_USEITEM
		.. usetime .. ',' .. challenge
	mcl_localplayer.send (msg)
end

function mcl_localplayer.send_visual_wielditem (wielditem)
	mcl_localplayer.send (SERVERBOUND_VISUAL_WIELDITEM .. wielditem)
end

------------------------------------------------------------------------
-- Connection initialization.
------------------------------------------------------------------------

mcl_localplayer.localplayer_initialized = false

local handshake_payloads = {}

local function process_clientbound_hello (payload)
	if mcl_localplayer.localplayer_initialized then
		error ("Received duplicate ClientboundHello message")
	end

	table.insert (handshake_payloads, payload)
	if #payload < MAX_PAYLOAD then
		local complete_payload = table.concat (handshake_payloads)
		local handshake = core.parse_json (complete_payload)
		if not handshake or type (handshake.proto) ~= "number" then
			error ("Malformed ClientboundHello")
		end
		if handshake.proto >= 0 then
			if handshake.proto > PROTO_VERSION then
				error ("Server requires a greater protocol version than the client supports")
			else
				if type (handshake.node_definitions) ~= "table" then
					error ("Malformed ClientboundHello")
				end
				-- Validate fields in handshake.node_definitions.
				for k, v in pairs (handshake.node_definitions) do
					if type (k) ~= "string" or type (v) ~= "table" then
						error ("Malformed handshake.node_definitions")
					end
					if v._mcl_velocity_factor
						and type (v._mcl_velocity_factor) ~= "number" then
						error ("Malformed _mcl_velocity_factor")
					end
				end
				-- Validate fields in bows.
				if type (handshake.bow_info) ~= "table" then
					error ("Malformed ClientboundHello")
				end
				for k, v in pairs (handshake.bow_info) do
					if type (k) ~= "string" or type (v) ~= "table" then
						error ("Malformed handshake.bow_info")
					end
					if k == "is_crossbow" then
						if type (v) ~= "table" then
							error ("Malformed handshake.is_crossbow")
						end
					elseif type (v.charge_time_half) ~= "number"
						or type (v.charge_time_full) ~= "number"
						or type (v.texture_0) ~= "string"
						or type (v.texture_0_wielditem) ~= "string"
						or type (v.texture_1) ~= "string"
						or type (v.texture_1_wielditem) ~= "string"
						or type (v.texture_2) ~= "string"
						or type (v.texture_2_wielditem) ~= "string"
						or (v.texture_loaded and type (v.texture_loaded) ~= "string") then
						error ("Malformed handshake.bow_info")
					end
				end
				mcl_localplayer.init_bows (handshake.bow_info)
				mcl_localplayer.proto = handshake.proto_version
				mcl_localplayer.node_defs = handshake.node_definitions
				mcl_localplayer.pose_defs = {}

				-- Initialize the CSM.
				print ("*** Mineclonia client-side mod initialized")
				mcl_localplayer.init_player ()
				mcl_localplayer.localplayer_initialized = true
			end
		end
	end
end

local function receive_modchannel_message (channel_name, sender, message)
	if channel_name == mcl_localplayer.modchannel_name and sender == "" then
		if mcl_localplayer.debug then
			print (" server->client " .. message:sub (1, 127) .. "\n")
		end

		local msgtype = message:sub (1, 2)
		local payload = message:sub (3, #message)

		if msgtype == CLIENTBOUND_HELLO then
			process_clientbound_hello (payload)
		elseif mcl_localplayer.localplayer_initialized then
			if msgtype == CLIENTBOUND_PLAYER_CAPABILITIES then
				mcl_localplayer.process_clientbound_player_capabilities (payload)
			elseif msgtype == CLIENTBOUND_ROCKET_USE then
				local number = tonumber (payload)
				assert (number, "Invalid payload in ClientboundRocketUse message")
				mcl_localplayer.apply_rocket_use (number)
			elseif msgtype == CLIENTBOUND_REGISTER_ATTRIBUTE_MODIFIER then
				local modifier = core.parse_json (payload)
				if type (modifier) ~= "table"
					or type (modifier.id) ~= "string"
					or type (modifier.field) ~= "string"
					or type (modifier.op) ~= "string"
					or type (modifier.value) ~= "number" then
					local blurb = "Invalid ClientboundRegisterAttributeModifier message: "
						.. dump (modifier)
					error (blurb)
				end
				mcl_localplayer.register_attribute_modifier (modifier)
			elseif msgtype == CLIENTBOUND_REMOVE_ATTRIBUTE_MODIFIER then
				local modifier = core.parse_json (payload)
				if type (modifier) ~= "table"
					or type (modifier.field) ~= "string"
					or type (modifier.id) ~= "string" then
					local blurb = "Invalid ClientboundRemoveAttributeModifier message: "
						.. dump (modifier)
					error (blurb)
				end
				mcl_localplayer.remove_attribute_modifier (modifier)
			elseif msgtype == CLIENTBOUND_REGISTER_STATUS_EFFECT then
				local status_effect = core.parse_json (payload)
				if type (status_effect) ~= "table"
					or type (status_effect.level) ~= "number"
					or type (status_effect.factor) ~= "number"
					or type (status_effect.name) ~= "string" then
					local blurb = "Invalid ClientboundRegisterStatusEffect message: "
						.. dump (status_effect)
					error (blurb)
				end
				mcl_localplayer.add_status_effect (status_effect)
			elseif msgtype == CLIENTBOUND_REMOVE_STATUS_EFFECT then
				mcl_localplayer.remove_status_effect (payload)
			elseif msgtype == CLIENTBOUND_POSECTRL then
				local ctrlword = tonumber (payload) -- nil to clear overrides.
				mcl_localplayer.do_posectrl (ctrlword)
			elseif msgtype == CLIENTBOUND_SHIELDCTRL then
				local ctrlword = tonumber (payload) or 0
				mcl_localplayer.do_shieldctrl (ctrlword)
			elseif msgtype == CLIENTBOUND_AMMOCTRL then
				local ctrlwords = string.split (payload, ',')
				if not ctrlwords or #ctrlwords ~= 2
					or not tonumber (ctrlwords[1])
					or not tonumber (ctrlwords[2]) then
					error ("Invalid ClientboundAmmoCtrl payload: " .. payload)
				end
				local ctrlword1 = tonumber (ctrlwords[1])
				local ctrlword2 = tonumber (ctrlwords[2])
				mcl_localplayer.do_ammoctrl (ctrlword1, ctrlword2)
			elseif msgtype == CLIENTBOUND_BOW_CAPABILITIES then
				local caps = core.parse_json (payload)
				if type (caps) ~= "table"
					or type (caps.infinity) ~= "boolean"
					or type (caps.charge_time) ~= "number"
					or type (caps.challenge) ~= "number" then
					error ("Invalid ClientboundBowCapabilities payload: " .. payload)
				end
				mcl_localplayer.do_bow_capabilities (caps.challenge, caps)
			end
		end
	end
end

core.register_on_localplayer_object_available (function ()
	local player = core.localplayer:get_name ()
	mcl_localplayer.modchannel_name = "mcl_player:" .. player
	mcl_localplayer.modchannel
		= core.mod_channel_join (mcl_localplayer.modchannel_name)
	core.register_on_modchannel_message (receive_modchannel_message)
end)

core.register_on_modchannel_signal (function (channel, signal)
	if channel == mcl_localplayer.modchannel_name
		and signal == 0 then
		mcl_localplayer.send (SERVERBOUND_HELLO .. PROTO_VERSION)		
	end
end)
