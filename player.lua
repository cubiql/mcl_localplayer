------------------------------------------------------------------------
-- Player physics and input.
------------------------------------------------------------------------

local POSE_STANDING = 1
local POSE_CROUCHING = 2
local POSE_SLEEPING = 3
local POSE_FALL_FLYING = 4
local POSE_SWIMMING = 5
local POSE_SIT_MOUNTED = 6
local POSE_MOUNTED = 7
local POSE_DEATH = 8

mcl_localplayer.POSE_STANDING = POSE_STANDING
mcl_localplayer.POSE_CROUCHING = POSE_CROUCHING
mcl_localplayer.POSE_FALL_FLYING = POSE_FALL_FLYING
mcl_localplayer.POSE_SWIMMING = POSE_SWIMMING
mcl_localplayer.POSE_SIT_MOUNTED = POSE_SIT_MOUNTED
mcl_localplayer.POSE_MOUNTED = POSE_MOUNTED
mcl_localplayer.POSE_DEATH = POSE_DEATH

local STANDARD_FOV_FACTOR = 1.0

local PLAYER_EVENT_JUMP = 1

local localplayer = {
	acc_dir = vector.zero (),
	movement_speed = 2.0,
	jump_height = 8.4,
	jump_timer = 0,
	jumping = false,
	gravity = -1.6,
	touching_ground = false,
	_was_touching_ground = false,
	_sprinting = false,
	water_friction = 0.8,
	water_velocity = 0.4,
	depth_strider_level = 0,
	_previously_floating = false,
	_last_standin = nil,
	_last_standon = nil,
	collisionbox = nil,
	immersion_depth = 0.0,
	liquidtype = nil,
	_last_liquidtype = nil,
	pose = POSE_STANDING,
	default_switchtime = 0.0,
	fall_flying = false,
	swimming = false,
	animation = "stand",
	eye_height_time = 0.0,
	current_eye_height = -1,
	target_eye_height = 1.6,
	_last_move_yaw = 0,
	sneak_speed_bonus = 0.0,
	can_sprint = false,
	movement_arresting_nodes = {},
	_stuck_in = nil,
	_physics_factors = {},
	fov_factor = STANDARD_FOV_FACTOR,
	noticed_fov_factor = 0.0,
	horiz_collision = false,
	minor_collision = false,
	server_movement_state = {},
	can_fall_fly = false,
	rocket_ticks = 0,
	fall_distance = 0.0,
	last_fall_y = nil,
	safe_fall_distance = 3.0,
	damage_immune = 0,
	reset_fall_damage = false,
	overriding_pose = nil,
	_was_jumping = false,
	blocking = 0,
	ground_standon = nil,
	mount = nil,
	yaw_offset = 0.0,
	pitch_offset = 0.0,
	yaw_locked = false,
	mount_pose = POSE_MOUNTED,
	_bone_overrides = {},
	last_yaw = 0.0,
	animation_speed = nil,
	_water_current = vector.zero (),
	offhand_item = ItemStack (),
	health = 20,
	hunger = 20,
	saturation = 20,
}
mcl_localplayer.localplayer = localplayer

local profile = mcl_localplayer.profile
local profile_done = mcl_localplayer.profile_done

local AIR_DRAG			= 0.98
local AIR_FRICTION		= 0.91
local DOLPHIN_GRANTED_FRICTION	= 0.96
local WATER_DRAG		= 0.8
local SPRINTING_WATER_DRAG	= 0.9
local LAVA_FRICTION		= 0.5
local LAVA_SPEED		= 0.4
local BASE_SLIPPERY_1		= 0.989
local BASE_SLIPPERY		= 0.98
local BASE_FRICTION		= 0.6
local LIQUID_FORCE		= 0.28
local LAVA_FORCE		= 0.09
local LAVA_FORCE_NETHER		= 0.14
local BASE_FRICTION3		= math.pow (0.6, 3)
local LIQUID_JUMP_FORCE		= 0.8
local ONE_TICK			= 0.05
local TICK_TO_SEC		= 1 / ONE_TICK
local WATER_DESCENT		= -0.8
local PLAYER_FLY_DRAG		= 0.6
local PLAYER_CROUCH_FACTOR	= 0.3
local FALL_FLYING_DRAG_HORIZ	= 0.99
local FALL_FLYING_DRAG_ASCENT	= 0.04
local FALL_FLYING_ACC_DESCENT	= 3.2
local FALL_FLYING_ROTATION_DRAG = 0.1
local LEVITATION_TRANSITION	= 0.2
local SLOW_FALLING_GRAVITY	= -0.2
local MIN_VELOCITY		= 0.003 * TICK_TO_SEC

local function scale_speed (speed, friction)
	local f = BASE_FRICTION3 / (friction * friction * friction)
	return speed * f
end

function localplayer:get_flying_speed (params)
	if params.flying then
		return self._sprinting and 4.0 or 2.0 -- 2.0 blocks/s
	else
		return self._sprinting and 0.52 or 0.4 -- 0.4 blocks/s
	end
end

function localplayer:accelerate_relative (acc, speed_x, speed_y)
	local yaw = self.last_yaw
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

function localplayer:get_jump_force ()
	local jump_boost_level
		= mcl_localplayer.get_effect_level ("leaping")
	return self.jump_height + (jump_boost_level * 2.0)
end

function localplayer:jump_actual (v, jump_force)
	v = vector.new (v.x, jump_force, v.z)

	-- Apply acceleration if sprinting.
	if self._sprinting then
		local yaw = self.last_yaw
		v.x = v.x + math.sin (yaw) * -4.0
		v.z = v.z + math.cos (yaw) * 4.0
	end
	mcl_localplayer.send_movement_event (PLAYER_EVENT_JUMP)
	self.localplayer:set_touching_ground (false)
	-- Disable stepheight; it should not be enabled during the
	-- first call to collision_move after motion_step, which is
	-- intended to assess whether it is to be enabled.
	self:toggle_step_height (false)
	return v
end

local function horiz_collision (moveresult)
	for _, item in ipairs (moveresult.collisions) do
		if item.axis == "x" or item.axis == "z" then
			-- Exclude ignore nodes from collision detection.
			if item.type ~= "node"
				or core.get_node_or_nil (item.node_pos) then
				return true, item.old_velocity, item.new_velocity
			end
		end
	end
	return false, nil
end

mcl_localplayer.horiz_collision = horiz_collision

local function clamp (num, min, max)
	return math.min (max, math.max (num, min))
end

mcl_localplayer.clamp = clamp

local EMPTY_NODE = {
	name = "ignore",
	groups = {},
}

local function check_one_immersion_depth (node, base_y, pos, current, dimension)
	local def = node and mcl_localplayer.node_defs [node.name] or nil
	local liquid_type = def and (def.liquidtype or def._liquidtype)
	if liquid_type and liquid_type ~= "none" then
		local height
		if def.liquid_type == "flowing" then
			height = 0.1 + node.param2 * 0.1
		else
			height = 1.0
		end
		if pos.y + height - 0.5 > base_y then
			local depth = ((pos.y - 0.5) + height - base_y)
			-- Integrate liquid current.

			local v = miniflowlib.quick_flow (pos, node)

			if depth < 0.4 then
				v.x = v.x * depth
				v.y = v.y * depth
				v.z = v.z * depth
			end

			local fluidtype
			if def.groups.lava then
				fluidtype = "lava"
				local force = dimension == "nether"
					and LAVA_FORCE_NETHER or LAVA_FORCE
				current.x = current.x + v.x * force
				current.y = current.y + v.y * force
				current.z = current.y + v.z * force
			else
				fluidtype = "water"
				current.x = current.x + v.x * LIQUID_FORCE
				current.y = current.y + v.y * LIQUID_FORCE
				current.z = current.y + v.z * LIQUID_FORCE
			end
			return depth, fluidtype
		end
	end
	return 0.0, nil
