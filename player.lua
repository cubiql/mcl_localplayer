------------------------------------------------------------------------
-- Player physics and input.
--
-- TODO: riding, knockback, jump bonuses, collision detection
------------------------------------------------------------------------

local POSE_STANDING	= 1
local POSE_CROUCHING	= 2
local POSE_SLEEPING	= 3
local POSE_FALL_FLYING	= 4
local POSE_SWIMMING	= 5
local POSE_DEATH	= 6

local STANDARD_FOV_FACTOR = 1.2

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
	water_friction = 0.6,
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
}

local AIR_DRAG			= 0.98
local AIR_FRICTION		= 0.91
local DOLPHIN_GRANTED_FRICTION	= 0.96
local WATER_DRAG		= 0.8
local AQUATIC_WATER_DRAG	= 0.9
local AQUATIC_GRAVITY		= -0.1
local SPRINTING_WATER_DRAG	= 0.9
local JUMPING_LAVA_DRAG		= 0.8
local LAVA_FRICTION		= 0.5
local LAVA_SPEED		= 0.4
local FLYING_LIQUID_SPEED	= 0.4
local FLYING_GROUND_SPEED	= 2.0
local FLYING_AIR_SPEED		= 0.4
local BASE_SLIPPERY		= 0.98
local BASE_FRICTION		= 0.6
local LIQUID_FORCE		= 0.28
local BASE_FRICTION3		= math.pow (0.6, 3)
local FLYING_BASE_FRICTION3	= math.pow (BASE_FRICTION * AIR_FRICTION, 3)
local LIQUID_JUMP_THRESHOLD	= 0.4
local LIQUID_JUMP_FORCE		= 0.8
local LIQUID_JUMP_FORCE_ONESHOT	= 6.0
local LAVA_JUMP_THRESHOLD	= 0.1
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
	local yaw = core.camera:get_look_horizontal ()
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
		local yaw = core.camera:get_look_horizontal ()
		v.x = v.x + math.sin (yaw) * -4.0
		v.z = v.z + math.cos (yaw) * 4.0
	end
	mcl_localplayer.send_movement_event (PLAYER_EVENT_JUMP)
	self.localplayer:set_touching_ground (false)
	return v
end

local function horiz_collision (moveresult)
	for _, item in ipairs (moveresult.collisions) do
		if item.axis == "x" or item.axis == "z" then
			return true, item.old_velocity, item.new_velocity
		end
	end
	return false, nil
end

local function clamp (num, min, max)
	return math.min (max, math.max (num, min))
end

local EMPTY_NODE = {
	name = "ignore",
	groups = {},
}

local function check_one_immersion_depth (node, base_y, pos)
	local def = node and core.get_node_def (node.name) or nil
	if def and def.liquid_type and def.liquid_type ~= "none" then
		local height
		if def.liquid_type == "flowing" then
			height = 0.1 + node.param2 * 0.1
		else
			height = 1.0
		end
		if pos.y + height - 0.5 > base_y then
			return ((pos.y - 0.5) + height - base_y),
				(def.groups.lava and "lava" or "water")
		end
	end
	return 0.0, nil
end

function localplayer:check_water_flow (self_pos)
	local node, nn, def
	node = minetest.get_node_or_nil (self_pos)
	if node then
		nn = node.name
		def = core.get_node_def (nn)
	end
	-- Move item around on flowing liquids
	if def and def.liquid_type == "flowing" then
		-- Get flowing direction (function call from flowlib),
		-- if there's a liquid.  NOTE: According to
		-- Qwertymine, flowlib.quickflow is only reliable for
		-- liquids with a flowing distance of 7.  Luckily,
		-- this is exactly what we need if we only care about
		-- water, which has this flowing distance.
		local vec = miniflowlib.quick_flow (self_pos, node)
		return vec
	end
	return nil
end

function localplayer:check_standin (pos, params)
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


	for y = y0, y1 do
		for x = x0, x1 do
			for z = z0, z1 do
				v.x = x
				v.y = y
				v.z = z
				local node = core.get_node_or_nil (v)
				local depth, liquidtype
					= check_one_immersion_depth (node, pos.y, v)
				immersion_depth = math.max (depth, immersion_depth)
				if liquidtype and worst_type ~= "lava" then
					worst_type = liquidtype
				end
				if node then
					local factors = self.movement_arresting_nodes[node.name]
					if factors then
						self._stuck_in = factors
					end
				end
			end
		end
	end
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

