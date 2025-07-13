------------------------------------------------------------------------
-- Mob & vehicle mounting.
------------------------------------------------------------------------

local localplayer = mcl_localplayer.localplayer

------------------------------------------------------------------------
-- Mob mounting.
------------------------------------------------------------------------

-- Mobs w/ mob physics.
local mob_table = {
	_is_mountable = true,
	_is_mounted = false,
	_driving = false,
	movement_speed = 1.0,
	jump_height = 8.4,
	acc_dir = vector.zero (),
	default_switchtime = 0.0,
	_stuck_in = nil,
	horiz_collision = false,
	touching_ground = nil,
	ground_standon = nil,
	gravity = -1.6,
	jump_timer = 0.0,
	fall_distance = 0.0,
	last_fall_y = nil,
	safe_fall_distance = 3.0,
	fall_damage_multiplier = 1.0,
	water_friction = 0.8,
	water_velocity = 0.4,
	depth_strider_level = 0,
	_driver_eye_height = 0.0,
	_last_sent_pos = nil,
	_last_selt_vel = nil,
	animation = {
	},
	_current_animation = nil,
	_default_stepheight = 0.6,
	_EF = {}, -- Status effects.
	acc_speed = 0.0,
	_tsc = 0.0, -- Timestamp counter.
	_water_current = vector.zero (),
}

function mob_table:on_activate ()
	self._water_current = vector.zero ()
end

function mob_table:on_deactivate ()
end

function mob_table:apply_driver_input (dtime, controls)
end

function mob_table:post_apply_driver_input (controls, v)
end

local check_one_immersion_depth = mcl_localplayer.check_one_immersion_depth

local y_to_dimension = mcl_localplayer.y_to_dimension

function mob_table:check_standin (pos, params)
	if params.flying then
		return 0.0, nil
	end

	local cbox = self.collisionbox

	-- Initialize self.collisionbox if unset.
	if not cbox then
		local props = self.object:get_properties ()
		cbox = props.collisionbox
		self.collisionbox = cbox
	end

	local x0 = math.floor (cbox[1] + pos.x + 0.5)
	local x1 = math.floor (cbox[4] + pos.x + 0.5)
	local y0 = math.floor (cbox[2] + pos.y + 0.5)
	local y1 = math.floor (cbox[5] + pos.y + 0.5)
	local z0 = math.floor (cbox[3] + pos.z + 0.5)
	local z1 = math.floor (cbox[6] + pos.z + 0.5)
	local immersion_depth = 0.0
	local worst_type = nil
	local v = vector.new (0, 0, 0)
	local current = self._water_current
	current.x = 0
	current.y = 0
	current.z = 0
	local n_fluids = 0
	local dimension = y_to_dimension (pos.y)

	for y = y0, y1 do
		for x = x0, x1 do
			for z = z0, z1 do
				v.x = x
				v.y = y
				v.z = z
				local node = core.get_node_or_nil (v)
				local depth, liquidtype
					= check_one_immersion_depth (node, pos.y, v,
								     current, dimension)
				immersion_depth = math.max (depth, immersion_depth)
				if liquidtype then
					n_fluids = n_fluids + 1

					if worst_type ~= "lava" then
						worst_type = liquidtype
					end
				end
				if node then
					local factors = localplayer.movement_arresting_nodes[node.name]
					if factors then
						self._stuck_in = factors
					end
				end
			end
		end
	end
	if n_fluids > 0 then
		current.x = current.x / n_fluids
		current.y = current.y / n_fluids
		current.z = current.z / n_fluids
	end
	return immersion_depth, worst_type
end

function mob_table:check_water_flow (self_pos)
	return self._water_current
end

local function dist_horizontal_sqr (v1, v2)
	return (v1.x - v2.x) * (v1.x - v2.x)
		+ (v1.z - v2.z) * (v1.z - v2.z)
end

local function get_y_axis_collisions (self_pos, moveresult)
	local collisions = {}
	local supporting_node, dist

	for _, item in pairs (moveresult.collisions) do
		if item.type == "node" and item.axis == "y"
			and item.old_velocity.y < 0 then
			table.insert (collisions, item.node_pos)
			local d = dist_horizontal_sqr (self_pos, item.node_pos)
			if not supporting_node or d < dist then
				dist = d
				supporting_node = item.node_pos
			end
		end
	end
	if supporting_node then
		local node = core.get_node_or_nil (supporting_node)
		if node then
			node.pos = supporting_node
		end
		return collisions, node
	end
	return collisions
end

local horiz_collision = mcl_localplayer.horiz_collision

function mob_table:toggle_step_height (enable_step_height)
	if enable_step_height ~= self._previously_floating then
		mcl_localplayer.send_configure_vehicle ({
			touching_ground = enable_step_height,
			id = self.object:get_id (),
		})
		self._previously_floating = enable_step_height
		if enable_step_height then
			self.object:set_property_overrides ({
				stepheight = self._default_stepheight,
			})
		else
			self.object:set_property_overrides ({
				stepheight = 0.0,
			})
		end
	end
end

