------------------------------------------------------------------------
-- Skyboxes, ambient lighting, and weather.
--
-- - [X] Ambient lighting in different dimensions.
-- - [X] Night vision.
-- - [X] Skyboxes (and biome skyboxes)
-- - [X] Client-side weather & lightning.
-- - [ ] Viewing range reductions in fluids and in the End.
------------------------------------------------------------------------

local floor = math.floor
local mathabs = math.abs

local profile = mcl_localplayer.profile
local profile_done = mcl_localplayer.profile_done

------------------------------------------------------------------------
-- Skybox & ambient lighting.
------------------------------------------------------------------------

local lighting_by_dimension = {}
local DEFAULT_LIGHTING_OPTIONS = {
	ambient_level = 0,
	range_squeeze = 0,
}
local NIGHT_VISION_LIGHTING_OPTIONS = {
	ambient_level = 9,
	range_squeeze = 25,
}

local y_to_dimension = mcl_localplayer.y_to_dimension
local previous_lighting_cfg = nil
local current_skybox_layer = nil
local held_torch_lighting_cfg = {
	ambient_level = 0,
	range_squeeze = 0,
}

local biome_sky_color = "#7ba4ff"
local biome_fog_color = "#c0d8ff"
local weather_state = "none"

local base_skybox_overworld = {
	sun = {
		visible = true,
		sunrise_visible = true,
	},
	moon = {
		visible = true,
	},
	stars = {
		visible = true,
	},
	sky = {
		type = "regular",
		sky_color = {
			day_sky = "#7ba4ff",
			day_horizon = "#c0d8ff",
			night_sky = "#000000",
			night_horizon = "#4a6790",
			indoors = "#c0d8ff",
			fog_sun_tint = "#ff5f33",
			fog_moon_tint = nil,
			fog_tint_type = "custom",
		},
		clouds = true,
	},
}

local water_skybox_overworld = {
	sun = {
		visible = true,
		sunrise_visible = true,
	},
	moon = {
		visible = true,
	},
	stars = {
		visible = true,
	},
	sky = {
		type = "regular",
		sky_color = {
			day_sky = "#3f76e4",
			day_horizon = "#3f76e4",
			dawn_sky = "#3f76e4",
			dawn_horizon = "#3f76e4",
			night_sky = "#3f76e4",
			night_horizon = "#3f76e4",
			indoors = "#3f76e4",
			fog_sun_tint = "#3f76e4",
			fog_moon_tint = "#3f76e4",
			fog_tint_type = "custom",
		},
		clouds = false,
	},
}

local base_skybox_end = {
	sun = {
		visible = false,
		sunrise_visible = false,
	},
	moon = {
		visible = false,
	},
	stars = {
		visible = false,
	},
	sky = {
		type = "skybox",
		base_color = "#000000",
		textures = {
			"mcl_playerplus_end_sky.png",
			"mcl_playerplus_end_sky.png",
			"mcl_playerplus_end_sky.png",
			"mcl_playerplus_end_sky.png",
			"mcl_playerplus_end_sky.png",
			"mcl_playerplus_end_sky.png",
		},
		clouds = false,
	},
}

local base_skybox_nether = {
	sun = {
		visible = false,
		sunrise_visible = false,
	},
	moon = {
		visible = false,
	},
	stars = {
		visible = false,
	},
	sky = {
		type = "plain",
		base_color = "#4a0d08",
		clouds = false,
		fog = {
			fog_distance = 96,
			fog_start = 0.75,
		},
	},
}

local base_skybox_void = {
	sun = {
		visible = false,
		sunrise_visible = false,
	},
	moon = {
		visible = false,
	},
	stars = {
		visible = false,
	},
	sky = {
		type = "plain",
		base_color = "#000000",
		clouds = false,
	},
}

local current_moon_texture

local function apply_skybox_layer (layer)
	core.camera:set_sky (layer.sky)
	core.camera:set_sun (layer.sun)
	local moon = {
		visible = layer.moon.visible,
		texture = current_moon_texture,
		scale = 3.75,
	}
	core.camera:set_moon (moon)
	core.camera:set_stars (layer.stars)
end

local function force_skybox_update ()
	if current_skybox_layer then
		apply_skybox_layer (current_skybox_layer)
	end
end

