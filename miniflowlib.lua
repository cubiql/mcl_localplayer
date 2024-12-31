miniflowlib = {}

--sum of direction vectors must match an array index

--(sum,root)
--(0,1), (1,1+0=1), (2,1+1=2), (3,1+2^2=5), (4,2^2+2^2=8)

local inv_roots = {
	[0] = 1,
	[1] = 1,
	[2] = 0.70710678118655,
	[4] = 0.5,
	[5] = 0.44721359549996,
	[8] = 0.35355339059327,
}

local function to_unit_vector(dir_vector)
	local sum = dir_vector.x * dir_vector.x + dir_vector.z * dir_vector.z
	return {x = dir_vector.x * inv_roots[sum], y = dir_vector.y, z = dir_vector.z * inv_roots[sum]}
end

local IGNORE_NODE = {
	name = "ignore",
	param1 = 0,
	param2 = 0,
}

--This code is more efficient
local function quick_flow_logic (node, pos_testing, direction)
	local name = node.name
	local def = mcl_localplayer.get_node_def (name)
	if not def then
		return 0
	end
	local liquid_type = (def.liquidtype or def._liquid_type)
	if liquid_type == "source" then
		local node_testing = (core.get_node_or_nil (pos_testing) or IGNORE_NODE)
		local def = mcl_localplayer.get_node_def (node_testing.name)
		if not def or (def.liquid_type ~= "flowing"
				and def._liquid_type ~= "flowing") then
			return 0
		end
		return direction
	elseif liquid_type == "flowing" then
		local node_testing = (core.get_node_or_nil (pos_testing) or IGNORE_NODE)
		local param2_testing = node_testing.param2
		local def = mcl_localplayer.get_node_def (node_testing.name)
		if not def then
			return 0
		end
		local liquid_type = (def.liquidtype or def._liquid_type)
		if liquid_type == "source" then
			return -direction
		elseif liquid_type == "flowing" then
			if param2_testing < node.param2 then
				if (node.param2 - param2_testing) > 6 then
					return -direction
				else
					return direction
				end
			elseif param2_testing > node.param2 then
				if (param2_testing - node.param2) > 6 then
					return direction
				else
					return -direction
				end
			end
		end
	end
	return 0
end

local function quick_flow_vertical (node)
	local name = node.name
	local def = mcl_localplayer.get_node_def (name)
	if def and (def.liquidtype == "source"
			or def._liquidtype == "source") then
		return 0
	end
	return node.param2 >= 8 and 1 or 0
end

local function quick_flow (pos, node)
	local x = quick_flow_logic (node, {x = pos.x-1, y = pos.y, z = pos.z}, -1)
		+ quick_flow_logic (node, {x = pos.x+1, y = pos.y, z = pos.z}, 1)
	local y = quick_flow_vertical (node)
	local z = quick_flow_logic (node, {x = pos.x, y = pos.y, z = pos.z-1}, -1)
		+ quick_flow_logic (node, {x = pos.x, y = pos.y, z = pos.z+1}, 1)
	return to_unit_vector ({x = x, y = -y, z = z})
end

miniflowlib.quick_flow = quick_flow
