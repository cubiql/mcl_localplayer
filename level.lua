------------------------------------------------------------------------
-- Level and biome data management.
------------------------------------------------------------------------

local profile = mcl_localplayer.profile
local profile_done = mcl_localplayer.profile_done

local insert = table.insert

local floor = math.floor
local mathabs = math.abs
local mathmax = math.max
local mathmin = math.min

local biome_data_initialized = false
local server_biome_system
local server_biome_seed

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
local registered_dimensions = {}

function mcl_localplayer.enable_biome_cache (biome_id_to_name_map,
					     biome_definitions,
					     biome_data_type, biome_seed,
					     dimensions)
	biome_data_initialized = true
	if biome_data_type ~= "levelgen_data"
		and biome_data_type ~= "engine_data" then
		error ("Unsupported biome data format: " .. biome_data_type)
	end
	server_biome_system = biome_data_type
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
		if biome_data_type == "levelgen_data" then
			assert (type (def.temperature) == "number")
			assert (not def.has_precipitation
				or type (def.has_precipitation) == "boolean")
			assert (not def.temperature_modifier
				or type (def.temperature_modifier) == "string")
		elseif biome_data_type == "engine_data" then
			assert (not def._mcl_biome_type
				or type (def._mcl_biome_type) == "string")
		end
	end
	registered_biomes = biome_definitions
	if biome_seed then
		assert (biome_data_type == "levelgen_data",
			"Biome seed specified with mcl_levelgen disabled")
		assert (type (biome_seed) == "table"
			and type (biome_seed[1]) == "number"
			and type (biome_seed[2]) == "number")
		server_biome_seed = biome_seed

		-- This data is only material when mcl_levelgen is
		-- enabled on the server and this data is required for
		-- correct biome indexing.
		assert (type (dimensions) == "table")
		for _, dim in ipairs (dimensions) do
			assert (type (dim.y_global) == "number")
			assert (type (dim.y_global_block) == "number")
			assert (type (dim.y_max) == "number")
			assert (type (dim.y_offset) == "number")
			assert (type (dim.id) == "string")
		end
		registered_dimensions = dimensions
	end
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
	local bx = floor (self_pos.x / 16)
	local by = floor (self_pos.y / 16)
	local bz = floor (self_pos.z / 16)
	if bx == biome_cache_center.x
		and by == biome_cache_center.y
		and bz == biome_cache_center.z then
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
end