local function apply_skybox_weather_state ()
	if weather_state == "rain" then
		base_skybox_overworld.sky.sky_color.day_sky = "#7b8aa0"
		base_skybox_overworld.sky.sky_color.day_horizon = "#717ca6"
		base_skybox_overworld.sky.sky_color.dawn_sky = "#7b8aa0"
		base_skybox_overworld.sky.sky_color.dawn_horizon = "#717ca6"
		water_skybox_overworld.sky.sky_color.day_sky = "#7b8aa0"
		water_skybox_overworld.sky.sky_color.day_horizon = "#717ca6"
		water_skybox_overworld.sky.sky_color.dawn_sky = "#7b8aa0"
		water_skybox_overworld.sky.sky_color.dawn_horizon = "#717ca6"
		base_skybox_overworld.sun.visible = false
		base_skybox_overworld.moon.visible = false
		base_skybox_overworld.stars.visible = false
		water_skybox_overworld.sun.visible = false
		water_skybox_overworld.moon.visible = false
		water_skybox_overworld.stars.visible = false
	elseif weather_state == "thunder" then
		base_skybox_overworld.sky.sky_color.day_sky = "#738092"
		base_skybox_overworld.sky.sky_color.day_horizon = "#6c77a2"
		base_skybox_overworld.sky.sky_color.dawn_sky = "#738092"
		base_skybox_overworld.sky.sky_color.dawn_horizon = "#6c77a2"
		water_skybox_overworld.sky.sky_color.day_sky = "#738092"
		water_skybox_overworld.sky.sky_color.day_horizon = "#6c77a2"
		water_skybox_overworld.sky.sky_color.dawn_sky = "#738092"
		water_skybox_overworld.sky.sky_color.dawn_horizon = "#6c77a2"
		base_skybox_overworld.sun.visible = false
		base_skybox_overworld.moon.visible = false
		base_skybox_overworld.stars.visible = false
		water_skybox_overworld.sun.visible = false
		water_skybox_overworld.moon.visible = false
		water_skybox_overworld.stars.visible = false
	else
		base_skybox_overworld.sun.visible = true
		base_skybox_overworld.moon.visible = true
		base_skybox_overworld.stars.visible = true
		water_skybox_overworld.sun.visible = true
		water_skybox_overworld.moon.visible = true
		water_skybox_overworld.stars.visible = true
	end
end

local fog_color_cache = {}
local function end_fog_color (color)
	if fog_color_cache[color] then
		return fog_color_cache[color]
	end
	local cs = core.colorspec_to_table (color)
	cs.r = math.floor (cs.r * 0.15)
	cs.g = math.floor (cs.g * 0.15)
	cs.b = math.floor (cs.b * 0.15)
	fog_color_cache[color] = core.colorspec_to_colorstring (cs)
	return fog_color_cache[color]
end

local function apply_skybox_biome_colors ()
	base_skybox_overworld.sky.sky_color.day_sky = biome_sky_color
	base_skybox_overworld.sky.sky_color.day_horizon = biome_fog_color
	base_skybox_overworld.sky.sky_color.dawn_sky = biome_sky_color
	base_skybox_overworld.sky.sky_color.dawn_horizon = biome_fog_color
	base_skybox_nether.sky.base_color = biome_fog_color
	base_skybox_end.sky.base_color = end_fog_color (biome_fog_color)
end

local function is_wielding_torch ()
	local wielded = core.localplayer:get_wielded_item ()
	if not wielded or wielded:is_empty () then
		return false
	end
	local name = wielded:get_name ()
	if not name or name == "" then
		return false
	end
	if name == "mcl_torches:torch" then
		return true
	end
	local ok, def = pcall (wielded.get_definition, wielded)
	return ok and def and def.groups and (def.groups.torch or 0) > 0
end

local function get_wielded_torch_lighting (self_pos, lighting)
	if not is_wielding_torch () or mcl_localplayer.localplayer:is_underwater () then
		return lighting
	end

	local sample_pos = vector.round (vector.offset (self_pos, 0, 1, 0))
	local light = core.get_node_light (sample_pos, nil) or 0
	if light >= 12 then
		return lighting
	end

	local ambient_boost = math.min (7, 12 - light)
	held_torch_lighting_cfg.ambient_level
		= math.max (lighting.ambient_level, ambient_boost)
	held_torch_lighting_cfg.range_squeeze
		= math.max (lighting.range_squeeze, 10 + ambient_boost * 2)
	return held_torch_lighting_cfg