function localplayer:rocket_boost (dir, v)
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
	end
end

function mcl_localplayer.apply_rocket_use (num_secs)
	local ticks = math.ceil (num_secs / ONE_TICK)
	localplayer.rocket_ticks = math.max (localplayer.rocket_ticks, ticks)
end

function localplayer:motion_step (v, self_pos, moveresult, controls, params)
	local acc_dir = self.acc_dir
	local acc_speed = self.movement_speed
	local last_standon = self._last_standon
		and core.get_node_def (self._last_standon.name)
		or EMPTY_NODE
	local standin = self.standin
		and core.get_node_def (self.standin.name)
		or EMPTY_NODE
	local standon = self.standon
		and core.get_node_def (self.standon.name)
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
	local server_def = mcl_localplayer.node_defs[standon.name]

	if server_def and server_def._mcl_velocity_factor then
		velocity_factor = server_def._mcl_velocity_factor
	end
	self.jump_timer = self.jump_timer - 1

	if self.swimming then
		local pitch = core.camera:get_look_vertical ()
		local transition_speed = pitch < -0.2 and 0.085 or 0.06
		v.y = v.y + ((pitch * 20) - v.y) * transition_speed
	end

	if self.fall_flying then
		local dir = core.camera:get_look_dir ()
		self:rocket_boost (dir, v)
	end

	if liquidtype == "water" then
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

		if water_vec and (water_vec.x >= 0
					or water_vec.y >= 0
					or water_vec.z >= 0) then
			v.x = v.x + water_vec.x * LIQUID_FORCE
			v.y = v.y + water_vec.y * LIQUID_FORCE
			v.z = v.z + water_vec.z * LIQUID_FORCE
		end

		-- If colliding horizontally within water, detect
		-- whether the result of this movement is vertically
		-- within 0.6 nodes of a position clear of water and
		-- collisions, and apply a force to this mob so as to
		-- breach the water if so.
		if horiz_collision then
			local diff_tick = v.y * ONE_TICK
			local dx = v.x * ONE_TICK
			local dz = v.z * ONE_TICK
			local will_breach_water
				= self:will_breach_water (self_pos, dx, 0.6, dz, params)
			if will_breach_water then
				v.y = 6.0
			end
		end
	elseif liquidtype == "lava" then
		local speed = LAVA_SPEED
		local r = LAVA_FRICTION
		local fv_x, fv_y, fv_z
			= self:accelerate_relative (acc_dir, speed, speed)
		v.x = v.x * r + fv_x
		v.y = v.y * p
		v.z = v.z * r + fv_z
		v.y = v.y + (gravity / 4.0)
		v.y = v.y + fv_y

		-- If colliding horizontally within lava,
		-- detect whether the result of this movement
		-- is vertically within 0.6 nodes of a
		-- position clear of lava and collisions, and
		-- apply a force to this mob so as to breach
		-- the water if so.
		if horiz_collision then
			local diff_tick = v.y * ONE_TICK
			local dx = v.x * ONE_TICK
			local dz = v.z * ONE_TICK
			local will_breach_lava
				= self:will_breach_water (self_pos, dx, 0.6, dz, params)
			if will_breach_lava then
				v.y = 6.0
			end
		end
	elseif self.fall_flying then
		-- Limit fall_distance to 1.0 if vertical velocity is
		-- less than -0.5 n/tick.
		if v.y > -10.0 and self.fall_distance > 1.0 then
			self.fall_distance = 1.0
		end

		local dir = core.camera:get_look_dir ()
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
			friction = BASE_SLIPPERY
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
	end

	if climbable then
		if v.y < -3.0 then
			v.y = -3.0
		end
		v.x = clamp (v.x, -3.0, 3.0)
		v.z = clamp (v.z, -3.0, 3.0)
		if jumping or horiz_collision then
			v.y = 4.0
			jumping = false
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
	return v
end