function mob_table:test_collision (self_pos, moveresult, v)
	if not self.horiz_collision then
		self.horiz_collision = horiz_collision (moveresult)
	end
	if not self.touching_ground then
		if moveresult.touching_ground then
			self.touching_ground, self.ground_standon
				= get_y_axis_collisions (self_pos, moveresult)
		end
	end

	-- Enable or disable stepheight according as this mob is
	-- colliding with the ground.
	self:toggle_step_height (moveresult.touching_ground)
end

local touching_only_ignore = mcl_localplayer.touching_only_ignore

function mob_table:check_fall_damage (self_pos, touching_ground, params)
	-- Integrate fall damage.
	if not params.flying then
		local fall_y = self.last_fall_y or self_pos.y
		local d = self.fall_distance + (fall_y - self_pos.y)
		self.fall_distance = math.max (d, 0)
		self.last_fall_y = self_pos.y
		if self.liquidtype == "water" or self._stuck_in then
			self.last_fall_y = nil
			self.fall_distance = 0
		elseif self.liquidtype == "lava" then
			self.fall_distance = self.fall_distance / 2
		end

		if touching_ground
			and not touching_only_ignore (touching_ground) then
			local distance = self.fall_distance
			if distance > self.safe_fall_distance then
				if mcl_localplayer.debug then
					print (string.format ("Detected mob fall of %.4f nodes", distance))
				end
				mcl_localplayer.send_damage ({
					type = "fall",
					amount = (distance - self.safe_fall_distance)
						* self.fall_damage_multiplier,
					damage_pos = self_pos,
					collisions = self.touching_ground,
					riding = self.object:get_id (),
				})
			end
			self.last_fall_y = nil
			self.fall_distance = 0
		end
		if self.reset_fall_damage then
			self.fall_distance = 0
		end
	else
		self.last_fall_y = nil
		self.fall_distance = 0
	end
	self.reset_fall_damage = false
end

function mob_table:post_motion_step (v, self_pos, control, params)
	local made_contact = self.touching_ground
	self._last_standon = self.standon
	self._last_standin = self.standin
	self._last_liquidtype = self.liquidtype
	self:check_fall_damage (self_pos, made_contact, params)
	self._was_touching_ground = self.touching_ground
end

local DEFAULT_ANIM_SPEED = 25

function mob_table:set_animation (name)
	if name == self._current_animation then
		return
	end

	if not name then
		self.object:set_animation (nil)
	else
		local animparams = self.animation[name]
		if animparams then
			self.object:set_animation (animparams, 0.2, true)
			self._current_animation = name
		end
	end
end

function mob_table:set_animation_speed ()
	local anim = self._current_animation
	if not anim or anim ~= "walk" then
		self.object:set_animation_frame_speed (DEFAULT_ANIM_SPEED)
		return
	end
	local v = self.object:get_velocity ()
	local v1 = math.sqrt (math.sqrt (v.x * v.x + v.z * v.z))
	local walk_speed = self.animation.walk_speed
		or DEFAULT_ANIM_SPEED
	self.object:set_animation_frame_speed (v1 * walk_speed)
end

function mob_table:has_effect (name)
	return self._EF[name] ~= nil
end

function mob_table:get_effect_level (name)
	if self._EF[name] then
		return self._EF[name].level
	else
		return 0
	end
end

function mob_table:accelerate_relative (acc, speed_x, speed_y)
	local yaw = self.object:get_yaw ()
	local acc_x, acc_y, acc_z
	local magnitude = vector.length (acc)
	if magnitude > 1.0 then
		acc_x = acc.x / magnitude * speed_x
		acc_y = acc.y / magnitude * speed_y
		acc_z = acc.z / magnitude * speed_x
	else
		acc_x = acc.x * speed_x
		acc_y = acc.y * speed_y
		acc_z = acc.z * speed_x
	end
	local s = -math.sin (yaw)
	local c = math.cos (yaw)
	local x = acc_x * c + acc_z * s
	local z = acc_z * c - acc_x * s
	return x, acc_y, z
end

function mob_table:get_jump_force ()
	local jump_boost_level = self:get_effect_level ("leaping")
	return self.jump_height + (jump_boost_level * 2.0)
end

function mob_table:jump_actual (v, jump_force)
	v = vector.new (v.x, jump_force, v.z)

	-- Apply acceleration if sprinting.
	if self._sprinting then
		local yaw = core.camera:get_look_horizontal ()
		v.x = v.x + math.sin (yaw) * -4.0
		v.z = v.z + math.cos (yaw) * 4.0
	end
	-- Disable stepheight; it should not be enabled during the
	-- first call to collision_move after motion_step, which is
	-- intended to assess whether it is to be enabled.
	self:toggle_step_height (false)
	return v
end

function mob_table:will_breach_water (self_pos, dx, dy, dz, params)
	local pos = vector.offset (self_pos, dx, dy, dz)
	if not core.collides (self.collisionbox, pos, true, self.object) then
		-- Verify that there is no liquid at the target
		-- position.
		local depth, _ = self:check_standin (pos, params)
		return depth <= 0.0
	end
	return false
end

local EMPTY_NODE = {
	name = "ignore",
	groups = {},
}

