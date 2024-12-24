------------------------------------------------------------------------
-- Player physics and input.
--
-- TODO: jump bonuses, fall damage, sprinting, poses, flying, fall
-- flying, cobwebs jump force boosting, shields, riding, bows, fov
-- modifiers, status effects
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
	-- Increase jump_height to 0.46 (from Minecraft's 0.42) as
	-- Minetest's globalsteps are more granular and respond to
	-- velocity changes sooner.
	jump_height = 9.6,
	jump_timer = 0.0,
	jumping = false,
	gravity = -1.6,
	touching_ground = false,
	_was_touching_ground = false,
	_sprinting = false,
	water_friction = 0.6,
	water_velocity = 0.4,
	depth_strider_level = 0,
	_previously_floating = false,
	switchtime = nil,
	_last_standin = nil,
	_last_standon = nil,
	collisionbox = nil,
	immersion_depth = 0.0,
	liquidtype = nil,
	_last_liquidtype = nil,
	pose = POSE_STANDING,
	default_switchtime = 0.0,
	fall_flying = false,
	sleeping = false,
	swimming = false,
	animation = "stand",
	eye_height_time = 0.0,
	current_eye_height = -1,
	target_eye_height = 1.6,
	_last_move_yaw = 0,
	was_touching_ground = true,
	_prev_pos = nil,
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
}

local AIR_DRAG			= 0.98
local AIR_FRICTION		= 0.91
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
local WATER_DESCENT		= -0.8
local PLAYER_FLY_DRAG		= 0.6
local PLAYER_CROUCH_FACTOR	= 0.3

local function scale_speed (speed, friction)
	local f = BASE_FRICTION3 / (friction * friction * friction)
	return speed * f
end

function localplayer:get_flying_speed (params)
	if params.flying then
		-- TODO: sprinting, spectator mode (??).
		return self._sprinting and 4.0 or 2.0 -- 2.0 blocks/s
	else
		return 0.4 -- 0.4 blocks/s
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

local function pow_by_step (value, dtime)
	return math.pow (value, dtime / ONE_TICK)
end

function localplayer:get_jump_force (moveresult)
	return self.jump_height
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
	return v
end

local function horiz_collision (moveresult)
	for _, item in ipairs (moveresult.collisions) do
		if item.type == "node"
			and (item.axis == "x" or item.axis == "z") then
			return true
		end
	end
	return false
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