function localplayer:check_crouch_axis_x (self_pos, x)
	local vec = vector.copy (self_pos)
	while x ~= 0 and not self:collides (self_pos, x * ONE_TICK, -0.6, 0) do
		if x > 0 then
			x = math.max (0, x - ONE_TICK)
		else
			x = math.max (0, x + ONE_TICK)
		end
	end
	return x
end

function localplayer:check_crouch_axis_z (self_pos, z)
	local vec = vector.copy (self_pos)
	while z ~= 0 and not self:collides (self_pos, 0, -0.6, z * ONE_TICK) do
		if z > 0 then
			z = math.max (0, z - ONE_TICK)
		else
			z = math.max (0, z + ONE_TICK)
		end
	end
	return z
end

function localplayer:check_crouch_axis_both (self_pos, x, z)
	local vec = vector.copy (self_pos)
	while x ~= 0 and not self:collides (self_pos, x * ONE_TICK, -0.6, z * ONE_TICK) do
		if x > 0 then
			x = math.max (0, x - ONE_TICK)
		elseif x < 0 then
			x = math.max (0, x + ONE_TICK)
		end
		if z > 0 then
			z = math.max (0, z - ONE_TICK)
		elseif z < 0 then
			z = math.max (0, z + ONE_TICK)
		end
	end
	return x, z
end

function localplayer:crouch_reduce_velocity (v, self_pos)
	v.x = self:check_crouch_axis_x (self_pos, v.x)
	v.z = self:check_crouch_axis_z (self_pos, v.z)
	v.x, v.z = self:check_crouch_axis_both (self_pos, v.x, v.z)
end

function localplayer:may_sprint (controls)
	return self.can_sprint
	-- TODO: bows, forward impulse tests.
		and controls.movement_y > 0
		and self.pose ~= POSE_FALL_FLYING
end

local SPEED_MODIFIER_SPRINTING = "mcl_localplayer:sprint_modifier"
local FOV_MODIFIER_SPRINTING = "mcl_localplayer:sprint_fov_modifier"

function localplayer:set_sprinting (is_sprinting)
	if is_sprinting then
		self._sprinting = is_sprinting
		self:add_physics_factor ("movement_speed", SPEED_MODIFIER_SPRINTING, 0.3,
					"add_multiplied_total")
		self:add_physics_factor ("fov_factor", FOV_MODIFIER_SPRINTING, 0.15, "add")
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
	local yaw = core.camera:get_look_horizontal ()
	local forward = vector.new (-math.sin (yaw), 0, math.cos (yaw))
	v.y = 0
	v = vector.normalize (v)
	return math.acos (vector.dot (v, forward))
end

local EIGHT_DEG = math.rad (8)
local ZERO_VECTOR = vector.zero ()

function localplayer:send_movement_state ()
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
end

local function get_y_axis_collisions (moveresult)
	local collisions = {}

	for _, item in pairs (moveresult.collisions) do
		if item.type == "node" and item.axis == "y" then
			table.insert (collisions, item.node_pos)
		end
	end
	return collisions
end

function localplayer:test_collision (moveresult, v)
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
			self.touching_ground
				= get_y_axis_collisions (moveresult)
		end
	end
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

		if touching_ground then
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