local AIR_DRAG			= 0.98
local AIR_FRICTION		= 0.91
local DOLPHIN_GRANTED_FRICTION	= 0.96
local WATER_DRAG		= 0.8
local LAVA_FRICTION		= 0.5
local LAVA_SPEED		= 0.4
local BASE_SLIPPERY_1		= 0.989
local BASE_SLIPPERY		= 0.98
local BASE_FRICTION		= 0.6
local BASE_FRICTION3		= math.pow (0.6, 3)
local LIQUID_JUMP_FORCE		= 0.8
local ONE_TICK			= 0.05
local TICK_TO_SEC		= 1 / ONE_TICK
local LEVITATION_TRANSITION	= 0.2
local SLOW_FALLING_GRAVITY	= -0.2
local MIN_VELOCITY		= 0.003 * TICK_TO_SEC

local function scale_speed (speed, friction)
	local f = BASE_FRICTION3 / (friction * friction * friction)
	return speed * f
end

local clamp = mcl_localplayer.clamp

function mob_table:motion_step (v, self_pos, moveresult, controls, params)
	local acc_dir = self.acc_dir
	local acc_speed = self.acc_speed
	local last_standon = self._last_standon
		and mcl_localplayer.node_defs[self._last_standon.name]
		or EMPTY_NODE
	local standin = self.standin
		and mcl_localplayer.node_defs[self.standin.name]
		or EMPTY_NODE
	local standon = self.standon
		and mcl_localplayer.node_defs[self.standon.name]
		or EMPTY_NODE
	local gravity = self.gravity
	local touching_ground = self.touching_ground
	local was_touching_ground = self._was_touching_ground
	local horiz_collision = self.horiz_collision

	if v.y <= 0.0 and self:has_effect ("slow_falling") then
		gravity = math.max (gravity, SLOW_FALLING_GRAVITY)
		self.reset_fall_damage = true
	end

	local p = AIR_DRAG
	acc_dir.x = acc_dir.x * p
	acc_dir.z = acc_dir.z * p

	local climbable = standin.climbable
	local jumping = self.jumping

	local velocity_factor = 1.0
	local liquidtype = self._last_liquidtype

	if standon and standon._mcl_velocity_factor and touching_ground then
		velocity_factor = standon._mcl_velocity_factor
	end
	self.jump_timer = self.jump_timer - 1

	if liquidtype == "water" then
		local water_vec = self:check_water_flow (self_pos)
		local water_friction = self.water_friction
		local friction = water_friction * velocity_factor
		local speed = self.water_velocity

		-- Apply depth strider.
		local level = math.min (3, self.depth_strider_level)
		level = touching_ground and level or level / 2
		if level > 0 then
			local delta = BASE_FRICTION * AIR_FRICTION - friction
			friction = friction + delta * level / 3
			delta = acc_speed - speed
			speed = speed + delta * level / 3
		end

		-- Apply Dolphin's Grace.
		if self:has_effect ("dolphin_grace") then
			friction = DOLPHIN_GRANTED_FRICTION
		end

		-- Adjust speed by friction.  Minecraft applies
		-- friction to acceleration (speed), not just the
		-- previous velocity.
		local r = friction
		local base_water_drag = WATER_DRAG
		local p = base_water_drag

		local fv_x, fv_y, fv_z
			= self:accelerate_relative (acc_dir, speed, speed)

		-- Apply friction and acceleration.
		v.x = v.x * r + fv_x
		v.y = v.y * p
		v.z = v.z * r + fv_z

		-- Apply vertical acceleration.
		v.y = v.y + fv_y

		-- Apply gravity unless this mob is sprinting.
		if not self._sprinting then
			v.y = v.y + gravity / 16
			if v.y > -0.06 and v.y < 0 then
				v.y = -0.06
			end
		end

		-- Apply water current.
		if water_vec and (water_vec.x >= 0
					or water_vec.y >= 0
					or water_vec.z >= 0) then
			v.x = v.x + water_vec.x
			v.y = v.y + water_vec.y
			v.z = v.z + water_vec.z
		end

		-- If colliding horizontally within water, detect
		-- whether the result of this movement is vertically
		-- within 0.6 nodes of a position clear of water and
		-- collisions, and apply a force to this mob so as to
		-- breach the water if so.
		if horiz_collision then
			local dx = v.x * ONE_TICK
			local dz = v.z * ONE_TICK
			local will_breach_water
				= self:will_breach_water (self_pos, dx, 0.6, dz, params)
			if will_breach_water then
				v.y = 6.0
			end
		end
	elseif liquidtype == "lava" then
		local lava_vec = self:check_water_flow (self_pos)
		local speed = LAVA_SPEED
		local r = LAVA_FRICTION
		local fv_x, fv_y, fv_z
			= self:accelerate_relative (acc_dir, speed, speed)
		v.x = v.x * r + fv_x
		v.y = v.y * p
		v.z = v.z * r + fv_z
		v.y = v.y + (gravity / 4.0)
		v.y = v.y + fv_y

		-- Apply lava current.
		if lava_vec and (lava_vec.x >= 0
					or lava_vec.y >= 0
					or lava_vec.z >= 0) then
			v.x = v.x + lava_vec.x
			v.y = v.y + lava_vec.y
			v.z = v.z + lava_vec.z
		end

		-- If colliding horizontally within lava,
		-- detect whether the result of this movement
		-- is vertically within 0.6 nodes of a
		-- position clear of lava and collisions, and
		-- apply a force to this mob so as to breach
		-- the water if so.
		if horiz_collision then
			local dx = v.x * ONE_TICK
			local dz = v.z * ONE_TICK
			local will_breach_lava
				= self:will_breach_water (self_pos, dx, 0.6, dz, params)
			if will_breach_lava then
				v.y = 6.0
			end
		end
	else
		-- If not standing on air, apply slippery to a base value of
		-- 0.6.
		local slippery = last_standon.groups.slippery
		local friction
		-- The order in which Minecraft applies velocity is
		-- such that it is scaled by ground friction after
		-- application even if vertical acceleration would
		-- render the mob airborne.  Emulate this behavior, in
		-- order to avoid a marked disparity in the speed of
		-- mobs that jump while in motion or walk off ledges.
		if was_touching_ground and slippery and slippery > 0 then
			if slippery > 3 then
				friction = BASE_SLIPPERY_1
			else
				friction = BASE_SLIPPERY
			end
		elseif was_touching_ground then
			friction = BASE_FRICTION
		else
			friction = 1
		end

		-- Apply friction, relative movement, and speed.
		local speed

		if touching_ground or climbable then
			speed = scale_speed (acc_speed, friction)
		else
			speed = 0.4 -- 0.4 blocks/s
		end
		-- Apply friction (velocity_factor) from Soul Sand and
		-- the like.  NOTE: this friction is supposed to be
		-- applied after movement, just as with standard
		-- friction.
		friction = friction * AIR_FRICTION * velocity_factor

		-- Adjust speed by friction.  Minecraft applies
		-- friction to acceleration (speed), not just the
		-- previous velocity.  The manner in which friction is
		-- applied to acceleration is very peculiar, in that
		-- mobs are moved by the original speed each tick,
		-- before the modified speed is integrated into the
		-- velocity.
		--
		-- In Minetest, this is emulated by integrating the
		-- full speed into the velocity after applying
		-- friction to the same, which is more logical anyway.
		local base_air_drag = AIR_DRAG
		local r = friction
		local p = base_air_drag
		local fv_x, fv_y, fv_z
			= self:accelerate_relative (acc_dir, speed, speed)

		local levitate = self:get_effect_level ("levitation")
		if levitate == 0.0 then
			v.x = v.x * r + fv_x
			v.y = v.y * p + gravity * base_air_drag
			v.z = v.z * r + fv_z
			v.y = v.y + fv_y
		else
			v.x = v.x * r + fv_x
			v.y = v.y * p + ((levitate - v.y) * LEVITATION_TRANSITION) * base_air_drag
			v.z = v.z * r + fv_z
			v.y = v.y + fv_y
			self.reset_fall_damage = true
		end
	end

	if jumping then
		if liquidtype then
			v.y = v.y + LIQUID_JUMP_FORCE
		else
			if self.touching_ground and self.jump_timer <= 0 then
				local force = self:get_jump_force ()
				v = self:jump_actual (v, force)
				self.jump_timer = 10
			end
		end
	else
		self.jump_timer = 0
	end

	if climbable then
		if v.y < -3.0 then
			v.y = -3.0
		end
		v.x = clamp (v.x, -3.0, 3.0)
		v.z = clamp (v.z, -3.0, 3.0)
		if jumping or horiz_collision then
			v.y = 4.0
			self.jumping = false
		end
		self.reset_fall_damage = true
	end

	if v.x > -MIN_VELOCITY and v.x < MIN_VELOCITY then
		v.x = 0
	end
	if v.y > -MIN_VELOCITY and v.y < MIN_VELOCITY then
		v.y = 0
	end
	if v.z > -MIN_VELOCITY and v.z < MIN_VELOCITY then
		v.z = 0
	end

	-- self:check_collision (self_pos)
	return v