core.register_globalstep (function (_)
	if biome_data_initialized then
		profile ("Level update biome cache")
		local self_pos = core.localplayer:get_pos ()
		self_pos.x = floor (self_pos.x + 0.5)
		self_pos.y = floor (self_pos.y + 0.5)
		self_pos.z = floor (self_pos.z + 0.5)
		mcl_localplayer.step_biome_cache (self_pos)
		profile_done ("Level update biome cache")
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

function mcl_localplayer.dimension_at_layer (y)
	for _, dim in ipairs (registered_dimensions) do
		if y >= dim.y_global and y <= dim.y_max then
			return dim
		end
	end

	return nil
end

local dimension_at_layer = mcl_localplayer.dimension_at_layer

------------------------------------------------------------------------
-- Biome position randomization.
------------------------------------------------------------------------

local band = bit.band
local arshift = bit.arshift
local rshift = bit.rshift
local huge = math.huge

local tmp, tmp1 = mcl_levelgen.ull (0, 0), mcl_levelgen.ull (0, 0)
local lcj_next = mcl_levelgen.lcj_next
local extkull = mcl_levelgen.extkull
local ashrull = mcl_levelgen.ashrull

local function munge_distance (seed, tqx, tqy, tqz, tpx, tpy, tpz)
	tmp[1], tmp[2] = seed[1], seed[2]
	local tmp1 = tmp1
	extkull (tmp1, tqx)
	lcj_next (tmp, tmp1)
	extkull (tmp1, tqy)
	lcj_next (tmp, tmp1)
	extkull (tmp1, tqz)
	lcj_next (tmp, tmp1)
	extkull (tmp1, tqx)
	lcj_next (tmp, tmp1)
	extkull (tmp1, tqy)
	lcj_next (tmp, tmp1)
	extkull (tmp1, tqz)
	lcj_next (tmp, tmp1)
	tmp1[1], tmp1[2] = tmp[1], tmp[2]
	ashrull (tmp1, 24)
	local bp = band (tmp1[1], 1023) / 1024.0
	local dx = (bp - 0.5) * 0.9

	lcj_next (tmp, seed)
	tmp1[1], tmp1[2] = tmp[1], tmp[2]
	ashrull (tmp1, 24)
	local bp = band (tmp1[1], 1023) / 1024.0
	local dy = (bp - 0.5) * 0.9

	lcj_next (tmp, seed)
	tmp1[1], tmp1[2] = tmp[1], tmp[2]
	ashrull (tmp1, 24)
	local bp = band (tmp1[1], 1023) / 1024.0
	local dz = (bp - 0.5) * 0.9
	return (tpz + dz) * (tpz + dz)
		+ (tpy + dy) * (tpy + dy)
		+ (tpx + dx) * (tpx + dx)
end

-- Return a displaced version of the quart position of the block
-- position X, Y, Z.  This position is lightly randomized and is not
-- consulted during biome generation, only when accessing generated
-- biome data.
--
-- Value is guaranteed to fall within one QuartBlock's distance of X,
-- Y, Z's absolute position on each axis.

function mcl_localplayer.munge_biome_coords (seed, x, y, z)
	x = x - 2
	y = y - 2
	z = z - 2
	local qx = arshift (x, 2)
	local qy = arshift (y, 2)
	local qz = arshift (z, 2)
	x = band (x, 3) / 4.0
	y = band (y, 3) / 4.0
	z = band (z, 3) / 4.0

	local nearest_transform = 0
	local max_distance = huge

	for i = 0, 7 do
		local dx = rshift (band (i, 4), 2)
		local dy = rshift (band (i, 2), 1)
		local dz = band (i, 1)
		local dist = munge_distance (seed, qx + dx, qy + dy,
					     qz + dz, x - dx, y - dy,
					     z - dz)
		if max_distance > dist then
			nearest_transform = i
			max_distance = dist
		end
	end

	x = rshift (band (nearest_transform, 4), 2)
	y = rshift (band (nearest_transform, 2), 1)
	z = band (nearest_transform, 1)
	return qx + x, qy + y, qz + z
end

if mcl_levelgen.detect_luajit () then
	local str = [[
	local tonumber = tonumber
	local rshift = bit.rshift
	local arshift = bit.arshift
	local lshift = bit.lshift
	local band = bit.band

	local function lcj_next (seed, increment)
		return seed * (seed * 0x5851f42d4c957f2dll
			       + 0x14057b7ef767814fll)
			+ increment
	end

	local function munge_one (value)
		local fixed = band (arshift (value, 24), 1023ll)
		local bp = tonumber (fixed) / 1024.0
		return (bp - 0.5) * 0.9
	end

	local function munge_distance (seed, tqx, tqy, tqz, tpx, tpy, tpz)
		local seed = 0x100000000ll * seed[2] + seed[1]
		local increment = seed
		seed = lcj_next (seed, tqx * 1ll)
		seed = lcj_next (seed, tqy * 1ll)
		seed = lcj_next (seed, tqz * 1ll)
		seed = lcj_next (seed, tqx * 1ll)
		seed = lcj_next (seed, tqy * 1ll)
		seed = lcj_next (seed, tqz * 1ll)

		local dx = munge_one (seed)
		seed = lcj_next (seed, increment)
		local dy = munge_one (seed)
		seed = lcj_next (seed, increment)
		local dz = munge_one (seed)
		return (tpz + dz) * (tpz + dz)
			+ (tpy + dy) * (tpy + dy)
			+ (tpx + dx) * (tpx + dx)
	end

	return munge_distance
]]
	local fn = loadstring (str)
	munge_distance = fn ()
end

local munge_biome_coords = mcl_localplayer.munge_biome_coords

------------------------------------------------------------------------
-- Biome database indexing.
------------------------------------------------------------------------

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
	local bx, by, bz
	local qx, qy, qz
	local dim = nil

	if server_biome_seed then
		dim = dimension_at_layer (y)
		if dim then
			-- Convert X, Y, Z into level positions.
			local y_offset = dim.y_offset
			local lx, ly, lz = x, y + y_offset, -z - 1
			qx, qy, qz = munge_biome_coords (server_biome_seed,
							 lx, ly, lz)

			-- Restore the produced quart position to the
			-- map coordinate system and convert it into a
			-- block position
			qz = -qz - 1
			qy = qy - y_offset / 4
			bx = arshift (qx, 2)
			by = arshift (qy, 2)
			bz = arshift (qz, 2)
		end
	end
	if not dim then
		qx = arshift (x, 2)
		qy = arshift (y, 2)
		qz = arshift (z, 2)
		bx = arshift (x, 4)
		by = arshift (y, 4)
		bz = arshift (z, 4)
	end

	local idx = block_index (bx, by, bz)

	if biome_data_initialized and idx and biome_cache_last[idx] then
		return index_biome_list (biome_cache_last[idx][1],
					 biome_cache_last[idx][2],
					 band (qx, 3), band (qy, 3),
					 band (qz, 3))
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

local function get_column_type (name, def, x, y, z)
	if name == nil then
		return 0x0
	elseif server_biome_system == "levelgen_data" then
		if def.has_precipitation then
			if is_temp_rainy (name, x, y + 64, -z - 1) then
				return COLUMN_RAIN
			else
				return COLUMN_SNOW
			end
		end
		return 0x0
	elseif server_biome_system == "engine_data" then
		local biome_type = def._mcl_biome_type
		if biome_type == "hot" then
			return 0x0
		elseif biome_type == "cold" then
			if name == "Taiga" and y > 140
				or name == "MegaSpruceTaiga" and y > 100 then
				return COLUMN_SNOW
			end
			return COLUMN_RAIN
		elseif biome_type == "snowy" then
			return COLUMN_SNOW
		else
			return COLUMN_RAIN
		end
	end
	assert (false)
end

function mcl_localplayer.build_column_visibility_map (x, y, z, map, range)
	local all = 0
	local i = 1

	for z = z - range, z + range do
		for x = x - range, x + range do
			-- Sample biomes at the surface if it is not
			-- too distant from the camera for
			-- consistency with snow cover.
			local y1 = core.get_position_height (x, z)
			y1 = mathmax (mathmin (y1, y + 10), y - 10)
			local name = index_biomes (x, y1, z)
			local def = registered_biomes[name]
			local column_type = get_column_type (name, def,
							     x, y1, z)
			map[i] = column_type
			all = bor (all, column_type)
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