function localplayer.on_step (dtime, moveresult, params)
	local player = core.localplayer
	local self = localplayer
	local control = player:get_control ()
	local self_pos = self.localplayer:get_pos ()

	if not moveresult then
		moveresult = {
			touching_ground = false,
			collides = false,
			standing_on_object = false,
			collisions = { },
		}
	end

	-- Set camera yaw and pitch.
	core.camera:set_look_horizontal (control.yaw)
	core.camera:set_look_vertical (control.pitch)
	local yaw = core.camera:get_look_horizontal ()

	-- Set self.standin and self.standon.
	self.standin = core.get_node_or_nil (self_pos)
	self.standon = self.standin
	if (self_pos.y - math.floor (self_pos.y + 0.5)) < 0.01 then
		local stand_on = vector.offset (self_pos, 0, -1, 0)
		self.standon = core.get_node_or_nil (stand_on)
	end
	if not self._last_standon or not self._last_standin then
		self._last_standon = self.standon
		self._last_standin = self.standin
	end

	-- Test movement info for collisions unless it would be
	-- reverted anyway.
	local switchtime = self.default_switchtime
	local t = switchtime + dtime
	if t < ONE_TICK then
		self:test_collision (moveresult)
	end

	-- Compute fluid immersion.
	local immersion_depth, liquidtype
		= self:check_standin (self_pos, params)
	self._immersion_depth = immersion_depth
	self.liquidtype = liquidtype

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

	-- Send physics state to server.
	self:send_movement_state ()

	-- Set jumping flag.
	self.jumping = control.jump and not self.fall_flying

	-- Apply acceleration.
	-- Slow down players using shields or bows.  TODO: the bows.
	local base = self.blocking ~= 0 and 0.2 or 1.0
	local moving_slowly = self.pose == POSE_CROUCHING
		or (self.pose == POSE_SWIMMING
		    and self._immersion_depth <= 0)
		or mcl_localplayer.is_using_bow ()

	if moving_slowly then
		local factor = math.min (PLAYER_CROUCH_FACTOR + self.sneak_speed_bonus, 1.0)
		self.acc_dir.z = control.movement_y * factor * base
		self.acc_dir.x = control.movement_x * factor * base
	else
		self.acc_dir.z = control.movement_y * base
		self.acc_dir.x = control.movement_x * base
	end

	-- Configure a suitable pose.
	local pose = self:desired_pose (self_pos, control, params)
	if pose ~= self.pose then
		self:apply_pose (pose)
	end
	self:tick_animation (control, dtime)

	----------------------------------------------------------------
	-- Physics section of globalstep.  The lifespan of the
	-- localplayer is divided into steps at intervals of ONE_TICK,
	-- and motion_step and the like are called whenever every such
	-- interval elapses in order to adjust the velocity and apply
	-- entity physics.
	----------------------------------------------------------------

	if t >= ONE_TICK then
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
			adj_pos, v, moveresult
				= self.localplayer:collision_move (adj_pos, v, before)
			self:test_collision (moveresult, v)
		end

		-- Run the physics simulation.
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
				adj_pos, v, moveresult
					= self.localplayer:collision_move (adj_pos, v, time)
				self:test_collision (moveresult, v)
			end
			phys_start = phys_start + ONE_TICK
		end
		self.localplayer:set_pos (adj_pos)
		self.localplayer:set_velocity (v)
		self.default_switchtime = t % ONE_TICK
	else
		self.default_switchtime = t
	end
	self._was_jumping = control.jump

	-- Enable or disable stepheight according as this mob is
	-- colliding with the ground.
	local enable_step_height = self.touching_ground
	if enable_step_height and self._previously_floating then
		self._previously_floating = false
		self.object:clear_property_overrides ({"stepheight"})
	elseif not enable_step_height and not self._previously_floating then
		self._previously_floating = true
		self.object:set_property_overrides ({stepheight = 0.0})
	end
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
-- These poses must currently be present in the table:
--  POSE_STANDING
--  POSE_CROUCHING = 1
--  POSE_SLEEPING = 2
--  POSE_FALL_FLYING = 3
--  POSE_SWIMMING = 4
--  POSE_DEATH = 4

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
	local def = mcl_localplayer.pose_defs[pose]
	return def and core.collides (def.collisionbox, self_pos,
					true, self.object, true)
end

function localplayer:collides (self_pos, off_x, off_y, off_z, reject_grazing)
	local test_pos = vector.offset (self_pos, off_x, off_y, off_z)
	return core.collides (self.collisionbox, test_pos,
				true, self.object, reject_grazing)
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
		if core.collides (pose_def.collisionbox, self_pos,
					true, self.object, true) then
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
	local posedef = mcl_localplayer.pose_defs[pose]
	if posedef then
		self.object:set_property_overrides ({
			collisionbox = posedef.collisionbox,
			eye_height = posedef.current_eye_height,
		})
		self.collisionbox = posedef.collisionbox

		if posedef.eye_height ~= self.target_eye_height then
			if self.current_eye_height == -1 then
				self.current_eye_height = posedef.eye_height
				local v = vector.new (0, posedef.eye_height, 0)
				core.camera:set_offset (v)
			else
				local v = core.camera:get_offset ()
				self.current_eye_height = v.y
			end
			self.eye_height_time = 0.0
			self.target_eye_height = posedef.eye_height
		end
		self.object:set_animation (posedef[self.animation], 0.05)
	end
	mcl_localplayer.send_playerpose (pose)
	self.pose = pose
