------------------------------------------------------------------------
-- Skyboxes, ambient lighting, and weather.
--
-- - [X] Ambient lighting in different dimensions.
-- - [X] Night vision.
-- - [X] Skyboxes (and biome skyboxes)
-- TODO: Protocol version 3:
-- - [ ]   + Viewing range reductions in fluids and in the End.
-- - [ ] Client-side weather & lightning.
------------------------------------------------------------------------

local floor = math.floor

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
		base_color = "#330808",
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

function mcl_localplayer.tick_effects (self_pos, dtime)
	local ylevel = floor (self_pos.y + 0.5)
	local dim = y_to_dimension (ylevel)
	local lighting = lighting_by_dimension[dim]
		or DEFAULT_LIGHTING_OPTIONS
	local localplayer = mcl_localplayer.localplayer

	if mcl_localplayer.has_effect ("night_vision") then
		lighting = NIGHT_VISION_LIGHTING_OPTIONS
	end

	if lighting ~= previous_lighting_cfg then
		core.camera:set_ambient_lighting (lighting.ambient_level,
						  lighting.range_squeeze)
		previous_lighting_cfg = lighting
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

	if update_skybox then
		apply_skybox_biome_colors ()
		apply_skybox_weather_state ()
		force_skybox_update ()
	end
end