function localplayer:motion_step (self_pos, dtime, moveresult, controls, params)
	local jump_timer = math.max (self.jump_timer - dtime, 0)
	local acc_dir = self.acc_dir
	local acc_speed = self.movement_speed
	local standin = self._last_standin
		and core.get_node_def (self._last_standin.name)
		or EMPTY_NODE
	local standon = self._last_standon
		and core.get_node_def (self._last_standon.name)
		or EMPTY_NODE
	local gravity = self.gravity
	local touching_ground = not params.flying and self.touching_ground
	local horiz_collision = self.horiz_collision
	self.jump_timer = jump_timer

	local p = pow_by_step (AIR_DRAG, dtime)
	acc_dir.x = acc_dir.x * p
	acc_dir.z = acc_dir.z * p

	local v = self.localplayer:get_velocity ()
	local fly_y = v.y

	local climbable = standin.climbable or standon.climbable
	local jumping = self.jumping
	local h_scale, v_scale

	local velocity_factor = 1.0
	local liquidtype = self.liquidtype
	local server_def = mcl_localplayer.node_defs[standon.name]

	if server_def and server_def._mcl_velocity_factor then
		velocity_factor = server_def._mcl_velocity_factor
	end

	-- Don't switch between different liquidtypes more rapidly
	-- than every tick.
	if liquidtype ~= self._last_liquidtype then
		local t = (self.switchtime or self.default_switchtime) + dtime

		if t < ONE_TICK then
			liquidtype = self._last_liquidtype
			self.switchtime = t
		else
			self._last_liquidtype = liquidtype
			self.switchtime = nil
		end
	else
		self.switchtime = nil
	end

	-- TODO: dolphin's grace.

	if liquidtype == "water" then
		local water_vec = self:check_water_flow (self_pos)
		local water_friction = self.water_friction
		if self._sprinting then
			water_friction = SPRINTING_WATER_DRAG
		end
		local friction = water_friction * velocity_factor
		local speed = self.water_velocity

		-- Apply depth strider.  TODO!!
		local level = math.min (3, self.depth_strider_level)
		level = touching_ground and level or level / 2
		if level > 0 then
			local delta = BASE_FRICTION * AIR_FRICTION - friction
			friction = friction + delta * level / 3
			delta = acc_speed - speed
			speed = speed + delta * level / 3
		end

		-- Adjust speed by friction.  Minecraft applies
		-- friction to acceleration (speed), not just the
		-- previous velocity.
		local r, z = pow_by_step (friction, dtime), friction
		local base_water_drag = WATER_DRAG
		local p = pow_by_step (base_water_drag, dtime)
		h_scale = (1 - r) / (1 - z)
		v_scale = (1 - p) / (1 - base_water_drag)

		local speed_x, speed_y = speed * h_scale, speed * v_scale
		local fv_x, fv_y, fv_z
			= self:accelerate_relative (acc_dir, speed_x, speed_y)

		-- Apply friction and acceleration.
		v.x = v.x * r + fv_x
		v.y = v.y * p
		v.z = v.z * r + fv_z

		-- Apply vertical acceleration.
		v.y = v.y + fv_y

		-- Apply gravity unless this mob is sprinting.
		if not self._sprinting then
			v.y = v.y + gravity / 16 * v_scale
			if v.y > -0.06 and v.y < 0 then
				v.y = -0.06
			end
		end

		-- If colliding horizontally within water, detect
		-- whether the result of this movement is vertically
		-- within 0.6 nodes of a position clear of water and
		-- collisions, and apply a force to this mob so as to
		-- breach the water if so.
		if horiz_collision then
			local r = 1 / v_scale
			local diff_tick = v.y * r * ONE_TICK
			local dx = v.x * r * ONE_TICK
			local dz = v.z * r * ONE_TICK
			local will_breach_water
				= self:will_breach_water (self_pos, dx, 0.6, dz, params)
			if will_breach_water then
				v.y = 6.0
			end
		end

		if water_vec and (water_vec.x >= 0
					or water_vec.y >= 0
					or water_vec.z >= 0) then
			v.x = v.x + water_vec.x * LIQUID_FORCE * h_scale
			v.y = v.y + water_vec.y * LIQUID_FORCE * v_scale
			v.z = v.z + water_vec.z * LIQUID_FORCE * h_scale
		end
	elseif liquidtype == "lava" then
		local speed = LAVA_SPEED
		local r, z = pow_by_step (LAVA_FRICTION, dtime), LAVA_FRICTION
		h_scale = (1 - r) / (1 - z)
		v_scale, p = h_scale, r

		local speed_x, speed_y
			= speed * h_scale, speed * v_scale
		local fv_x, fv_y, fv_z
			= self:accelerate_relative (acc_dir, speed_x, speed_y)
		v.x = v.x * r + fv_x
		v.y = v.y * p
		v.z = v.z * r + fv_z
		v.y = v.y + (gravity / 4.0) * v_scale
		v.y = v.y + fv_y

		-- If colliding horizontally within lava,
		-- detect whether the result of this movement
		-- is vertically within 0.6 nodes of a
		-- position clear of lava and collisions, and
		-- apply a force to this mob so as to breach
		-- the water if so.
		if horiz_collision then
			local r = 1 / v_scale
			local diff_tick = v.y * r * ONE_TICK
			local dx = v.x * r * ONE_TICK
			local dz = v.z * r * ONE_TICK
			local will_breach_lava
				= self:will_breach_water (self_pos, dx, 0.6, dz, params)
			if will_breach_lava then
				v.y = 6.0
			end
		end
	else
		-- If not standing on air, apply slippery to a base value of
		-- 0.6.
		local slippery = standon.groups.slippery
		local friction
		-- The order in which Minecraft applies velocity is
		-- such that it is scaled by ground friction after
		-- application even if vertical acceleration would
		-- render the mob airborne.  Emulate this behavior, in
		-- order to avoid a marked disparity in the speed of
		-- mobs that jump while in motion or walk off ledges.
		if self._was_touching_ground
			and slippery and slippery > 0 then
			friction = BASE_SLIPPERY
		elseif self._was_touching_ground then
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
		local r, z = pow_by_step (friction, dtime), friction
		local p = pow_by_step (base_air_drag, dtime)
		h_scale = (1 - r) / (1 - z)
		v_scale = (1 - p) / (1 - base_air_drag)
		local speed_x, speed_y = speed * h_scale, speed * v_scale
		local fv_x, fv_y, fv_z
			= self:accelerate_relative (acc_dir, speed_x, speed_y)
		v.x = v.x * r + fv_x
		v.y = v.y * p + gravity * v_scale * base_air_drag
		v.z = v.z * r + fv_z
		v.y = v.y + fv_y
	end

	if jumping then
		if liquidtype then
			v.y = v.y + LIQUID_JUMP_FORCE * v_scale
		else
			if touching_ground and self.jump_timer <= 0 then
				local force = self:get_jump_force (moveresult)
				v = self:jump_actual (v, force)
				self.jump_timer = 0.5
				self.default_switchtime = 0.0
			end
		end
	end

	local enable_step_height = moveresult.touching_ground
		or moveresult.standing_on_object
	if enable_step_height and self._previously_floating then
		self._previously_floating = false
		self.object:clear_property_overrides ({"stepheight"})
	elseif not enable_step_height and not self._previously_floating then
		self._previously_floating = true
		self.object:set_property_overrides ({stepheight = 0.0})
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
		self.reset_fall_damage = 1

		if v.y < 0 and controls.sneak then
			v.y = 0.0
		end
	end

	if params.flying then
		local p = pow_by_step (PLAYER_FLY_DRAG, dtime)
		v_scale = (1 - p) / (1 - PLAYER_FLY_DRAG)
		v.y = fly_y * p
	end

	self.localplayer:set_velocity (v)
	v.y = 0
	-- self:check_collision (self_pos)
	return h_scale, v_scale
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