end

function mob_table:drive_physics (dtime, moveresult, params, control)
	local self_pos = self.object:get_pos ()

	local switchtime = self.default_switchtime
	local t = switchtime + dtime
	if t < ONE_TICK then
		self:test_collision (self_pos, moveresult)
	end

	-- Set self.standin and self.standon.
	local diff = math.abs (self_pos.y - (math.floor (self_pos.y) + 0.5))
	local test_pos = vector.offset (self_pos, 0, 0.01, 0)
	self.standin = core.get_node_or_nil (test_pos)
	self.standon = self.standin
	if diff <= 0.01 then
		test_pos.y = test_pos.y - 1
		self.standon = core.get_node_or_nil (test_pos)
	end
	if self.standon then
		self.standon.pos = test_pos
	end
	if not self._last_standon or not self._last_standin then
		self._last_standon = self.standon
		self._last_standin = self.standin
	end

	-- Extract supporting nodes from the moveresult if possible.
	if self.ground_standon then
		self.standon = self.ground_standon
	end

	-- Compute fluid immersion.
	local immersion_depth, liquidtype
		= self:check_standin (self_pos, params)
	self._immersion_depth = immersion_depth
	self.liquidtype = liquidtype

	-- Set animation speed.
	local v = self.object:get_velocity ()
	if (v.x * v.x + v.z * v.z) > 0.25 then
		self:set_animation ("walk")
	else
		self:set_animation ("stand")
	end
	self:set_animation_speed ()

	--------------------------------------------------------
	-- Physics section of globalstep.
	--------------------------------------------------------
	local tsc = self._tsc + dtime
	self._tsc = tsc
	if t >= ONE_TICK then
		-- Apply that portion of the globalstep which elapsed
		-- before this globalstep.
		local adj_pos = params.old_position
		local v = params.old_velocity
		local before = ONE_TICK - switchtime % ONE_TICK

		adj_pos, v, moveresult
			= self.object:collision_move (adj_pos, v, before)
		self:test_collision (adj_pos, moveresult, v)

		-- Run the physics simulation.
		local phys_start = switchtime + before
		while phys_start <= t do
			local time = math.min (ONE_TICK, t - phys_start)
			local stuck_in = self._stuck_in
			if stuck_in then
				v = vector.zero ()
				self._stuck_in = nil
			end
			v = self:motion_step (v, adj_pos, moveresult, control, params)
			self:post_motion_step (v, adj_pos, control, params)
			self:post_apply_driver_input (control, v)

			-- Clear collision detection flags.  They will
			-- be set as collisions are detected over the
			-- span of the next globalstep.
			self.horiz_collision = false
			self.touching_ground = false
			self.ground_standon = nil
			if stuck_in then
				v.x = v.x * stuck_in.x
				v.y = v.y * stuck_in.y
				v.z = v.z * stuck_in.z
			end
			adj_pos, v, moveresult
				= self.object:collision_move (adj_pos, v, time)
			self:test_collision (adj_pos, moveresult, v)
			phys_start = phys_start + ONE_TICK
		end
		self.object:set_pos (adj_pos)
		self.object:set_velocity (v)
		self.default_switchtime = t % ONE_TICK

		if not self._last_sent_pos or not self._last_sent_vel
			or not vector.equals (self._last_sent_pos, adj_pos)
			or not vector.equals (self._last_sent_vel, v) then
			local id = self.object:get_id ()
			self._last_sent_pos = adj_pos
			self._last_sent_vel = v
			local tsc_1 = math.round (tsc * 5000)
			mcl_localplayer.send_move_vehicle (id, tsc_1, adj_pos, v)
		end
	else
		self.default_switchtime = t
	end
