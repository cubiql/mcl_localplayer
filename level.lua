------------------------------------------------------------------------
-- Level and biome data management.
------------------------------------------------------------------------

local profile = mcl_localplayer.profile
local profile_done = mcl_localplayer.profile

local insert = table.insert

local floor = math.floor
local mathabs = math.abs

local biome_data_initialized = false

local BIOME_CACHE_RANGE = 4
local BIOME_CACHE_DIAMETER = BIOME_CACHE_RANGE * 2 + 1
local BIOME_CACHE_Y = BIOME_CACHE_DIAMETER
local BIOME_CACHE_X = BIOME_CACHE_DIAMETER * BIOME_CACHE_DIAMETER
local BIOME_CACHE_SIZE = BIOME_CACHE_DIAMETER
	* BIOME_CACHE_DIAMETER
	* BIOME_CACHE_DIAMETER

local biome_cache_next = {}
local biome_cache_last = {}
local biome_cache_center = vector.new ()

for i = 1, BIOME_CACHE_SIZE do
	biome_cache_next[i] = nil
	biome_cache_last[i] = nil
end

local id_to_name_map = {}
local registered_biomes = {}

function mcl_localplayer.enable_biome_cache (biome_id_to_name_map,
					     biome_definitions)
	biome_data_initialized = true
	assert (type (biome_definitions) == "table")
	for id, name in pairs (biome_id_to_name_map) do
		local id = tonumber (id)
		assert (type (id) == "number" and id < 256)
		assert (type (name) == "string")
		id_to_name_map[id] = name
		assert (type (biome_definitions[name]) == "table")
	end
	for name, def in pairs (biome_definitions) do
		assert (type (def) == "table")
		assert (type (name) == "string")
		assert (type (def.temperature) == "number")
		assert (not def.has_precipitation
			or type (def.has_precipitation) == "boolean")
		assert (not def.temperature_modifier
			or type (def.temperature_modifier) == "string")
	end
	registered_biomes = biome_definitions
end

local function hashmapblock (x, y, z)
	return (y + 2048) * 16777216
		+ (x + 2048) * 4096
		+ (z + 2048)
end

local function unhashmapblock (hash)
	local y = floor (hash / 16777216) - 2048
	local x = floor (hash / 4096 % 4096) - 2048
	local z = hash % 4096 - 2048
	return x, y, z
end

function mcl_localplayer.step_biome_cache (self_pos)
	profile ("update biome cache")
	local bx = floor (self_pos.x / 16)
	local by = floor (self_pos.y / 16)
	local bz = floor (self_pos.z / 16)
	if bx == biome_cache_center.x
		and by == biome_cache_center.y
		and bz == biome_cache_center.z then
		profile_done ("update biome cache")
		return
	end

	local discard = {}
	for i = 1, BIOME_CACHE_SIZE do
		local dz = (i - 1) % BIOME_CACHE_DIAMETER
		local dy = floor ((i - 1) / BIOME_CACHE_Y) % BIOME_CACHE_DIAMETER
		local dx = floor ((i - 1) / BIOME_CACHE_X)

		-- Move this item into the new biome cache, if it
		-- should exist there, and discard it otherwise.
		local old_x = biome_cache_center.x + dx - BIOME_CACHE_RANGE
		local old_y = biome_cache_center.y + dy - BIOME_CACHE_RANGE
		local old_z = biome_cache_center.z + dz - BIOME_CACHE_RANGE

		if mathabs (old_x - bx) <= BIOME_CACHE_RANGE
			and mathabs (old_y - by) <= BIOME_CACHE_RANGE
			and mathabs (old_z - bz) <= BIOME_CACHE_RANGE then
			local list = biome_cache_last[i]
			local new_x = old_x - bx + BIOME_CACHE_RANGE
			local new_y = old_y - by + BIOME_CACHE_RANGE
			local new_z = old_z - bz + BIOME_CACHE_RANGE
			local idx = new_x * BIOME_CACHE_X
				+ new_y * BIOME_CACHE_Y + new_z + 1
			biome_cache_next[idx] = list
		elseif biome_cache_last[i] then
			insert (discard, hashmapblock (old_x, old_y, old_z))
		end

		biome_cache_last[i] = nil
	end
	biome_cache_last, biome_cache_next
		= biome_cache_next, biome_cache_last
	biome_cache_center.x = bx
	biome_cache_center.y = by
	biome_cache_center.z = bz
	if #discard > 0 then
		mcl_localplayer.send_discard_biome_data (discard)
	end
	profile_done ("update biome cache")
end

core.register_globalstep (function (_)
	if biome_data_initialized then
		local self_pos = core.localplayer:get_pos ()
		self_pos.x = floor (self_pos.x + 0.5)
		self_pos.y = floor (self_pos.y + 0.5)
		self_pos.z = floor (self_pos.z + 0.5)
		mcl_localplayer.step_biome_cache (self_pos)
	end
end)

local function block_index (bx, by, bz)
	local x = bx - biome_cache_center.x + BIOME_CACHE_RANGE
	local y = by - biome_cache_center.y + BIOME_CACHE_RANGE
	local z = bz - biome_cache_center.z + BIOME_CACHE_RANGE
	if x >= 0 and y >= 0 and z >= 0
		and x < BIOME_CACHE_DIAMETER
		and y < BIOME_CACHE_DIAMETER
		and z < BIOME_CACHE_DIAMETER then
		return x * BIOME_CACHE_X + y * BIOME_CACHE_Y + z + 1
	else
		return nil
	end