end

function localplayer:desired_animation (controls, v)
	if math.abs (v.x) > 0.35 or math.abs (v.z) > 0.35 then
		local is_using_bow = mcl_localplayer.is_using_bow_visually ()
		if is_using_bow then
			return "walk_bow"
		elseif controls.dig then
			return "walk_mine"
		else
			return "walk"
		end
	elseif controls.dig then
		return "mine"
	else
		return "stand"
	end
end

local function norm_radians (x)
	local x = x % (math.pi * 2)
	if x >= math.pi then
		x = x - math.pi * 2
	end
	if x < -math.pi then
		x = x + math.pi * 2
	end
	return x
end

local FOURTY_DEG = math.rad (40)
local TWENTY_DEG = math.rad (20)
local SEVENTY_FIVE_DEG = math.rad (75)
local FIFTY_DEG = math.rad (50)
local ONE_HUNDRED_AND_TEN_DEG = math.rad (110)
local THIRTY_DEG = math.deg (30)
local FOURTY_THREE_DEG = math.rad (43)

local function dir_to_pitch (dir)
	local xz = math.abs (dir.x) + math.abs (dir.z)
	return -math.atan2 (-dir.y, xz)
end

local RIGHT_ARM_BLOCKING_OVERRIDE = {
	rotation = {
		vec = vector.new (20, -20, 0):apply (math.rad),
		absolute = true,
	},
}

local LEFT_ARM_BLOCKING_OVERRIDE = {
	rotation = {
		vec = vector.new (20, 20, 0):apply (math.rad),
		absolute = true,
	},
}