end

function mob_table:on_step (dtime, moveresult, params)
	if self._driving then
		if not moveresult then
			moveresult = {
				touching_ground = false,
				collides = false,
				standing_on_object = false,
				collisions = { },
			}
		end

		local controls = core.localplayer:get_control ()
		self.object:set_yaw (core.camera:get_look_horizontal ())
		self:apply_driver_input (dtime, controls)
		self:drive_physics (dtime, moveresult, params, controls)
	end
end

local ZERO_VECTOR = vector.zero ()
local DRIVER_EYE_HEIGHT_FACTOR = "mcl_localplayer:driver_eye_height"

function mob_table:import_vehicle_capabilities (caps)
	if caps._driving ~= nil then
		if type (caps._driving) ~= "boolean" then
			error ("Invalid `driving' field in vehicle capability table")
		end
		self._driving = caps._driving
		if not self._driving then
			self:stop_driving ()
		else
			local self_pos = self.object:get_pos ()
			self.object:set_velocity (ZERO_VECTOR)
			self.object:set_pos (self_pos)
		end
	end

	if caps.movement_speed then
		if type (caps.movement_speed) ~= "number" then
			error ("Invalid `movement_speed' field in vehicle capability table")
		end
		self.movement_speed = caps.movement_speed
	end

	if caps.jump_height then
		if type (caps.jump_height) ~= "number" then
			error ("Invalid `jump_height' field in vehicle capability table")
		end
		self.jump_height = caps.jump_height
	end

	if caps.ef_set and caps._EF then
		if type (caps._EF) ~= "table" then
			error ("Invalid status effect table in vehicle capability table")
		end
		for k, v in pairs (caps._EF) do
			if type (k) ~= "string"
				or type (v) ~= "table"
				or type (v.level) ~= "number"
				or type (v.factor) ~= "number" then
				error ("Invalid status effect definition")
			end
		end
		self._EF = caps._EF
	elseif caps.ef_set then
		self._EF = {}
	end
end

function mob_table:stop_driving ()
	self._previously_floating = nil
	self.object:set_animation (nil)
	self.object:set_animation_frame_speed (nil)
	self.object:set_velocity (nil)
	self.object:set_pos (nil)
	self.object:set_rotation (nil)
	self.object:clear_property_overrides ({"stepheight"})
end

function mob_table:dismount ()
	self._driving = false
	self._last_sent_pos = nil
	self._last_sent_vel = nil
	self:stop_driving ()
	local p = mcl_localplayer.localplayer
	p:remove_physics_factor ("target_eye_height", DRIVER_EYE_HEIGHT_FACTOR)
	mcl_localplayer.set_mount_pose (mcl_localplayer.POSE_MOUNTED)
