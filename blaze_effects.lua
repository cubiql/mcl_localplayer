------------------------------------------------------------------------
-- Client-side Blaze particle enhancement.
------------------------------------------------------------------------

local mathrandom = math.random

local BLAZE_SMOKE_INTERVAL_MIN = 0.04
local BLAZE_SMOKE_INTERVAL_MAX = 0.08
local BLAZE_FLAME_INTERVAL_MIN = 0.10
local BLAZE_FLAME_INTERVAL_MAX = 0.16
local BLAZE_PARTICLE_RANGE = 40.0

local blaze = {
	on_activate = function (self)
		self._smoke_timer = mathrandom () * BLAZE_SMOKE_INTERVAL_MAX
		self._flame_timer = mathrandom () * BLAZE_FLAME_INTERVAL_MAX
	end,

	on_step = function (self, dtime)
		local player = core.localplayer
		if not player then
			return
		end

		local pos = self.object:get_pos ()
		local self_pos = player:get_pos ()
		if not pos or not self_pos
			or vector.distance (pos, self_pos) > BLAZE_PARTICLE_RANGE then
			return
		end

		self._smoke_timer = (self._smoke_timer or 0.0) - dtime
		if self._smoke_timer <= 0.0 then
			self._smoke_timer = BLAZE_SMOKE_INTERVAL_MIN
				+ mathrandom () * (BLAZE_SMOKE_INTERVAL_MAX
						   - BLAZE_SMOKE_INTERVAL_MIN)
			for _ = 1, 3 do
				local dark = 24 + mathrandom (56)
				local color = string.format ("#%02x%02x%02x", dark, dark, dark)
				core.add_particle ({
					pos = {
						x = pos.x + (mathrandom () - 0.5) * 0.85,
						y = pos.y + 0.55 + mathrandom () * 1.45,
						z = pos.z + (mathrandom () - 0.5) * 0.85,
					},
					velocity = {
						x = (mathrandom () - 0.5) * 0.10,
						y = 0.55 + mathrandom () * 0.70,
						z = (mathrandom () - 0.5) * 0.10,
					},
					acceleration = {
						x = 0,
						y = 0.15 + mathrandom () * 0.15,
						z = 0,
					},
					expirationtime = 0.65 + mathrandom () * 0.75,
					size = 2.0 + mathrandom () * 3.2,
					texture = "mcl_particles_smoke_anim.png^[colorize:" .. color .. ":235",
					animation = {
						type = "vertical_frames",
						aspect_w = 8,
						aspect_h = 8,
						length = 1.4 + mathrandom () * 0.5,
					},
				})
			end
		end

		self._flame_timer = (self._flame_timer or 0.0) - dtime
		if self._flame_timer <= 0.0 then
			self._flame_timer = BLAZE_FLAME_INTERVAL_MIN
				+ mathrandom () * (BLAZE_FLAME_INTERVAL_MAX
						   - BLAZE_FLAME_INTERVAL_MIN)
			core.add_particle ({
				pos = {
					x = pos.x + (mathrandom () - 0.5) * 0.95,
					y = pos.y + 0.35 + mathrandom () * 1.25,
					z = pos.z + (mathrandom () - 0.5) * 0.95,
				},
				velocity = {
					x = (mathrandom () - 0.5) * 0.14,
					y = 0.65 + mathrandom () * 0.40,
					z = (mathrandom () - 0.5) * 0.14,
				},
				expirationtime = 0.30 + mathrandom () * 0.25,
				size = 1.2 + mathrandom () * 1.8,
				glow = 12,
				texture = "mcl_particles_fire_flame.png^[colorize:#ffd27a:80",
			})
		end
	end,
}

core.register_entity ("mobs_mc:blaze", blaze)
