mcl_localplayer = {
	debug = true,
}
local modname = core.get_current_modname ()
print ("*** Loading Mineclonia CSM")

dofile (minetest.get_modpath (modname) .. "/miniflowlib.lua")
dofile (minetest.get_modpath (modname) .. "/player.lua")

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

-- Clientbound messages.
local CLIENTBOUND_HELLO = 'AA'
local CLIENTBOUND_PLAYER_CAPABILITIES = 'AB'

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