end

function mob_table:init_mount ()
	self.movement_speed = 0.0
	self._driving = false
	self._last_sent_pos = nil
	self._last_sent_vel = nil
	local p = mcl_localplayer.localplayer
	p:add_physics_factor ("target_eye_height", DRIVER_EYE_HEIGHT_FACTOR,
			self._driver_eye_height, "add")
	mcl_localplayer.set_mount_pose (mcl_localplayer.POSE_SIT_MOUNTED)
end

local PLACEHOLDER_VECTOR = vector.new (1.0e+6, 1.0e+6, 1.0e+6)

function mob_table:import_position (pos, vel)
	if self._driving then
		if not vector.equals (pos, PLACEHOLDER_VECTOR) then
			self.object:set_pos (pos)
		end
		if not vector.equals (vel, PLACEHOLDER_VECTOR) then
			self.object:set_velocity (vel)
		end
	end
end

function mcl_localplayer.register_mountable_mob (name, decl)
	core.register_entity (name, decl)
end

------------------------------------------------------------------------
-- Mountable mobs.
------------------------------------------------------------------------

-- Horse & friends.
local horse = table.merge (mob_table, {
	_jump_charge = 0.0,
	safe_fall_distance = 6.0,
	fall_damage_multiplier = 0.5,
	_driver_eye_height = 0.3,
	animation = {
		stand = {
			x = 0,
			y = 0,
		},
		stand_speed = 25,
		walk = {
			x = 0,
			y = 40,
		},
		walk_speed = 25,
	},
	_default_stepheight = 1.01,
})

function horse:apply_driver_input (dtime, controls)
	if controls.movement_x then
		self.acc_dir.z = controls.movement_y
		self.acc_dir.x = controls.movement_x * 0.5
	else
		local x = (controls.left and -1.0 or 0.0)
			+ (controls.right and 1.0 or 0.0)
		local z = (controls.up and 1.0 or 0.0)
			+ (controls.down and -1.0 or 0.0)
		self.acc_dir.z = z
		self.acc_dir.x = x * 0.5
	end
	self.acc_speed = self.movement_speed

	if self.acc_dir.z < 0 then
		self.acc_dir.z = self.acc_dir.z * 0.5
	end

	self.jumping = false
	if controls.jump then
		if self._jump_charge == nil then
			self._jump_charge = 0.0
		end
		local charge = self._jump_charge
		self._jump_charge = charge + dtime
	end
end

function horse:post_apply_driver_input (controls, v)
	if not controls.jump
		and self._jump_charge and self._jump_charge > 0.0 then
		if not self.touching_ground then
			return
		end

		local mc_ticks = math.floor (self._jump_charge * 20)
		local scale

		if mc_ticks >= 10 then
			scale = 0.8 + 2.0 / (mc_ticks - 9) * 0.1
		else
			scale = mc_ticks * 0.1
		end
		if scale >= 0.9 then
			scale = 1.0
		else
			scale = 0.4 + 0.4 * scale / 0.9
		end

		-- TODO: horses should rear up after jumping.
		v.y = scale * self.jump_height
		self._jump_charge = 0
	end
end

function horse:init_mount ()
	mob_table.init_mount (self)
	self._jump_charge = 0.0
end

mcl_localplayer.register_mountable_mob ("mobs_mc:horse", horse)
mcl_localplayer.register_mountable_mob ("mobs_mc:skeleton_horse", horse)
mcl_localplayer.register_mountable_mob ("mobs_mc:zombie_horse", horse)
mcl_localplayer.register_mountable_mob ("mobs_mc:donkey", horse)
mcl_localplayer.register_mountable_mob ("mobs_mc:mule", horse)

--- Pig.

local pig = table.merge (mob_table, {
	_drive_boost_total = 0.0,
	_drive_boost_elapsed = 0.0,
	animation = {
		stand = {
			x = 0,
			y = 0,
		},
		stand_speed = 0,
		walk = {
			x = 0,
			y = 40,
		},
		walk_speed = 55,
	},
})

local PIG_DRIVE_BONUS = 0.225

function pig:init_mount ()
	mob_table.init_mount (self)
	self._drive_boost_elapsed = 0.0
	self._drive_boost_total = 0.0
end

function pig:import_vehicle_capabilities (caps)
	mob_table.import_vehicle_capabilities (self, caps)
	if caps._drive_boost_total then
		if type (caps._drive_boost_total) ~= "number" then
			error ("Invalid _drive_boost_total")
		end
		self._drive_boost_total = caps._drive_boost_total

		if caps._drive_boost_elapsed then
			if type (caps._drive_boost_elapsed) ~= "number" then
				error ("Invalid _drive_boost_elapsed")
			end
			self._drive_boost_elapsed = caps._drive_boost_elapsed
		else
			self._drive_boost_elapsed = 0.0
		end
	end
end