end

mcl_localplayer.check_one_immersion_depth = check_one_immersion_depth

function localplayer:check_water_flow (self_pos)
	local current = self._water_current
	return current
end

function mcl_localplayer.get_node_def (name)
	return mcl_localplayer.node_defs[name]
end

local mg_overworld_min = -128
local mg_nether_min = -29067
local mg_nether_max = mg_nether_min + 128
local mg_end_min = -27073
local mg_end_max = mg_overworld_min - 2000

local function y_to_dimension (y)
	if y >= mg_overworld_min then
		return "overworld"
	elseif y >= mg_nether_min and y <= mg_nether_max + 128 then
		return "nether"
	elseif y >= mg_end_min and y <= mg_end_max then
		return "end"
	else
		return "void"
	end
end

mcl_localplayer.y_to_dimension = y_to_dimension

function localplayer:check_standin (pos, params)
	profile ("LocalPlayer check_standin")
	if params.flying then
		profile_done ("LocalPlayer check_standin")
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
				if liquidtype then
					n_fluids = n_fluids + 1

					if worst_type ~= "lava" then
						worst_type = liquidtype
					end
				end
				immersion_depth = math.max (depth, immersion_depth)
				if node then
					local factors = self.movement_arresting_nodes[node.name]
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
	profile_done ("LocalPlayer check_standin")
	return immersion_depth, worst_type
end

function localplayer:will_breach_water (self_pos, dx, dy, dz, params)
	local pos = vector.offset (self_pos, dx, dy, dz)
	if not core.collides (self.collisionbox, pos, true, self.object) then
		-- Verify that there is no liquid at the target
		-- position.
		local depth, _ = self:check_standin (pos, params)
		return depth <= 0.0
	end
	return false
end

local BASE_ROCKET_BOOST = 2.0
local ROCKET_BOOST_FORCE = 30.0

function localplayer:rocket_boost (self_pos, dir, v)
	if self.rocket_ticks > 0 then
		v.x = dir.x * BASE_ROCKET_BOOST
			+ (dir.x * ROCKET_BOOST_FORCE - v.x) * 0.5
			+ v.x
		v.y = dir.y * BASE_ROCKET_BOOST
			+ (dir.y * ROCKET_BOOST_FORCE - v.y) * 0.5
			+ v.y
		v.z = dir.z * BASE_ROCKET_BOOST
			+ (dir.z * ROCKET_BOOST_FORCE - v.z) * 0.5
			+ v.z
		self.rocket_ticks = self.rocket_ticks - 1
		local dir = vector.new (dir.x, 0, dir.z)
		local pos = vector.normalize (dir)
		local s = pos.x
		local c = pos.z
		pos.x = self_pos.x + (c * 0.5 + s * 0.7)
		pos.y = self_pos.y + 0.3
		pos.z = self_pos.z + (c * 0.7 - s * 0.5)
		core.add_particle ({
			pos = pos,
			expirationtime = 1.0,
			texture = "mcl_bows_rocket_particle.png^[colorize:#bc7a57:127",
		})
	end
end

function mcl_localplayer.apply_rocket_use (num_secs)
	local ticks = math.ceil (num_secs / ONE_TICK)
	localplayer.rocket_ticks = math.max (localplayer.rocket_ticks, ticks)
end

function localplayer:get_look_dir ()
	local mode = core.camera:get_camera_mode ()
	-- CAMERA_MODE_ANY displaces the remaining camera modes by 1
	-- which is not reflected in client_lua_api.md.
	return core.camera:get_look_dir () * (mode ~= 3 and 1 or -1)
end

function localplayer:motion_step (v, self_pos, moveresult, controls, params)
	profile ("LocalPlayer motion_step")
	profile ("LocalPlayer motion_step prologue")
	local acc_dir = self.acc_dir
	local acc_speed = self.movement_speed
	-- core.get_node_def is REALLY expensive because it
	-- reconstructing node definitions every time.  Avoid it like
	-- the plague.
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
	local touching_ground = not params.flying and self.touching_ground
	local was_touching_ground = not params.flying and self._was_touching_ground
	local horiz_collision = self.horiz_collision
	local damage_immune = math.max (self.damage_immune - 1, 0)
	self.damage_immune = damage_immune

	if v.y <= 0.0 and mcl_localplayer.has_effect ("slow_falling") then
		gravity = math.max (gravity, SLOW_FALLING_GRAVITY)
		self.reset_fall_damage = true
	end

	local p = AIR_DRAG
	acc_dir.x = acc_dir.x * p
	acc_dir.z = acc_dir.z * p

	local fly_y = v.y
	local climbable = standin.climbable
	local jumping = self.jumping

	local velocity_factor = 1.0
	local liquidtype = self._last_liquidtype

	if standon and standon._mcl_velocity_factor and touching_ground then
		velocity_factor = standon._mcl_velocity_factor
	end
	self.jump_timer = self.jump_timer - 1

	if self.swimming then
		local pitch = core.camera:get_look_vertical ()
		local transition_speed = pitch < -0.2 and 0.085 or 0.06
		v.y = v.y + ((pitch * 20) - v.y) * transition_speed
	end

	if self.fall_flying then
		local dir = self:get_look_dir ()
		self:rocket_boost (self_pos, dir, v)
	end
	profile_done ("LocalPlayer motion_step prologue")

	if liquidtype == "water" then
		profile ("LocalPlayer water movement")
		local water_vec = self:check_water_flow (self_pos)
		local water_friction = self.water_friction
		if self._sprinting then
			water_friction = SPRINTING_WATER_DRAG
		end
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
		if mcl_localplayer.has_effect ("dolphin_grace") then
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
		profile_done ("LocalPlayer water movement")
	elseif liquidtype == "lava" then
		profile ("LocalPlayer lava movement")
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
		profile_done ("LocalPlayer lava movement")
	elseif self.fall_flying then
		profile ("LocalPlayer fall flying")
		-- Limit fall_distance to 1.0 if vertical velocity is
		-- less than -0.5 n/tick.
		if v.y > -10.0 and self.fall_distance > 1.0 then
			self.fall_distance = 1.0
		end

		local dir = self:get_look_dir ()
		local pitch = -core.camera:get_look_vertical ()
		local horiz = math.sqrt (dir.x * dir.x + dir.z * dir.z)
		local movement = math.sqrt (v.x * v.x + v.z * v.z)
		local incline = math.cos (pitch)
		local v_movement = incline * incline
		v.y = v.y + -gravity * (-1.0 + v_movement * 0.75)
		-- Accelerate if moving downward.
		if v.y < 0.0 and horiz > 0.0 then
			local acc = v.y * ONE_TICK * -0.1 * v_movement
			v.x = v.x + (dir.x * acc / horiz) * TICK_TO_SEC
			v.y = v.y + acc * TICK_TO_SEC
			v.z = v.z + (dir.z * acc / horiz) * TICK_TO_SEC
		end
		-- Arrest horizontal movement when moving upward.
		if horiz > 0.0 and pitch < 0 then
			local arrest = movement * ONE_TICK * -math.sin (pitch)
				* FALL_FLYING_DRAG_ASCENT
			v.x = v.x + (-dir.x * TICK_TO_SEC) * arrest / horiz
			v.y = v.y + arrest * FALL_FLYING_ACC_DESCENT * TICK_TO_SEC
			v.z = v.z + (-dir.z * TICK_TO_SEC) * arrest / horiz
		end

		-- Apply rotation penalties.
		if movement > 0.0 then
			v.x = v.x + (dir.x / horiz * movement - v.x)
				* FALL_FLYING_ROTATION_DRAG
			v.z = v.z + (dir.z / horiz * movement - v.z)
				* FALL_FLYING_ROTATION_DRAG
		end

		v.x = v.x * FALL_FLYING_DRAG_HORIZ
		v.z = v.z * FALL_FLYING_DRAG_HORIZ
		v.y = v.y * AIR_DRAG
		profile_done ("LocalPlayer fall flying")
	else
		profile ("LocalPlayer movement")
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
			speed = self:get_flying_speed (params)
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

		local levitate = mcl_localplayer.get_effect_level ("levitation")
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
		profile_done ("LocalPlayer movement")
	end

	profile ("LocalPlayer motion_step epilogue")
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

		if v.y < 0 and controls.sneak then
			v.y = 0.0
		end
	end

	if params.flying then
		v.y = fly_y * PLAYER_FLY_DRAG
	end

	-- self:check_collision (self_pos)

	if v.x > -MIN_VELOCITY and v.x < MIN_VELOCITY then
		v.x = 0
	end
	if v.y > -MIN_VELOCITY and v.y < MIN_VELOCITY then
		v.y = 0
	end
	if v.z > -MIN_VELOCITY and v.z < MIN_VELOCITY then
		v.z = 0
	end
	profile_done ("LocalPlayer motion_step epilogue")
	profile_done ("LocalPlayer motion_step")
	return v