function localplayer:crouch_reduce_velocity (self_pos, moveresult, dtime)
	local v = self.localplayer:get_velocity ()

	v.x = self:check_crouch_axis_x (self_pos, v.x)
	v.z = self:check_crouch_axis_z (self_pos, v.z)
	v.x, v.z = self:check_crouch_axis_both (self_pos, v.x, v.z)
	self.localplayer:set_velocity (v)
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
		-- TODO: apply FOV adjustment and announce change to server.
		-- TODO: enable swimming.
		self:add_physics_factor ("movement_speed", SPEED_MODIFIER_SPRINTING, 0.3,
					"add_multiplied_total")
		self:add_physics_factor ("fov_factor", FOV_MODIFIER_SPRINTING, 0.15, "add")
	else
		self._sprinting = false
		self:remove_physics_factor ("movement_speed", SPEED_MODIFIER_SPRINTING)
		self:remove_physics_factor ("fov_factor", FOV_MODIFIER_SPRINTING)
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
		or self._sprinting ~= state.is_sprinting then
		state.is_sprinting = self._sprinting
		state.in_water = in_water
		mcl_localplayer.send_movement_state (state)
	end
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

	if self._stuck_in then
		self._stuck_in = nil
		self.localplayer:set_velocity (ZERO_VECTOR)
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

	-- Compute collision information
	self.horiz_collision = horiz_collision (moveresult)
	self.minor_collision = self._sprinting
		and self.horiz_collision
		and self:collision_angle () < EIGHT_DEG

	-- Compute fluid immersion.
	local immersion_depth, liquidtype
		= self:check_standin (self_pos, params)
	self._immersion_depth = immersion_depth
	self.liquidtype = liquidtype

	-- Begin sprinting if possible.
	if self:may_sprint (control) and control.aux1
		and self._immersion_depth <= 0
		and (not self.horiz_collision or self.minor_collision) then
		if not self._sprinting then
			self:set_sprinting (true)
		end
	elseif self._sprinting then
		-- TODO: swimming.
		self:set_sprinting (false)
	end

	-- Send physics state to server.
	self:send_movement_state ()

	-- Set jumping flag.
	self.jumping = control.jump

	-- Apply acceleration.
	local moving_slowly = self.pose == POSE_CROUCHING
		or (self.pose == POSE_SWIMMING
			and self._immersion_depth < 0)

	if moving_slowly then
		local factor = math.min (PLAYER_CROUCH_FACTOR + self.sneak_speed_bonus, 1.0)
		self.acc_dir.z = control.movement_y * factor
		self.acc_dir.x = control.movement_x * factor
	else
		self.acc_dir.z = control.movement_y
		self.acc_dir.x = control.movement_x
	end

	-- Configure a suitable pose.
	local pose = self:desired_pose (self_pos, control, params)
	if pose ~= self.pose then
		self:apply_pose (pose)
	end
	self:tick_animation (control, dtime)

	-- If stuck in a node, force dtime to 0.05, as the velocity is
	-- to be reset on the next globalstep.
	if self._stuck_in then
		dtime = ONE_TICK
	end

	-- When input is registered, there must be a minimum of a one
	-- tick delay between its commencement and the commencement of
	-- the next jump.  Otherwise, Luanti's lesser dtime interval
	-- may result in jumps being performed prematurely.
	if control.movement_y >= 0 and not control.jump then
		self.jump_timer = math.max (self.jump_timer, ONE_TICK)
	end

	local h_scale, v_scale
		= self:motion_step (self_pos, dtime, moveresult, control, params)

	-- Descend in water.
	if self.liquidtype == "water" and control.sneak then
		local v = self.localplayer:get_velocity ()
		v.y = v.y + WATER_DESCENT * v_scale
		self.localplayer:set_velocity (v)
	elseif params.flying then
		local dir = 0.0
		if control.sneak then
			dir = dir + -1.0
		end
		if control.jump then
			dir = dir + 1.0
		end
		local v = self.localplayer:get_velocity ()
		v.y = v.y + dir * self:get_flying_speed (params) * 3.0 * v_scale
		self.localplayer:set_velocity (v)
	end

	-- Minecraft evaluates surface properties before applying
	-- movement and only does so once per tick.
	local t = self.default_switchtime + dtime
	if t >= ONE_TICK then
		t = t % ONE_TICK
		self._last_standon = self.standon
		self._last_standin = self.standin

		if params.flying then
			self._was_touching_ground = false
			self.touching_ground = false
		else
			local touching_ground = moveresult.touching_ground
				or moveresult.standing_on_object
			self._was_touching_ground = self.touching_ground
			self.touching_ground = touching_ground
		end
	end
	self.default_switchtime = t
	self._last_control = control
	self._prev_pos = self_pos

	-- Implement crouching by refusing to move forward if doing so
	-- would result in a fall after one tick.
	if control.sneak and not params.flying
		and (moveresult.touching_ground or moveresult.standing_on_object) then
		self:crouch_reduce_velocity (self_pos, moveresult, dtime)
	end
	if self._stuck_in then
		local v = self.localplayer:get_velocity ()
		v.x = v.x * self._stuck_in.x
		v.y = v.y * self._stuck_in.y
		v.z = v.z * self._stuck_in.z
		self.localplayer:set_velocity (v)
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
	if data.can_sprint ~= nil then
		localplayer.can_sprint = (not not data.can_sprint)
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
	if self.localplayer:get_hp () == 0 then
		return POSE_DEATH
	elseif self.fall_flying then
		pose = POSE_FALL_FLYING
	elseif self.sleeping then
		pose = POSE_SLEEPING
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
		-- Walking.
		-- TODO: body movement.
		if controls.dig then
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

	local look_dir = core.camera:get_look_horizontal ()
	local v = vector.normalize (v)
	local move_yaw = (math.abs (v.z) < 0.35 and math.abs (v.x) < 0.35)
		and self._last_move_yaw or math.atan2 (v.z, v.x) - math.pi / 2

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

	-- TODO: swim and fall flying poses.
	-- TODO: head rotation.
	-- TODO: send animations to server.
end


------------------------------------------------------------------------
-- Player physics factors.
------------------------------------------------------------------------

function localplayer:validate_attribute (field, value)
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

-- function localplayer:restore_physics_factors ()
-- 	for field, factors in pairs (self._physics_factors) do
-- 		-- Upgrade obsolete numerical factors.
-- 		for id, data in pairs (factors) do
-- 			if id ~= "base" and type (data) == "number" then
-- 				factors[id] = {
-- 					amount = data,
-- 					op = "scale_by",
-- 				}
-- 			end
-- 		end
-- 		apply_physics_factors (self, field)
-- 	end
-- end