function pig:apply_driver_input (dtime, controls)
	local bonus = 1.0
	if self._drive_boost_total ~= 0.0 then
		local t = self._drive_boost_elapsed + dtime
		if t > self._drive_boost_total then
			self._drive_boost_total = 0.0
		else
			local total = self._drive_boost_total
			bonus = 1.0 + 1.5 * math.sin (t / total * math.pi)
		end
		self._drive_boost_elapsed = t
	end
	self.acc_speed = self.movement_speed * PIG_DRIVE_BONUS * bonus
	self.acc_dir.z = 1

	self.jumping = false
	if self.horiz_collision then
		self.jumping = true
	end
end

mcl_localplayer.register_mountable_mob ("mobs_mc:pig", pig)

------------------------------------------------------------------------
-- Mounting other vehicles (namely boats).
------------------------------------------------------------------------

local boat = {
	_is_boat = true,
	_last_sent_pos = nil,
	_last_sent_vel = nil,
	_last_sent_yaw = nil,
	_yaw_acc = 0.0,
	_is_mountable = true,
	_is_mounted = false,
	_default_switchtime = 0.0,
	_tsc = 0.0,
	_speed = 0.0,
	_next_yaw = 0.0,
}

local YAW_DRAG = 0.05
local BOAT_DRAG = 0.45

local BOAT_ANIMATION = {
	x = 0,
	y = 40,
}

local boat_y_offset = 0.35

local function is_water (pos)
	local node = core.get_node_or_nil (pos)
	if node then
		local def = mcl_localplayer.node_defs[node.name]
		return def and def.groups.water
	end
	return false
end

local function is_ice (pos)
	local node = core.get_node_or_nil (pos)
	if node then
		local def = mcl_localplayer.node_defs[node.name]
		return def and def.groups.ice
	end
	return false
end

local function signbit (x)
	return x < 0.0 and -1 or (x > 0.0 and 1 or 0.0)
end

-- Forward declaration.
local previous_mount = nil

function mcl_localplayer.orient_camera_on_boat (dtime)
	local mount = previous_mount
	if mount then
		local entity = mount:get_luaentity ()
		if entity._is_boat then
			entity:turn_camera (dtime)
		end
	end
end

function boat:turn_camera (dtime)
	local p = math.pow (YAW_DRAG, dtime)
	local scale = (1 - p) / (1 - YAW_DRAG)
	local yaw = self._next_yaw
	local delta = self._yaw_acc * scale
	mcl_localplayer.add_cam_offsets (delta, 0)
	mcl_localplayer.lock_yaw (yaw + delta)
	self._next_yaw = yaw + delta
	self._yaw_acc = self._yaw_acc * p
end

function boat:drive (dtime, moveresult, params)
	local ctrl = core.localplayer:get_control ()
	local vel = self.object:get_velocity ()
	local speed = math.sqrt (vel.x * vel.x + vel.z * vel.z)
		* signbit (self._speed)
	local yaw = self._next_yaw
	-- The camera yaw is adjusted before this mob is ridden, as
	-- object on_step functions are called after the LocalPlayer's
	-- and adjusting the camera's orientation here would produce a
	-- one frame delay.
	self.object:set_yaw (yaw)
	if ctrl.left then
		self._yaw_acc = self._yaw_acc + (dtime * math.pi * 1.5)
	elseif ctrl.right then
		self._yaw_acc = self._yaw_acc - (dtime * math.pi * 1.5)
	else
		self._yaw_acc = self._yaw_acc
		if math.abs (self._yaw_acc) < (math.pi / 60) then
			self._yaw_acc = 0
		end
	end

	-- Apply gravity and orient player.
	local self_pos = self.object:get_pos ()
	local test_pos = vector.copy (self_pos)
	local on_water = is_water (test_pos)
	test_pos.y = self_pos.y - boat_y_offset
	if not on_water then
		-- Free fall.
		vel.y = vel.y - 9.81 * dtime
	else
		test_pos.y = test_pos.y + 1

		if is_water (test_pos) then
			-- Sink slowly while submerged.
			vel.y = math.max (-0.2, vel.y - 0.2 * dtime)
		else
			-- Above water.
			vel.y = 0.0
		end
	end
	test_pos.y = self_pos.y - boat_y_offset - 0.1
	local on_ice = is_ice (test_pos)
	local acc = 5.0

	if not on_ice and not on_water then
		acc = 0.4
	end

	if ctrl.up then
		speed = speed + acc * dtime
	elseif ctrl.down then
		speed = speed - acc * dtime
	else
		speed = speed * math.pow (BOAT_DRAG, dtime)
		if math.abs (speed) < 0.1 and speed ~= 0.0 then
			speed = 0.0
			self.object:set_animation (BOAT_ANIMATION, 0.2, true)
		end
	end

	local terminal_velocity = on_ice and 57.1
		or (on_water and 8.0 or 0.7)
	if speed > terminal_velocity then
		speed = terminal_velocity
	elseif speed < -terminal_velocity then
		speed = -terminal_velocity
	end

	vel.z = math.cos (yaw) * speed
	vel.x = -math.sin (yaw) * speed
	self.object:set_velocity (vel)
	self._speed = speed
	local f = math.sqrt (math.abs (speed))
	self.object:set_animation_frame_speed (f * 8)

	local tsc = self._tsc + dtime
	self._tsc = tsc

	local t = self._default_switchtime + dtime
	if t >= 0.10 then
		t = t % 0.10
		local id = self.object:get_id ()
		local pos = self.object:get_pos ()
		local tsc_1 = math.round (tsc * 5000)
		if not self._last_sent_pos
			or not self._last_sent_vel
			or not vector.equals (self._last_sent_pos, pos)
			or not vector.equals (self._last_sent_vel, vel) then
			mcl_localplayer.send_move_vehicle (id, tsc_1, pos, vel)
			self._last_sent_pos = pos
			self._last_sent_vel = vel
		end
		if self._last_sent_yaw ~= yaw then
			mcl_localplayer.send_turn_vehicle (id, tsc_1, yaw)
			self._last_sent_yaw = yaw
		end
	end
	self._default_switchtime = t