end

function localplayer:check_crouch_axis_x (self_pos, x)
	while x ~= 0 and not self:collides (self_pos, x * 0.1, -0.6, 0, true) do
		if x > 0 then
			x = math.max (0, x - ONE_TICK)
		else
			x = math.min (0, x + ONE_TICK)
		end
	end
	return x
end

function localplayer:check_crouch_axis_z (self_pos, z)
	while z ~= 0 and not self:collides (self_pos, 0, -0.6, z * 0.1, true) do
		if z > 0 then
			z = math.max (0, z - ONE_TICK)
		else
			z = math.min (0, z + ONE_TICK)
		end
	end
	return z
end

function localplayer:check_crouch_axis_both (self_pos, x, z)
	while x ~= 0 and not self:collides (self_pos, x * 0.1, -0.6, z * 0.1, true) do
		if x > 0 then
			x = math.max (0, x - ONE_TICK)
		elseif x < 0 then
			x = math.min (0, x + ONE_TICK)
		end
		if z > 0 then
			z = math.max (0, z - ONE_TICK)
		elseif z < 0 then
			z = math.min (0, z + ONE_TICK)
		end
	end
	return x, z
end

function localplayer:crouch_reduce_velocity (v, self_pos)
	profile ("LocalPlayer crouching")
	v.x = self:check_crouch_axis_x (self_pos, v.x)
	v.z = self:check_crouch_axis_z (self_pos, v.z)
	v.x, v.z = self:check_crouch_axis_both (self_pos, v.x, v.z)
	profile_done ("LocalPlayer crouching")
end

function localplayer:may_sprint (controls)
	return self.can_sprint
		and controls.movement_y > 0
		and self.pose ~= POSE_FALL_FLYING
		and not mcl_localplayer.is_using_bow ()
end

local SPEED_MODIFIER_SPRINTING = "mcl_localplayer:sprint_modifier"
local FOV_MODIFIER_SPRINTING = "mcl_localplayer:sprint_fov_modifier"

function localplayer:set_sprinting (is_sprinting)
	if is_sprinting then
		self._sprinting = is_sprinting
		self:add_physics_factor ("movement_speed", SPEED_MODIFIER_SPRINTING, 0.3,
					"add_multiplied_total")
		self:add_physics_factor ("fov_factor", FOV_MODIFIER_SPRINTING, 0.10, "add")
	else
		self._sprinting = false
		self:remove_physics_factor ("movement_speed", SPEED_MODIFIER_SPRINTING)
		self:remove_physics_factor ("fov_factor", FOV_MODIFIER_SPRINTING)
	end
end

function localplayer:set_fall_flying (fall_flying)
	if self.fall_flying then
		if not fall_flying then
			self.fall_flying = false
			self.rocket_ticks = 0
		end
	elseif fall_flying then
		self.fall_flying = true
		self.rocket_ticks = 0
	end
end

function localplayer:collision_angle ()
	local v = self.localplayer:get_velocity ()
	local yaw = self.last_yaw
	local forward = vector.new (-math.sin (yaw), 0, math.cos (yaw))
	v.y = 0
	v = vector.normalize (v)
	return math.acos (vector.dot (v, forward))
end

local EIGHT_DEG = math.rad (8)

function localplayer:send_movement_state ()
	profile ("LocalPlayer send_movement_state")
	local state = self.server_movement_state
	local in_water = self._immersion_depth > 0 and self.liquidtype == "water"
	if state.in_water ~= in_water
		or self._sprinting ~= state.is_sprinting
		or self.fall_flying ~= state.is_fall_flying
		or self.swimming ~= state.is_swimming then
		state.is_sprinting = self._sprinting
		state.in_water = in_water
		state.is_fall_flying = self.fall_flying
		state.is_swimming = self.swimming
		mcl_localplayer.send_movement_state (state)
	end
	profile_done ("LocalPlayer send_movement_state")
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

function localplayer:toggle_step_height (enable_step_height)
	profile ("LocalPlayer toggle_step_height")
	if enable_step_height and self._previously_floating then
		self._previously_floating = false
		self.object:clear_property_overrides ({"stepheight"})
	elseif not enable_step_height and not self._previously_floating then
		self._previously_floating = true
		self.object:set_property_overrides ({stepheight = 0.0})
	end
	profile_done ("LocalPlayer toggle_step_height")
end

function localplayer:test_collision (self_pos, moveresult, v)
	profile ("LocalPlayer test_collision")
	if not self.horiz_collision then
		local old, new
		self.horiz_collision, old, new = horiz_collision (moveresult)
		self.minor_collision = self._sprinting
			and self.horiz_collision
			and self:collision_angle () < EIGHT_DEG

		-- Apply "kinetic damage" when the player collides
		-- with a wall while fall flying.
		if self.fall_flying and self.horiz_collision then
			if old and new then
				local diff = math.abs (vector.length (old) - vector.length (new))
				if diff >= 6.0 and self.damage_immune == 0 then
					mcl_localplayer.send_damage ({
						type = "kinetic",
						amount = diff * 0.5,
					})
					self.damage_immune = 10
				end
			end
		end
	end
	if not self.touching_ground then
		if moveresult.touching_ground then
			self.touching_ground, self.ground_standon
				= get_y_axis_collisions (self_pos, moveresult)
		end
	end

	-- Enable or disable stepheight according as this mob is
	-- colliding with the ground.
	self:toggle_step_height (not not self.touching_ground)
	profile_done ("LocalPlayer test_collision")