end

function mcl_localplayer.import_biome_data (index_len, index, index_payload)
	local indices = index:split (',')
	assert (#indices % 2 == 0, "Odd number of indices provided in biome data")
	local discard = {}
	for i = 1, #indices - 1, 2 do
		local block = tonumber (indices[i])
		local offset = tonumber (indices[i + 1])
		local bx, by, bz = unhashmapblock (block)
		local idx = block_index (bx, by, bz)
		if idx then
			biome_cache_last[idx] = {
				offset + index_len + 1,
				index_payload,
			}
		else
			-- The server sent a block beyond the extents
			-- of the client's cache.
			insert (discard, block)
		end
	end
	if #discard > 0 then
		mcl_localplayer.send_discard_biome_data (discard)
	end
end

local band = bit.band
local arshift = bit.arshift
local byte = string.byte
local N = 4

local function index_biome_list (offset, list, qx, qy, qz)
	local i, idx = offset, qx * N * N + qy * N + qz + 1
	local biome
	repeat
		idx = idx - byte (list, i)
		biome = byte (list, i + 1)
		i = i + 2
	until idx <= 0
	return id_to_name_map[biome]
end

function mcl_localplayer.index_biomes (x, y, z)
	local bx = arshift (x, 4)
	local by = arshift (y, 4)
	local bz = arshift (z, 4)
	local idx = block_index (bx, by, bz)

	if biome_data_initialized and idx and biome_cache_last[idx] then
		local qx = band (arshift (x, 2), 3)
		local qy = band (arshift (y, 2), 3)
		local qz = band (arshift (z, 2), 3)
		return index_biome_list (biome_cache_last[idx][1],
					 biome_cache_last[idx][2],
					 qx, qy, qz)
	end
	return nil
end

local index_biomes = mcl_localplayer.index_biomes

------------------------------------------------------------------------
-- Climate sampling facilities.
------------------------------------------------------------------------

local seed = mcl_levelgen.ull (0, 1234)
local rng = mcl_levelgen.jvm_random (seed)
local TEMPERATURE_NOISE
	= mcl_levelgen.make_simplex_noise (rng, { 0, })
local seed = mcl_levelgen.ull (0, 3456)
local rng = mcl_levelgen.jvm_random (seed)
local FROZEN_BIOME_NOISE
	= mcl_levelgen.make_simplex_noise (rng, { -2, -1, 0, })
local seed = mcl_levelgen.ull (0, 2345)
local rng = mcl_levelgen.jvm_random (seed)
local BIOME_SELECTOR_NOISE
	= mcl_levelgen.make_simplex_noise (rng, { 0, })

local function get_temperature_in_biome (biome, x, y, z)
	local biome = registered_biomes[biome]
	local temp = biome.temperature

	-- Apply temperature modifier.
	if biome.temperature_modifier == "frozen" then
		local temp_offset
			= FROZEN_BIOME_NOISE (x * 0.05, z * 0.05) * 7.0
		local selector = BIOME_SELECTOR_NOISE (x * 0.2, z * 0.2)
		if temp_offset + selector < 0.3 then
			local selector1 = BIOME_SELECTOR_NOISE (x * 0.09, z * 0.09)
			if selector1 < 0.8 then
				temp = 0.2
			end
		end
	end

	-- And altitude chill.
	if y > 80 then
		local chill = TEMPERATURE_NOISE (x / 8.0, z / 8.0) * 8.0
		return temp - (chill + y - 80) * 0.05 / 40
	end
	return temp
end

local function is_temp_rainy (biome, x, y, z)
	local temp = get_temperature_in_biome (biome, x, y, z)
	return temp >= 0.15
end

local bor = bit.bor
local COLUMN_RAIN = 0x1
local COLUMN_SNOW = 0x2
local COLUMN_BOTH = 0x3
mcl_localplayer.COLUMN_RAIN = COLUMN_RAIN
mcl_localplayer.COLUMN_SNOW = COLUMN_SNOW

local NONE = {}
local RAIN = { "default", }
local SNOW = { "cold", }
local BOTH = { "cold", "default", }

function mcl_localplayer.build_column_visibility_map (x, y, z, map, range)
	local all = 0
	local i = 1

	for z = z - range, z + range do
		for x = x - range, x + range do
			local name = index_biomes (x, y, z)
			local def = registered_biomes[name]
			if name and def.has_precipitation then
				if is_temp_rainy (name, x, y + 64, -z - 1) then
					map[i] = COLUMN_RAIN
					all = bor (all, COLUMN_RAIN)
				else
					map[i] = COLUMN_SNOW
					all = bor (all, COLUMN_SNOW)
				end
			else
				map[i] = 0x0
			end
			i = i + 1
		end
	end

	if all == 0 then
		return NONE
	elseif all == COLUMN_RAIN then
		return RAIN
	elseif all == COLUMN_SNOW then
		return SNOW
	elseif all == COLUMN_BOTH then
		return BOTH
	else
		assert (false)
	end
end

function mcl_localplayer.have_dynamic_climate_effects ()
	return biome_data_initialized
end

