------------------------------------------------------------------------
-- Utility functions.
------------------------------------------------------------------------

function table.update(t, ...)
	for _, to in ipairs {...} do
		for k, v in pairs (to) do
			t[k] = v
		end
	end
	return t
end

function table.merge (t, ...)
	local t2 = table.copy (t)
	return table.update (t2, ...)
end

------------------------------------------------------------------------
-- `.lua' chatcommand.
------------------------------------------------------------------------

-- core.register_chatcommand ("lua", {
-- 	params = "<string>",
-- 	func = function (param)
-- 		local fn, err = loadstring (param)
-- 		if not fn then
-- 			print (err)
-- 		else
-- 			local ok, err = pcall (fn)
-- 			if not ok then
-- 				print (err)
-- 			end
-- 		end
-- 	end,
-- })