end

local current_climate = nil
local sound_handle = nil

local climate_particle_spawners = {}
local climate_particle_spawner_ids = {}
local effect_visibility_map = {}
local have_dynamic_climate_effects
	= mcl_localplayer.have_dynamic_climate_effects
local build_column_visibility_map
	= mcl_localplayer.build_column_visibility_map
local COLUMN_RAIN = mcl_localplayer.COLUMN_RAIN
local COLUMN_SNOW = mcl_localplayer.COLUMN_SNOW
local EFFECT_VISIBILITY_MAP_RANGE = 10

local function enable_climate_effects (effects, map, x, z)
	for existing, id in pairs (climate_particle_spawner_ids) do
		for _, effect in ipairs (effects) do
			if effect == existing then
				id = nil
				break
			end
		end
		if id then
			core.delete_volume_particle_spawner (id)
			climate_particle_spawner_ids[existing] = nil
		end
	end

	for _, effect in ipairs (effects) do
		local id = climate_particle_spawner_ids[effect]
		if not id then
			local def = climate_particle_spawners[effect]
			id = core.add_volume_particle_spawner (def)
			climate_particle_spawner_ids[effect] = id
		end
		if map and effect == "cold" then
			core.set_volume_particle_spawner_visibility_map (id, EFFECT_VISIBILITY_MAP_RANGE,
									 x, z, map, COLUMN_SNOW)
		elseif map and effect == "default" then
			core.set_volume_particle_spawner_visibility_map (id, EFFECT_VISIBILITY_MAP_RANGE,
									 x, z, map, COLUMN_RAIN)
		end
	end
end

local mathsqrt = math.sqrt
local mathmax = math.max
local BASE_GAIN = 1.0 / mathsqrt (11.0)
local GAIN_SCALE = 1.0 / (1.0 - BASE_GAIN)

local function get_sound_gain (self_pos)
	if current_climate == "default" then
		local x = floor (self_pos.x + 0.5)
		local y = floor (self_pos.y + 0.5)
		local z = floor (self_pos.z + 0.5)
		local nearest = core.scan_position_height (x, y, z, 10)
		if nearest then
			local d = mathabs (nearest.y - floor (self_pos.y))
			if d <= 10 then
				local g = (1.0 / mathsqrt (mathmax (1, d))) - BASE_GAIN
				return g * GAIN_SCALE
			end
		end
	end
	return 0.0
end

if core.global_exists ("jit") then
	jit.opt.start ("maxmcode=40960", "maxtrace=100000",
		       "loopunroll=35", "maxside=8000", "maxsnap=1000",
		       "maxrecord=8000")
end

function mcl_localplayer.tick_effects (self_pos, dtime)
	profile ("Level tick effects")
	local ylevel = floor (self_pos.y + 0.5)
	local dim = y_to_dimension (ylevel)
	local lighting = lighting_by_dimension[dim]
		or DEFAULT_LIGHTING_OPTIONS
	local localplayer = mcl_localplayer.localplayer

	if mcl_localplayer.has_effect ("night_vision") then
		lighting = NIGHT_VISION_LIGHTING_OPTIONS
	end
	lighting = get_wielded_torch_lighting (self_pos, lighting)

	if not previous_lighting_cfg
		or lighting.ambient_level ~= previous_lighting_cfg.ambient_level
		or lighting.range_squeeze ~= previous_lighting_cfg.range_squeeze then
		core.camera:set_ambient_lighting (lighting.ambient_level,
						  lighting.range_squeeze)
		previous_lighting_cfg = {
			ambient_level = lighting.ambient_level,
			range_squeeze = lighting.range_squeeze,
		}
	end

	local skybox_layer
	if dim == "overworld" then
		if localplayer:is_underwater () then
			skybox_layer = water_skybox_overworld
		else
			skybox_layer = base_skybox_overworld
		end
	elseif dim == "nether" then
		skybox_layer = base_skybox_nether
	elseif dim == "end" then
		skybox_layer = base_skybox_end
	else
		skybox_layer = base_skybox_void
	end
	if skybox_layer ~= current_skybox_layer then
		apply_skybox_layer (skybox_layer)
		current_skybox_layer = skybox_layer
	end
	if weather_state == "rain" or weather_state == "thunder" then
		local effects, map
		local x, z = floor (self_pos.x + 0.5),
			floor (self_pos.z + 0.5)
		if have_dynamic_climate_effects () then
			profile ("Level dynamic effect computation")
			map = effect_visibility_map
			effects = build_column_visibility_map (x, ylevel, z, map,
							       EFFECT_VISIBILITY_MAP_RANGE)
			profile_done ("Level dynamic effect computation")
		else
			map = nil
			effects = { current_climate, }
		end
		enable_climate_effects (effects, map, x, z)

		local gain = get_sound_gain (self_pos)
		if gain > 0.0 and not sound_handle then
			sound_handle = core.sound_play ({
				name = "weather_rain",
				gain = gain,
			}, { loop = true, })
		end
		if sound_handle then
			core.sound_fade (sound_handle, -0.5, gain)
		end
		if gain <= 0.0 then
			sound_handle = nil
		end
	else
		for existing, id in pairs (climate_particle_spawner_ids) do
			core.delete_volume_particle_spawner (id)
			climate_particle_spawner_ids[existing] = nil
		end
		if sound_handle then
			core.sound_fade (sound_handle, -0.5, 0.0)
			sound_handle = nil
		end
	end
	profile_done ("Level tick effects")