end

function boat:import_vehicle_capabilities (caps)
end

function boat:import_position (pos, vel)
	if not vector.equals (pos, PLACEHOLDER_VECTOR) then
		self.object:set_pos (pos)
	end
	if not vector.equals (vel, PLACEHOLDER_VECTOR) then
		self.object:set_velocity (vel)
	end
end

local BOAT_ANIMATION = {
	x = 0,
	y = 40,
}

function boat:init_mount ()
	self.object:set_animation (BOAT_ANIMATION, 0.2, true)
	self._last_sent_pos = nil
	self._last_sent_vel = nil
	self._last_sent_yaw = nil
	self._yaw_acc = 0.0
	self.speed = 0.0
	self._next_yaw = self.object:get_yaw ()
	mcl_localplayer.lock_yaw (self._next_yaw)

	local self_pos = self.object:get_pos ()
	self.object:set_velocity (ZERO_VECTOR)
	self.object:set_pos (self_pos)
	mcl_localplayer.set_mount_pose (mcl_localplayer.POSE_MOUNTED)
end

function boat:dismount ()
	self.object:set_animation_frame_speed (nil)
	self.object:set_animation (nil)
	self.object:set_velocity (nil)
	self.object:set_pos (nil)
	self.object:set_rotation (nil)
	mcl_localplayer.unlock_yaw ()
	mcl_localplayer.set_mount_pose (mcl_localplayer.POSE_MOUNTED)
end

function boat:on_step (dtime, moveresult, params)
	if self._is_mounted then
		self:drive (dtime, moveresult, params)
	end
end

function boat:on_deactivate ()
	if self._is_mounted then
		mcl_localplayer.unlock_yaw ()
	end
end

core.register_entity ("mcl_boats:boat", boat)
core.register_entity ("mcl_boats:chest_boat", boat)

------------------------------------------------------------------------
-- Object mounting protocol.
------------------------------------------------------------------------

local pending_handoff = nil
local pending_vehicle_capabilities = nil

function mcl_localplayer.update_mounting (mount)
	if not mount then
		if previous_mount and previous_mount:is_valid () then
			local entity = previous_mount:get_luaentity ()
			entity._is_mounted = false
			entity:dismount ()
		end
		previous_mount = nil
		return
	end

	if mount:get_id () == pending_handoff then
		local entity = mount:get_luaentity ()
		assert (entity)
		entity._is_mounted = true
		if mcl_localplayer.debug then
			print ("Mounted object: " .. pending_handoff)
		end
		pending_handoff = nil
		previous_mount = mount
		entity:init_mount ()
		if pending_vehicle_capabilities then
			entity:import_vehicle_capabilities (pending_vehicle_capabilities)
			pending_vehicle_capabilities = nil
		end
	end
end

function mcl_localplayer.handle_vehicle_handoff (vehicle_type, objid)
	local def = core.registered_entities[vehicle_type]
	if not def or not def._is_mountable then
		mcl_localplayer.send_refuse_vehicle (objid)
	else
		pending_handoff = objid
		pending_vehicle_capabilities = nil
		mcl_localplayer.send_acknowledge_vehicle (objid)
	end
end

function mcl_localplayer.handle_vehicle_position (objid, pos, vel)
	local vehicle = core.localplayer:get_object ():get_attach ()
	if vehicle and vehicle:get_id () == objid then
		local entity = vehicle:get_luaentity ()
		entity:import_position (pos, vel)
	end
end

function mcl_localplayer.handle_rescind_vehicle (objid)
	if pending_handoff == objid then
		pending_handoff = nil
		pending_vehicle_capabilities = nil
	end
	local mount = previous_mount
	if mount and mount:get_id () == objid then
		local entity = mount:get_luaentity ()
		entity._is_mounted = false
		entity:dismount ()
		previous_mount = nil
	end
end

function mcl_localplayer.handle_vehicle_capabilities (objid, caps)
	if pending_handoff == objid then
		if pending_vehicle_capabilities then
			local old = pending_vehicle_capabilities
			pending_vehicle_capabilities = table.merge (old, caps)
		else
			pending_vehicle_capabilities = caps
		end
		return
	end

	local mount = previous_mount
	if not mount or mount:get_id () ~= objid then
		return
	end
	local entity = mount:get_luaentity ()

	if mount:get_id () == objid then
		if mcl_localplayer.debug then
			print ("Vehicle capabilities: " .. dump (caps))
		end
		entity:import_vehicle_capabilities (caps)
	end
end