end

function localplayer:post_motion_step (v, self_pos, control, params)
	-- Descend in water or descend or ascend when flying.
	if self.liquidtype == "water" and control.sneak then
		v.y = v.y + WATER_DESCENT
	elseif params.flying then
		local dir = 0.0
		if control.sneak then
			dir = dir + -1.0
		end
		if control.jump then
			dir = dir + 1.0
		end
		v.y = v.y + dir * self:get_flying_speed (params) * 3.0
	end

	local made_contact = self.touching_ground
	self._last_standon = self.standon
	self._last_standin = self.standin
	self._last_liquidtype = self.liquidtype
	self:check_fall_damage (self_pos, made_contact, params)
	self._was_touching_ground = self.touching_ground
end

core.register_on_teleport_localplayer (function (new_pos)
	localplayer.fall_distance = 0
	localplayer.last_fall_y = nil

	-- Minetest specifies yaw and pitch alongside position whilst
	-- teleporting players.
	localplayer.yaw_offset = 0
	localplayer.pitch_offset = 0
	if mcl_localplayer.debug then
		print ("Teleported to: " .. new_pos:to_string ())
	end
end)

function localplayer:is_underwater ()
	local depth = self.swimming and 0.5 or 1.75
	return self._immersion_depth >= depth
end

function localplayer:set_swimming (swimming)
	self.swimming = swimming
end

local function touching_only_ignore (collisions)
	for _, node_pos in pairs (collisions) do
		if core.get_node_or_nil (node_pos) then
			return false
		end
	end
	return true
end

mcl_localplayer.touching_only_ignore = touching_only_ignore