end

core.register_globalstep (function (dtime)
	if mcl_localplayer.localplayer_initialized
		and mcl_localplayer.proto >= 2 then
		local self_pos = core.localplayer:get_pos ()
		mcl_localplayer.tick_effects (self_pos, dtime)
	end
end)

------------------------------------------------------------------------
-- External interface.
------------------------------------------------------------------------

function mcl_localplayer.handle_effect_ctrl (cfg)
	local lighting = cfg.dim_lighting
	if cfg.dim_lighting then
		for dim, options in pairs (lighting) do
			if type (options.ambient_level) ~= "number"
				or type (options.range_squeeze) ~= "number" then
				error ("Invalid dimension lighting configuration: " .. dump (cfg))
			end
		end
		lighting_by_dimension = lighting
		previous_lighting_cfg = nil
	end

	local update_skybox = false
	if cfg.biome_sky_color or cfg.biome_fog_color then
		assert (type (cfg.biome_sky_color) == "string")
		assert (type (cfg.biome_fog_color) == "string")
		biome_sky_color = cfg.biome_sky_color
		biome_fog_color = cfg.biome_fog_color
		update_skybox = true
	end

	if cfg.weather_state then
		weather_state = cfg.weather_state
		update_skybox = true
	end

	if cfg.moon_texture and mcl_localplayer.proto >= 3 then
		assert (type (cfg.moon_texture) == "string")
		current_moon_texture = cfg.moon_texture
		update_skybox = true
	end

	if cfg.climate and mcl_localplayer.proto >= 5 then
		assert (cfg.climate == "none"
			or cfg.climate == "cold"
			or cfg.climate == "arid"
			or cfg.climate == "default")
		current_climate = cfg.climate
	end

	if cfg.preciptation_spawners and mcl_localplayer.proto >= 5 then
		assert (type (cfg.preciptation_spawners) == "table")
		for _, spawner in pairs (cfg.preciptation_spawners) do
			assert (type (spawner.textures) == "table")
			for _, texture in ipairs (spawner.textures) do
				assert (type (texture) == "string")
			end
			assert (type (spawner.velocity_min) == "table"
				and type (spawner.velocity_min.x) == "number"
				and type (spawner.velocity_min.y) == "number"
				and type (spawner.velocity_min.z) == "number")
			assert (type (spawner.particles_per_column) == "number"
				and spawner.particles_per_column > 0)
			assert (type (spawner.size) == "number" and spawner.size > 0)
			assert (type (spawner.range_vertical) == "number"
				and spawner.range_vertical > 0)
			assert (type (spawner.range_horizontal) == "number"
				and spawner.range_horizontal > 0)
			assert (type (spawner.period) == "number" and spawner.period > 0)
			assert (type (spawner.above_heightmap) == "boolean")
		end
		climate_particle_spawners = cfg.preciptation_spawners
	end

	if update_skybox then
		apply_skybox_biome_colors ()
		apply_skybox_weather_state ()
		force_skybox_update ()
	end
end