function localplayer:tick_animation (controls, dtime)
	local base = self.current_eye_height
	local target = self.target_eye_height
	local v = self.localplayer:get_velocity ()

	if base ~= target then
		local t = math.min (self.eye_height_time + dtime, 0.20)
		local v = vector.new (0, base + (target - base) * (t / 0.20), 0)
		core.camera:set_offset (v)

		if t >= 0.20 then
			self.current_eye_height = target
		end
		self.eye_height_time = t
	end

	local anim = self:desired_animation (controls, v)
	if anim ~= self.animation then
		local posedef = mcl_localplayer.pose_defs[self.pose]
		self.animation = anim
		if posedef then
			self.object:set_animation (posedef[anim], 0.05)
			mcl_localplayer.send_playeranim (anim)
		end
	end

	-- Animate FOV.
	if self.fov_factor ~= self.noticed_fov_factor then
		self.localplayer:set_fov (self.fov_factor, true, 0.20)
		self.noticed_fov_factor = self.fov_factor
	end

	-- Animate body.
	local look_dir = core.camera:get_look_horizontal ()
	local v = vector.normalize (v)
	local move_yaw = (math.abs (v.z) < 0.35 and math.abs (v.x) < 0.35)
		and self._last_move_yaw or math.atan2 (v.z, v.x) - math.pi / 2

	if self.pose == POSE_SWIMMING then
		local pitch = core.camera:get_look_vertical ()
		local move_pitch = dir_to_pitch (v)
		local norm_look_dir = norm_radians (look_dir)
		local rot = vector.new ((pitch - move_pitch) + TWENTY_DEG,
			move_yaw - norm_look_dir, 0)
		self.object:set_bone_override ("Head_Control", {
			rotation = { vec = rot, absolute = true, },
		})
		rot.x = SEVENTY_FIVE_DEG + move_pitch
		rot.y = move_yaw - norm_look_dir
		rot.z = math.pi
		self.object:set_bone_override ("Body_Control", {
			rotation = { vec = rot, absolute = true, },
		})
		self._last_move_yaw = move_yaw
		return
	elseif self.pose == POSE_FALL_FLYING then
		local pitch = -core.camera:get_look_vertical ()
		local move_pitch = dir_to_pitch (v)
		local xrot = move_pitch + FIFTY_DEG
		local yrot = move_yaw - look_dir
		local rot = vector.new (xrot, yrot, 0)
		self.object:set_bone_override ("Head_Control", {
			rotation = { vec = rot, absolute = true, },
		})
		local xrot = move_pitch + ONE_HUNDRED_AND_TEN_DEG
		local yrot = -move_yaw + norm_radians (look_dir)
		rot.x = xrot
		rot.y = yrot
		rot.z = math.pi
		self.object:set_bone_override ("Body_Control", {
			rotation = { vec = rot, absolute = true, },
		})
		self._last_move_yaw = move_yaw
		return
	elseif self.pose == POSE_SLEEPING then
		self.object:set_bone_override ("Head_Control", {})
		self.object:set_bone_override ("Body_Control", {
			rotation = {
				vec = vector.new (0, 0, 0),
				absolute = true,
			},
		})
		return
	elseif self.pose == POSE_DEATH then
		self.object:set_bone_override ("Head_Control", {})
		self.object:set_bone_override ("Body_Control", {})
		return
	end

	local move_yaw_lim = norm_radians (move_yaw)
	local look_dir_new = norm_radians (look_dir)
	local diff = norm_radians (move_yaw_lim - look_dir_new)

	if diff > FOURTY_DEG then
		move_yaw_lim = look_dir_new + FOURTY_DEG
	elseif diff < -FOURTY_DEG then
		move_yaw_lim = look_dir_new - FOURTY_DEG
	end
	self._last_move_yaw = move_yaw_lim
	local body = look_dir_new - move_yaw_lim
	local rot = vector.new (0, body, 0)
	self.object:set_bone_override ("Body_Control", {
		rotation = { vec = rot, absolute = true, },
	})
	rot.y = move_yaw_lim - look_dir_new
	rot.x = core.camera:get_look_vertical ()
	self.object:set_bone_override ("Head_Control", {
		rotation = { vec = rot, absolute = true, },
	})

	-- Control arm rotation whilst blocking.
	if self.blocking == 2 then
		self.object:set_bone_override ("Arm_Right_Pitch_Control",
					RIGHT_ARM_BLOCKING_OVERRIDE)
		self.object:set_bone_override ("Arm_Left_Pitch_Control", nil)
	elseif self.blocking == 1 then
		self.object:set_bone_override ("Arm_Right_Pitch_Control", nil)
		self.object:set_bone_override ("Arm_Left_Pitch_Control",
					LEFT_ARM_BLOCKING_OVERRIDE)
	elseif mcl_localplayer.is_using_bow_visually () then
		local pitch = math.deg (core.camera:get_look_vertical ())
		local right_arm_rot = vector.new(pitch + 90, -30, pitch * -1 * .35):apply (math.rad)
		local left_arm_rot = vector.new (pitch + 90, 43, pitch * 0.35):apply (math.rad)
		self.object:set_bone_override ("Arm_Right_Pitch_Control", {
			rotation = {
				vec = right_arm_rot,
				absolute = true,
			},
		})
		self.object:set_bone_override ("Arm_Left_Pitch_Control", {
			rotation = {
				vec = left_arm_rot,
				absolute = true,
			},
		})
	else
		self.object:set_bone_override ("Arm_Right_Pitch_Control", nil)
		self.object:set_bone_override ("Arm_Left_Pitch_Control", nil)
	end
end

function mcl_localplayer.do_posectrl (ctrlword)
	assert (not ctrlword or (ctrlword >= POSE_STANDING
					and ctrlword <= POSE_DEATH))
	localplayer.overriding_pose = ctrlword
end

function mcl_localplayer.do_shieldctrl (ctrlword)
	localplayer.blocking = ctrlword
end

------------------------------------------------------------------------
-- Player physics factors.
------------------------------------------------------------------------

function localplayer:validate_attribute (field, value)
	if field == "fov_factor" then
		return math.max (math.min (value, 3.0), 0.8)
	end
	return value
end

function localplayer:post_apply_physics_factor (field, oldvalue, value)
	-- Nothing here but crickets.
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