function localplayer:check_fall_damage (self_pos, touching_ground, params)
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
					print (string.format ("Detected fall of %.4f nodes", distance))
				end
				mcl_localplayer.send_damage ({
					type = "fall",
					amount = distance - self.safe_fall_distance,
					damage_pos = self_pos,
					collisions = self.touching_ground,
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

local function norm_radians (x)
	return (x + math.pi) % (math.pi * 2) - math.pi
end

mcl_localplayer.norm_radians = norm_radians

function localplayer.on_step (dtime, moveresult, params)
	local player = core.localplayer
	local self = localplayer
	local control = player:get_control ()
	local self_pos = self.localplayer:get_pos ()
	profile ("on_step")

	if not moveresult then
		moveresult = {
			touching_ground = false,
			collides = false,
			standing_on_object = false,
			collisions = { },
		}
	end

	profile ("LocalPlayer camera control")
	-- Set camera yaw and pitch.
	local cam_yaw = control.yaw + self.yaw_offset
	local cam_pitch = control.pitch + self.pitch_offset

	-- Apply yaw lock if necessary.
	if self.yaw_locked then
		mcl_localplayer.orient_camera_on_boat (dtime)
		local dist = norm_radians (cam_yaw) - self.yaw_locked
		local norm = norm_radians (dist)
		local diff = 0.0
		if norm > math.pi / 2 then
			diff = math.pi / 2 - norm
		elseif norm < -math.pi / 2 then
			diff = -math.pi / 2 - norm
		end
		self.yaw_offset	= self.yaw_offset + diff
		cam_yaw = cam_yaw + diff
	end

	core.camera:set_look_horizontal (cam_yaw)
	core.camera:set_look_vertical (cam_pitch)
	self.last_yaw = cam_yaw
	profile_done ("LocalPlayer camera control")

	-- Am I mounted?
	profile ("LocalPlayer mounting tests")
	local mount = self.object:get_attach ()
	mcl_localplayer.update_mounting (mount)
	if mount then
		self._immersion_depth = 0
		self.liquidtype = nil
		self.fall_distance = 0.0
		self.last_fall_y = nil
		self.localplayer:set_touching_ground (nil)
		self:set_sprinting (false)
		self:set_swimming (false)
		self:set_fall_flying (false)
		-- Send physics state to server.
		self:send_movement_state ()

		-- Configure a suitable pose.
		local pose = self.mount_pose
		if pose ~= self.pose then
			self:apply_pose (pose)
		end
		self:tick_animation (control, dtime)
		profile_done ("LocalPlayer mounting tests")
		return
	end
	profile_done ("LocalPlayer mounting tests")

	profile ("Localplayer supporting node computation")
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
	profile_done ("Localplayer supporting node computation")

	-- Test movement info for collisions unless it would be
	-- reverted anyway.
	local switchtime = self.default_switchtime
	local t = switchtime + dtime
	if t < ONE_TICK then
		self:test_collision (self_pos, moveresult)
	end

	-- Extract supporting nodes from the moveresult if possible.
	if self.ground_standon then
		self.standon = self.ground_standon
	end
	if self.standon then
		core.localplayer:set_supporting_node (self.standon.pos)
	end

	-- Compute fluid immersion.
	local immersion_depth, liquidtype
		= self:check_standin (self_pos, params)
	self._immersion_depth = immersion_depth
	self.liquidtype = liquidtype

	profile ("LocalPlayer pose control")
	-- Begin sprinting if possible.
	if self:may_sprint (control) and control.aux1
		and (not control.sneak or params.flying)
		and (self._immersion_depth <= 0 or self:is_underwater ())
		and (not self.horiz_collision or self.minor_collision or self.swimming) then
		if not self._sprinting then
			self:set_sprinting (true)
		end
	elseif self._sprinting then
		self:set_sprinting (false)
	end

	-- Maybe trigger swimming and fall flying.
	self:set_swimming (self._sprinting and self:is_underwater ())
	if not self.fall_flying and control.jump and not self._was_jumping
		and not params.flying and not self.touching_ground
		and self._immersion_depth == 0 then
		local def = self.standon and core.get_node_def (self.standon.name)
		if not def or not def.climbable then
			self:set_fall_flying (true)
		end
	end
	if self.fall_flying and (params.flying
					or self.touching_ground
					or not self.can_fall_fly
					or mcl_localplayer.has_effect ("levitation")) then
		self:set_fall_flying (false)
	end
	profile_done ("LocalPlayer pose control")

	-- Send physics state to server.
	self:send_movement_state ()

	-- Set jumping flag.
	self.jumping = control.jump

	-- Apply acceleration.
	-- Slow down players using shields or bows.
	local base = self.blocking ~= 0 and 0.2 or 1.0
	local moving_slowly = self.pose == POSE_CROUCHING
		or (self.pose == POSE_SWIMMING
		    and self._immersion_depth <= 0)
		or mcl_localplayer.is_using_bow ()
		or mcl_localplayer.is_using_food ()

	if moving_slowly then
		local factor = math.min (PLAYER_CROUCH_FACTOR + self.sneak_speed_bonus, 1.0)
		self.acc_dir.z = control.movement_y * factor * base
		self.acc_dir.x = control.movement_x * factor * base
	else
		self.acc_dir.z = control.movement_y * base
		self.acc_dir.x = control.movement_x * base
	end

	profile ("LocalPlayer pose application")
	-- Configure a suitable pose.
	local pose = self:desired_pose (self_pos, control, params)
	if pose ~= self.pose then
		self:apply_pose (pose)
	end
	profile_done ("LocalPlayer pose application")
	self:tick_animation (control, dtime)

	----------------------------------------------------------------
	-- Physics section of globalstep.  The lifespan of the
	-- localplayer is divided into steps at intervals of ONE_TICK,
	-- and motion_step and the like are called whenever every such
	-- interval elapses in order to adjust the velocity and apply
	-- entity physics.
	----------------------------------------------------------------

	if t >= ONE_TICK then
		profile ("LocalPlayer physics")
		-- Apply that portion of the globalstep which elapsed
		-- before this globalstep.
		local adj_pos = params.old_position
		local v = params.old_velocity
		local before = ONE_TICK - switchtime % ONE_TICK

		if params.flying and params.noclip then
			adj_pos.x = adj_pos.x + v.x * before
			adj_pos.y = adj_pos.y + v.y * before
			adj_pos.z = adj_pos.z + v.z * before
		else
			profile ("LocalPlayer collision_move")
			adj_pos, v, moveresult
				= self.localplayer:collision_move (adj_pos, v, before)
			self:test_collision (adj_pos, moveresult, v)
			profile_done ("LocalPlayer collision_move")
		end

		-- Run the physics simulation.
		profile ("LocalPlayer physics simulation")
		local phys_start = switchtime + before
		while phys_start <= t do
			local time = math.min (ONE_TICK, t - phys_start)
			local stuck_in = self._stuck_in
			if stuck_in then
				v = vector.zero ()
				self._stuck_in = nil
			end
			self.localplayer:set_touching_ground (self.touching_ground)
			v = self:motion_step (v, adj_pos, moveresult, control, params)
			self:post_motion_step (v, adj_pos, control, params)

			-- Clear collision detection flags.  They will
			-- be set as collisions are detected over the
			-- span of the next globalstep.
			self.horiz_collision = false
			self.touching_ground = false
			self.ground_standon = nil

			-- Implement crouching by refusing to move
			-- forward if doing so would result in a fall
			-- after one tick.
			if control.sneak and not params.flying and self._was_touching_ground then
				self:crouch_reduce_velocity (v, self_pos)
			end
			if stuck_in then
				v.x = v.x * stuck_in.x
				v.y = v.y * stuck_in.y
				v.z = v.z * stuck_in.z
			end
			if params.flying and params.noclip then
				adj_pos.x = adj_pos.x + v.x * time
				adj_pos.y = adj_pos.y + v.y * time
				adj_pos.z = adj_pos.z + v.z * time
			else
				profile ("LocalPlayer collision_move")
				adj_pos, v, moveresult
					= self.localplayer:collision_move (adj_pos, v, time)
				self:test_collision (adj_pos, moveresult, v)
				profile_done ("LocalPlayer collision_move")
			end
			phys_start = phys_start + ONE_TICK
		end
		profile_done ("LocalPlayer physics simulation")
		self.localplayer:set_pos (adj_pos)
		self.localplayer:set_velocity (v)
		self.default_switchtime = t % ONE_TICK
		profile_done ("LocalPlayer physics")
	else
		self.default_switchtime = t
	end
	self._was_jumping = control.jump
	local root = profile_done ("on_step")
	mcl_localplayer.profiler_collect (root, dtime)
end

function mcl_localplayer.add_cam_offsets (y, x)
	if y ~= 0 or x ~= 0 then
		local yaw = localplayer.yaw_offset + y
		local pitch = localplayer.pitch_offset + x
		localplayer.yaw_offset = yaw
		localplayer.pitch_offset = pitch
	end
end

function mcl_localplayer.lock_yaw (cam_yaw)
	localplayer.yaw_locked = norm_radians (cam_yaw)
end

function mcl_localplayer.unlock_yaw ()
	localplayer.yaw_locked = nil
end

function mcl_localplayer.handle_knockback (v)
	if not localplayer.touching_ground then
		v.y = 0
	end
	localplayer.localplayer:set_velocity (v)
end

function mcl_localplayer.init_player ()
	core.localplayer:set_player_callbacks (localplayer)
	localplayer.localplayer = core.localplayer
	localplayer.object = core.localplayer:get_object ()
	mcl_localplayer.send_playerpose (POSE_STANDING)
end

------------------------------------------------------------------------
-- Poses.
------------------------------------------------------------------------


-- Pose definition format.
-- {
--	poseid = {
--		stand = {x = 0, y = 0,},
--		walk = {x = 0, y = 0,},
--		mine = {x = 0, y = 0,},
--		walk_mine = {x = 0, y = 0,},
--		collisionbox = aabb3f,
--		eye_height = eye_height,
--	},
-- }
--
-- All defined poses are expected to be in such a table.

local function validate_pose_table (pose)
	if type (pose.stand) ~= "table"
		or type (pose.stand.x) ~= "number"
		or type (pose.stand.y) ~= "number" then
		error ("Invalid stand pose")
	end
	if type (pose.walk) ~= "table"
		or type (pose.walk.x) ~= "number"
		or type (pose.walk.y) ~= "number" then
		error ("Invalid walk pose")
	end
	if type (pose.mine) ~= "table"
		or type (pose.mine.x) ~= "number"
		or type (pose.mine.y) ~= "number" then
		error ("Invalid mine pose")
	end
	if type (pose.walk_bow) ~= "table"
		or type (pose.walk_bow.x) ~= "number"
		or type (pose.walk_bow.y) ~= "number" then
		error ("Invalid walk_mine pose")
	end
	if type (pose.walk_mine) ~= "table"
		or type (pose.walk_mine.x) ~= "number"
		or type (pose.walk_mine.y) ~= "number" then
		error ("Invalid walk_mine pose")
	end
	if type (pose.collisionbox) ~= "table"
		or type (pose.collisionbox[1]) ~= "number"
		or type (pose.collisionbox[2]) ~= "number"
		or type (pose.collisionbox[3]) ~= "number"
		or type (pose.collisionbox[4]) ~= "number"
		or type (pose.collisionbox[5]) ~= "number"
		or type (pose.collisionbox[6]) ~= "number" then
		error ("Invalid pose collisionbox")
	end
	if type (pose.eye_height) ~= "number" then
		error ("Invalid pose eye height")
	end
end

function mcl_localplayer.process_clientbound_player_capabilities (payload)
	-- PAYLOAD is a json table containing player physics metadata
	-- or pose information.
	local data = core.parse_json (payload)
	if type (data) ~= "table" then
		error ("Malformed ClientboundPlayerCapabilities")
	end

	if data.pose_defs then
		for id, pose in pairs (data.pose_defs) do
			if type (id) ~= "number" then
				error ("Invalid pose id in ClientboundPlayerCapabilities")
			end
			if type (pose) ~= "table" then
				error ("Invalid pose table in ClientboundPlayerCapabilities")
			end
			validate_pose_table (pose)
		end

		if not data.pose_defs[POSE_STANDING] then
			error ("Server did not define POSE_STANDING")
		end
		if not data.pose_defs[POSE_CROUCHING] then
			error ("Server did not define POSE_CROUCHING")
		end
		if not data.pose_defs[POSE_SLEEPING] then
			error ("Server did not define POSE_SLEEPING")
		end
		if not data.pose_defs[POSE_FALL_FLYING] then
			error ("Server did not define POSE_FALL_FLYING")
		end
		if not data.pose_defs[POSE_DEATH] then
			error ("Server did not define POSE_DEATH")
		end
		if not data.pose_defs[POSE_MOUNTED] then
			error ("Server did not define POSE_MOUNTED")
		end
		if not data.pose_defs[POSE_SIT_MOUNTED] then
			error ("Server did not define POSE_SIT_MOUNTED")
		end
		mcl_localplayer.pose_defs = data.pose_defs
		localplayer:apply_pose (localplayer.pose)
	end
	if data.movement_arresting_nodes then
		if type (data.movement_arresting_nodes) ~= "table" then
			error ("Invalid node movement table")
		end
		for node, vector in pairs (data.movement_arresting_nodes) do
			if type (node) ~= "string" then
				error ("Invalid node ID in node movement table")
			end
			data.movement_arresting_nodes[node] = vector
		end
		localplayer.movement_arresting_nodes = data.movement_arresting_nodes
	end
	if data.gamemode ~= nil then
		if data.gamemode ~= "survival" and data.gamemode ~= "creative" then
			error ("Unknown gamemode `" .. data.gamemode .. "'")
		end
		localplayer.gamemode = data.gamemode
	end
	if data.can_sprint ~= nil then
		localplayer.can_sprint = (not not data.can_sprint)
	end
	if data.can_fall_fly ~= nil then
		localplayer.can_fall_fly = (not not data.can_fall_fly)
	end
	if data.depth_strider_level ~= nil then
		if type (data.depth_strider_level) ~= "number" then
			error ("Invalid enchantment data")
		end
		localplayer.depth_strider_level = data.depth_strider_level
	end
end

function localplayer:pose_collides (self_pos, pose)
	profile ("LocalPlayer pose_collides")
	local def = mcl_localplayer.pose_defs[pose]
	local rc = def and core.collides (def.collisionbox, self_pos,
					true, self.object, true)
	profile_done ("LocalPlayer pose_collides")
	return rc
end

function localplayer:collides (self_pos, off_x, off_y, off_z, reject_grazing)
	profile ("LocalPlayer collision detection")
	local test_pos = vector.offset (self_pos, off_x, off_y, off_z)
	local rc = core.collides (self.collisionbox, test_pos,
				true, self.object, reject_grazing)
	profile_done ("LocalPlayer collision detection")
	return rc
end

function localplayer:desired_pose (self_pos, controls, params)
	local pose
	if self.overriding_pose then
		return self.overriding_pose
	elseif self.localplayer:get_hp () == 0 then
		return POSE_DEATH
	elseif self.fall_flying then
		pose = POSE_FALL_FLYING
	elseif self.swimming then
		pose = POSE_SWIMMING
	elseif controls.sneak and not params.flying then
		pose = POSE_CROUCHING
	else
		pose = POSE_STANDING
	end

	-- Guarantee that the player will fit in the selected pose.
	local pose_def = mcl_localplayer.pose_defs[pose]
	if not pose_def or (params.flying and params.noclip) then
		return pose
	else
		if self:pose_collides (self_pos, pose) then
			if not self:pose_collides (self_pos, POSE_CROUCHING) then
				return POSE_CROUCHING
			elseif not self:pose_collides (self_pos, POSE_SWIMMING) then
				return POSE_SWIMMING
			end
		end
		return pose
	end
end

function localplayer:apply_pose (pose)
	profile ("LocalPlayer apply_pose")
	local posedef = mcl_localplayer.pose_defs[pose]
	if posedef then
		self.object:set_property_overrides ({
			collisionbox = posedef.collisionbox,
			eye_height = posedef.current_eye_height,
		})
		self.collisionbox = posedef.collisionbox

		self:set_physics_factor_base ("target_eye_height",
					posedef.eye_height)
		self.object:set_animation (posedef[self.animation], 0.25)
	end
	mcl_localplayer.send_playerpose (pose)
	self.pose = pose
	profile_done ("LocalPlayer apply_pose")
end

local DEFAULT_ANIMATION_SPEED = 30

function localplayer:desired_animation (controls, v)
	local speed = DEFAULT_ANIMATION_SPEED
	if self.pose == POSE_CROUCHING or self.blocking ~= 0 then
		speed = speed / 2
	end
	if math.abs (v.x) > 0.35 or math.abs (v.z) > 0.35 then
		local is_using_bow = mcl_localplayer.is_using_bow_visually ()
		if is_using_bow then
			return "walk_bow", speed
		elseif controls.dig then
			return "walk_mine", speed
		else
			return "walk", speed
		end
	elseif controls.dig then
		return "mine", speed
	else
		return "stand", speed
	end
end

local FOURTY_DEG = math.rad (40)
local TWENTY_DEG = math.rad (20)
local SEVENTY_FIVE_DEG = math.rad (75)
local FIFTY_DEG = math.rad (50)
local ONE_HUNDRED_AND_TEN_DEG = math.rad (110)

local function dir_to_pitch (dir)
	local xz = math.abs (dir.x) + math.abs (dir.z)
	return -math.atan2 (-dir.y, xz)
end

local RIGHT_ARM_BLOCKING_OVERRIDE = vector.new (-160, -20, 0):apply (math.rad)
local LEFT_ARM_BLOCKING_OVERRIDE = vector.new (-160, 20, 0):apply (math.rad)

local OVERRIDE_TEMPLATE = {
	rotation = {
		vec = vector.zero (),
		absolute = true,
	},
}

local DEFAULT_FOV = 86.1

function localplayer:rotate_non_redundantly (bone, rot_x, rot_y, rot_z)
	local existing = self._bone_overrides[bone]
	if existing
		and existing.x == rot_x
		and existing.y == rot_y
		and existing.z == rot_z then
		return
	end

	profile ("LocalPlayer set_bone_override")
	local v = OVERRIDE_TEMPLATE.rotation.vec
	v.x = rot_x
	v.y = rot_y
	v.z = rot_z
	self.object:set_bone_override (bone, OVERRIDE_TEMPLATE)
	if existing then
		existing.x = rot_x
		existing.y = rot_y
		existing.z = rot_z
	else
		self._bone_overrides[bone] = vector.copy (v)
	end
	profile_done ("LocalPlayer set_bone_override")
end

local NOTHING = {}

function localplayer:unrotate (bone)
	local existing = self._bone_overrides[bone]
	if existing then
		profile ("LocalPlayer set_bone_override")
		self.object:set_bone_override (bone, NOTHING)
		self._bone_overrides[bone] = nil
		profile_done ("LocalPlayer set_bone_override")
	end
end

function localplayer:tick_animation (controls, dtime)
	profile ("LocalPlayer tick_animation")
	local base = self.current_eye_height
	local target = self.target_eye_height
	local v = self.localplayer:get_velocity ()

	profile ("LocalPlayer animate eye height")
	if base ~= target then
		local t = math.min (self.eye_height_time + dtime, 0.20)
		local v = vector.new (0, base + (target - base) * (t / 0.20), 0)
		core.camera:set_offset (v)

		if t >= 0.20 then
			self.current_eye_height = target
		end
		self.eye_height_time = t
	end
	profile_done ("LocalPlayer animate eye height")

	profile ("LocalPlayer configure animation")
	local anim, speed = self:desired_animation (controls, v)
	if anim ~= self.animation then
		local posedef = mcl_localplayer.pose_defs[self.pose]
		self.animation = anim
		if posedef then
			self.object:set_animation (posedef[anim], 0.25)
			mcl_localplayer.send_playeranim (anim)
		end
	end
	if speed ~= self.animation_speed then
		self.object:set_animation_frame_speed (speed)
		self.animation_speed = speed
	end
	profile_done ("LocalPlayer configure animation")

	profile ("LocalPlayer animate FOV")
	-- Animate FOV.
	if self.fov_factor ~= self.noticed_fov_factor then
		local fov = DEFAULT_FOV * self.fov_factor
		self.localplayer:set_fov (fov, false, 0.20)
		self.noticed_fov_factor = self.fov_factor
	end
	profile_done ("LocalPlayer animate FOV")

	-- Animate body.
	profile ("LocalPlayer animate prologue")
	local look_dir = self.last_yaw
	local v = vector.normalize (v)
	local move_yaw = (math.abs (v.z) < 0.35 and math.abs (v.x) < 0.35)
		and self._last_move_yaw or math.atan2 (v.z, v.x) - math.pi / 2
	profile_done ("LocalPlayer animate prologue")

	if self.pose == POSE_SWIMMING then
		profile ("LocalPlayer animate POSE_SWIMMING")
		local pitch = core.camera:get_look_vertical ()
		local move_pitch = dir_to_pitch (v)
		local norm_look_dir = norm_radians (look_dir)
		self:rotate_non_redundantly ("Head_Control",
			(pitch - move_pitch) + TWENTY_DEG,
			move_yaw - norm_look_dir, 0)
		local x = SEVENTY_FIVE_DEG + move_pitch
		local y = move_yaw - norm_look_dir
		local z = math.pi
		self:rotate_non_redundantly ("Body_Control", x, y, z)
		self._last_move_yaw = move_yaw
		profile_done ("LocalPlayer animate POSE_SWIMMING")
		profile_done ("LocalPlayer tick_animation")
		return
	elseif self.pose == POSE_FALL_FLYING then
		profile ("LocalPlayer animate POSE_FALL_FLYING")
		local move_pitch = dir_to_pitch (v)
		local xrot = move_pitch + FIFTY_DEG
		local yrot = move_yaw - look_dir
		self:rotate_non_redundantly ("Head_Control", xrot, yrot, 0)
		local xrot = move_pitch + ONE_HUNDRED_AND_TEN_DEG
		local yrot = -move_yaw + norm_radians (look_dir)
		self:rotate_non_redundantly ("Body_Control", xrot, yrot, math.pi)
		self._last_move_yaw = move_yaw
		profile_done ("LocalPlayer animate POSE_FALL_FLYING")
		profile_done ("LocalPlayer tick_animation")
		return
	elseif self.pose == POSE_SLEEPING then
		profile ("LocalPlayer animate POSE_SLEEPING")
		self:unrotate ("Head_Control")
		self:rotate_non_redundantly ("Body_Control", 0, math.pi, 0)
		profile_done ("LocalPlayer animate POSE_SLEEPING")
		profile_done ("LocalPlayer tick_animation")
		return
	elseif self.pose == POSE_DEATH then
		profile ("LocalPlayer animate POSE_DEATH")
		self:unrotate ("Head_Control")
		self:unrotate ("Body_Control")
		profile_done ("LocalPlayer animate POSE_DEATH")
		profile_done ("LocalPlayer tick_animation")
		return
	end

	profile ("LocalPlayer animate default pose")
	local move_yaw_lim = norm_radians (move_yaw)
	local look_dir_new = norm_radians (look_dir)
	local diff = norm_radians (move_yaw_lim - look_dir_new)

	if self.pose == self.mount_pose then
		profile ("LocalPlayer animate mount")
		local attach = self.object:get_attach ()
		if attach then
			local yaw = attach:get_yaw ()
			local yrot = -norm_radians (look_dir - norm_radians (yaw))
			local pitch = core.camera:get_look_vertical ()
			self:rotate_non_redundantly ("Body_Control", 0, math.pi, 0)
			self:rotate_non_redundantly ("Head_Control", pitch, yrot, 0)
		end
		profile_done ("LocalPlayer animate mount")
	else
		if diff > FOURTY_DEG then
			move_yaw_lim = look_dir_new + FOURTY_DEG
		elseif diff < -FOURTY_DEG then
			move_yaw_lim = look_dir_new - FOURTY_DEG
		end
		self._last_move_yaw = move_yaw_lim
		local body = look_dir_new - move_yaw_lim - math.pi
		self:rotate_non_redundantly ("Body_Control", 0, body, 0)
		local y = move_yaw_lim - look_dir_new
		local x = core.camera:get_look_vertical ()
		self:rotate_non_redundantly ("Head_Control", x, y, 0)
	end

	profile_done ("LocalPlayer animate default pose")
	profile ("LocalPlayer animate arm rotation")

	-- Control arm rotation whilst blocking.
	if self.blocking == 2 then
		self:rotate_non_redundantly ("Arm_Right", 0, 0, 0)
		self:unrotate ("Arm_Left")
		self:rotate_non_redundantly ("Arm_Right_Pitch_Control",
					RIGHT_ARM_BLOCKING_OVERRIDE.x,
					RIGHT_ARM_BLOCKING_OVERRIDE.y,
					RIGHT_ARM_BLOCKING_OVERRIDE.z)
		self:unrotate ("Arm_Left_Pitch_Control")
	elseif self.blocking == 1 then
		self:unrotate ("Arm_Right")
		self:rotate_non_redundantly ("Arm_Left", 0, 0, 0)
		self:unrotate ("Arm_Right_Pitch_Control")
		self:rotate_non_redundantly ("Arm_Left_Pitch_Control",
					LEFT_ARM_BLOCKING_OVERRIDE.x,
					LEFT_ARM_BLOCKING_OVERRIDE.y,
					LEFT_ARM_BLOCKING_OVERRIDE.z)
	elseif mcl_localplayer.is_using_bow_visually () then
		self:rotate_non_redundantly ("Arm_Right", 0, 0, 0)
		self:rotate_non_redundantly ("Arm_Left", 0, 0, 0)
		local pitch = math.deg (core.camera:get_look_vertical ())
		local right_arm_rot
			= vector.new (pitch + 90 - 180, -30, pitch * -1 * .35):apply (math.rad)
		local left_arm_rot
			= vector.new (pitch + 90 - 180, 43, pitch * 0.35):apply (math.rad)
		self:rotate_non_redundantly ("Arm_Right_Pitch_Control", right_arm_rot.x,
					right_arm_rot.y,
					right_arm_rot.z)
		self:rotate_non_redundantly ("Arm_Left_Pitch_Control", left_arm_rot.x,
					left_arm_rot.y,
					left_arm_rot.z)
	else
		self:unrotate ("Arm_Right")
		self:unrotate ("Arm_Left")
		self:rotate_non_redundantly ("Arm_Right_Pitch_Control", math.pi, 0, 0)
		self:rotate_non_redundantly ("Arm_Left_Pitch_Control", math.pi, 0, 0)
	end
	profile_done ("LocalPlayer animate arm rotation")
	profile_done ("LocalPlayer tick_animation")
end

function mcl_localplayer.do_posectrl (ctrlword)
	assert (not ctrlword or (ctrlword >= POSE_STANDING
					and ctrlword <= POSE_DEATH))
	localplayer.overriding_pose = ctrlword
end

function mcl_localplayer.do_shieldctrl (ctrlword)
	if mcl_localplayer.proto >= 1 then
		error ("Did not expect server to dictate shield activation state")
	end
	localplayer.blocking = ctrlword
end

function mcl_localplayer.set_mount_pose (poseid)
	localplayer.mount_pose = poseid
end

------------------------------------------------------------------------
-- Player physics factors.
------------------------------------------------------------------------

function localplayer:validate_attribute (field, value)
	if field == "fov_factor" then
		return math.max (math.min (value, 3.0), 0.2)
	end
	return value
end

function localplayer:post_apply_physics_factor (field, oldvalue, value)
	if field == "target_eye_height" then
		if oldvalue == value then
			return
		end

		if self.current_eye_height == -1 then
			self.current_eye_height = value
			local v = vector.new (0, value, 0)
			core.camera:set_offset (v)
		else
			local v = core.camera:get_offset ()
			self.current_eye_height = v.y
		end
		self.eye_height_time = 0.0
	end
end

local function apply_physics_factors (self, field)
	local base = self._physics_factors[field].base or self[field]
	local total = base
	local to_add = {}
	local to_add_multiply_base = {}
	local to_multiply_total = {}
	for name, value in pairs (self._physics_factors[field]) do
		if name ~= "base" then
			if value.op == "scale_by" then
				table.insert (to_multiply_total, value.amount)
			elseif value.op == "add_multiplied_base" then
				table.insert (to_add_multiply_base, value.amount)
			elseif value.op == "add_multiplied_total" then
				table.insert (to_multiply_total, 1.0 + value.amount)
			elseif value.op == "add" then
				table.insert (to_add, value.amount)
			end
		end
	end
	for _, value in ipairs (to_add) do
		total = total + value
	end
	base = total
	for _, value in ipairs (to_add_multiply_base) do
		total = total + base * value
	end
	for _, value in ipairs (to_multiply_total) do
		total = total * value
	end
	local oldvalue = self[field]
	self[field] = self:validate_attribute (field, total)
	self:post_apply_physics_factor (field, oldvalue, total)
end

function localplayer:set_physics_factor_base (field, base)
	if not self._physics_factors[field] then
		self._physics_factors[field] = { base = base, }
	else
		self._physics_factors[field].base = base
	end
	apply_physics_factors (self, field)
end

function localplayer:add_physics_factor (field, id, factor, op, add_to_existing)
	if not self._physics_factors[field] then
		self._physics_factors[field] = { base = self[field], }
	else
		-- Do not apply physics factors redundantly.
		local old = self._physics_factors[field][id]
		if old then
			if add_to_existing then
				old.amount = old.amount + factor
				old.op = op
				apply_physics_factors (self, field)
				return
			elseif old.amount == factor and old.op == op then
				return
			end
		end
	end
	self._physics_factors[field][id] = {
		amount = factor,
		op = op or "scale_by",
	}
	apply_physics_factors (self, field)
end

function localplayer:remove_physics_factor (field, id)
	if not self._physics_factors[field]
		or not self._physics_factors[field][id] then
		return
	end
	self._physics_factors[field][id] = nil
	apply_physics_factors (self, field)
end

function localplayer:stock_value (field)
	if not self._physics_factors[field] then
		return self[field]
	end
	return self._physics_factors[field].base
end

function mcl_localplayer.register_attribute_modifier (modifier)
	local op = modifier.op
	if op == "add" or op == "add_multiplied_total"
		or op == "add_multiplied_base" or op == "scale_by" then
		local old_value = localplayer[modifier.field]
		localplayer:add_physics_factor (modifier.field, modifier.id,
						modifier.value, modifier.op)
		if mcl_localplayer.debug then
			print (string.format ("  %s: %.4f -> %.4f", modifier.field,
					old_value, localplayer[modifier.field]))
		end
	else
		error ("Invalid attribute modifier operation: " .. op)
	end
end

function mcl_localplayer.remove_attribute_modifier (modifier)
	localplayer:remove_physics_factor (modifier.field, modifier.id)
end

function mcl_localplayer.add_fov_factor (id, factor)
	localplayer:add_physics_factor ("fov_factor", id, factor, "add")
end

function mcl_localplayer.clear_fov_factor (id)
	localplayer:remove_physics_factor ("fov_factor", id)
end

------------------------------------------------------------------------
-- Player status effects.
------------------------------------------------------------------------

local FOV_MODIFIER_SWIFTNESS = "mcl_localplayer:swiftness_fov_modifier"
local FOV_MODIFIER_SLOWNESS = "mcl_localplayer:slowness_fov_modifier"

function localplayer:apply_effect (effect)
	if effect.name == "swiftness" then
		localplayer:add_physics_factor ("fov_factor", FOV_MODIFIER_SWIFTNESS,
						math.min (0.10 * effect.level, 0.60), "add")
	elseif effect.name == "slowness" then
		localplayer:add_physics_factor ("fov_factor", FOV_MODIFIER_SLOWNESS,
						math.max (-0.05 * effect.level, -0.10), "add")
	end
end

function localplayer:remove_effect (id, effect)
	if id == "swiftness" then
		localplayer:remove_physics_factor ("fov_factor", FOV_MODIFIER_SWIFTNESS)
	elseif id == "slowness" then
		localplayer:remove_physics_factor ("fov_factor", FOV_MODIFIER_SLOWNESS)
	end
end

local EF = {}

function mcl_localplayer.add_status_effect (effect)
	EF[effect.name] = effect
	localplayer:apply_effect (effect)
end

function mcl_localplayer.remove_status_effect (id)
	if EF[id] then
		localplayer:remove_effect (id, EF[id])
		EF[id] = nil
	end
end

function mcl_localplayer.get_status_effect (id)
	return EF[id]
end

function mcl_localplayer.get_effect_level (id)
	return EF[id] and EF[id].level or 0.0
end

function mcl_localplayer.has_effect (id)
	return EF[id] ~= nil
end

------------------------------------------------------------------------
-- Game modes.
------------------------------------------------------------------------

function mcl_localplayer.is_creative_enabled ()
	return localplayer.gamemode == "creative"
end

------------------------------------------------------------------------
-- Player vitals.
------------------------------------------------------------------------

function mcl_localplayer.handle_player_vitals (payload)
	assert (type (payload.hp) == "number")
	assert (type (payload.hunger) == "number")
	assert (type (payload.saturation) == "number")

	localplayer.health = payload.hp
	localplayer.hunger = payload.hunger
	localplayer.saturation = payload.saturation
end

function mcl_localplayer.get_player_vitals ()
	return localplayer.health, localplayer.hunger, localplayer.saturation
end
