------------------------------------------------------------------------
-- 64-bit integers.
------------------------------------------------------------------------

local UINT_MAX = 4294967295

local function ull (hi, lo)
	return { lo, hi, }
end

local function normalize (l)
	return (l + UINT_MAX + 1) % (UINT_MAX + 1)
end

local function extull (int)
	return {
		normalize (int),
		(int < 0 or int > 0x7fffffff) and UINT_MAX or 0,
	}
end

local function extkull (ull, int)
	ull[1] = normalize (int)
	ull[2] = (int < 0 or int > 0x7fffffff) and UINT_MAX or 0
end

local bxor = bit.bxor
local band = bit.band
local bnot = bit.bnot
local bor = bit.bor
local rshift = bit.rshift
local lshift = bit.lshift

local ceil = math.ceil
local fmod = math.fmod
local floor = math.floor

local function rtz (n)
	if n < 0 then
		return ceil (n)
	end
	return floor (n)
end

local LONG_MAX_AS_DOUBLE = (2 ^ 63 - 1)
local LONG_MIN_AS_DOUBLE = -(2 ^ 63)

-- Meant to be equivalent to `(long) (double) d' in Java.
local function dtoull (ull, d)
	if d >= LONG_MAX_AS_DOUBLE then
		ull[2] = 0x7fffffff
		ull[1] = 0xffffffff
		return
	elseif d <= LONG_MIN_AS_DOUBLE then
		ull[2] = 0x80000000
		ull[1] = 0x00000000
		return
	end

	local x = rtz (d)
	local hi = floor (x / 0x100000000)
	local lo = fmod (x, 0x100000000)
	ull[1] = normalize (lo)
	ull[2] = normalize (hi)
end

local function addull (a, b)
	local a_lo, a_hi = a[1], a[2]
	local b_lo, b_hi = b[1], b[2]

	local lo, hi = a_lo + b_lo, 0
	if b_lo > UINT_MAX - a_lo then
		lo = lo % (UINT_MAX + 1)
		hi = 1
	end
	hi = (hi + a_hi + b_hi) % (UINT_MAX + 1)
	a[1] = lo
	a[2] = hi
end

local function ltull (a, b) -- B < A
	return b[2] < a[2] or (b[2] == a[2] and b[1] < a[1])
end

local function andull (a, b)
	a[1] = normalize (band (a[1], b[1]))
	a[2] = normalize (band (a[2], b[2]))
end

local function xorull (a, b)
	a[1] = normalize (bxor (a[1], b[1]))
	a[2] = normalize (bxor (a[2], b[2]))
end

local function addkull (a, k)
	local a_lo, a_hi = a[1], a[2]

	local lo, hi = a_lo + k, 0
	if k > UINT_MAX - a_lo then
		lo = lo % (UINT_MAX + 1)
		hi = 1
	end
	hi = (hi + a_hi) % (UINT_MAX + 1)
	a[1] = lo
	a[2] = hi
end

local function negull (x)
	local lo, hi = normalize (bnot (x[1])),
		normalize (bnot (x[2]))
	if lo == UINT_MAX then
		lo, hi = 0, (hi + 1) % (UINT_MAX + 1)
	else
		lo = lo + 1
	end
	x[1] = lo
	x[2] = hi
end

local function subull (a, b)
	local subtrahend = { b[1], b[2], }
	negull (subtrahend)
	addull (a, subtrahend)
end

local USHORT_MAX = 65535

local function divull (a, d) -- NOTE: d <= 0x7fff
	local a_lo, a_hi = a[1], a[2]
	local a1 = band (a_lo, USHORT_MAX)
	local a2 = rshift (a_lo, 16)
	local a3 = band (a_hi, USHORT_MAX)
	local a4 = rshift (a_hi, 16)
	local r, q4, q3, q2, q1

	q4, r = floor (a4 / d), fmod (a4, d)
	q3, r = floor ((a3 + lshift (r, 16)) / d),
		fmod (a3 + lshift (r, 16), d)
	q2, r = floor ((a2 + lshift (r, 16)) / d),
		fmod (a2 + lshift (r, 16), d)
	q1, r = floor ((a1 + lshift (r, 16)) / d),
		fmod (a1 + lshift (r, 16), d)
	a[1] = normalize (bor (lshift (q2, 16), q1))
	a[2] = normalize (bor (lshift (q4, 16), q3))
	return normalize (r)
end

local function mulull (a, m)
	local a_lo, a_hi = a[1], a[2]
	local a1 = band (a_lo, USHORT_MAX)
	local a2 = rshift (a_lo, 16)
	local a3 = band (a_hi, USHORT_MAX)
	local a4 = rshift (a_hi, 16)
	local p1, p2, p3, p4
	local mullo = band (m, USHORT_MAX)
	local mulhi = rshift (m, 16)

	-- Long multiplication of low word.
	p1 = a1 * mullo
	p2 = a1 * mulhi
	p3 = a2 * mullo
	p4 = a2 * mulhi

	-- Add products of low word handling carry.
	a_lo = p1 -- lo*lo
	a_hi = p4 -- hi*hi

	-- p3 + p2 = lo*hi + hi*lo = 47:16
	-- Check carry.
	if p3 > UINT_MAX - p2 then
		a_hi = a_hi + 65536
	end

	-- Bits 47:16.
	local hilo = (p3 + p2) % (1 + UINT_MAX)
	a_lo = a_lo + (hilo * 65536) % (1 + UINT_MAX) -- lshift (hilo, 16)
	a_hi = a_hi + band (rshift (hilo, 16), USHORT_MAX)

	if a_lo > UINT_MAX then
		-- Carry into a_hi.
		a_lo = a_lo % (1 + UINT_MAX)
		a_hi = a_hi + 1
	end

	-- Long multiplication of hi word.
	p1 = a3 * mullo
	p2 = a3 * mulhi
	p3 = a4 * mullo
	p4 = a4 * mulhi

	local hi = p4
	a_hi = a_hi + p1
	if a_hi > UINT_MAX then
		hi = hi + 1
		a_hi = a_hi % (1 + UINT_MAX)
	end

	local hilo = (p2 + p3) % (1 + UINT_MAX)
	if p2 > UINT_MAX - p3 then
		hi = hi + 65536
	end
	a_hi = a_hi + (hilo * 65536) % (1 + UINT_MAX) -- lshift (hilo, 16)
	if a_hi > UINT_MAX then
		hi = hi + 1
		a_hi = a_hi % (1 + UINT_MAX)
	end
	hi = hi + rshift (hilo, 16)

	a[1] = a_lo
	a[2] = a_hi

	return (hi % (1 + UINT_MAX))
end

local function detect_luajit ()
	local fn = loadstring ([[
local x = 0x3ull
x = bit.band (x, 0x1ull)
return x == 0x1ull
]])
	return fn and fn ()
end
mcl_levelgen.detect_luajit = detect_luajit

local function shlull (a, k)
	local hi, lo = a[2], a[1]
	if k >= 32 then
		hi = lo
		lo = 0
		k = k - 32
	end
	hi = band (lshift (hi, k), UINT_MAX)
	local rem = rshift (lo, 32 - k)
	a[2] = normalize (bor (hi, rem))
	lo = k == 32 and 0 or lshift (lo, k)
	a[1] = normalize (lo)
end

local function shrull (a, k) -- logical shift right
	local lo, hi = a[1], a[2]
	if k >= 32 then
		lo = hi
		hi = 0
		k = k - 32
	end
	local rem = lshift (hi, 32 - k)
	hi = k ~= 32 and rshift (hi, k) or 0
	lo = rshift (lo, k)
	a[1] = normalize (bor (lo, rem))
	a[2] = normalize (hi)
end

local function ashrull (a, k) -- arithmetic shift right
	local lo, hi = a[1], a[2]
	local n, s = k, band (hi, 0x80000000) ~= 0
	if k >= 32 then
		lo = hi
		hi = 0
		k = k - 32
	end
	local rem = lshift (hi, 32 - k)
	hi = k ~= 32 and rshift (hi, k) or 0
	lo = rshift (lo, k)

	-- Sign extend.
	if s then
		local n = 64 - n
		if n < 32 then
			local lomask = lshift (UINT_MAX, n)
			lo = bor (lomask, lo)
			hi = UINT_MAX
		elseif n < 64 then
			local himask = lshift (UINT_MAX, n - 32)
			hi = bor (himask, hi)
		end
	end

	a[1] = normalize (bor (lo, rem))
	a[2] = normalize (hi)
end

local function rotlull (a, k)
	local lo, hi = a[1], a[2]
	shlull (a, k)
	a[1], lo = lo, a[1]
	a[2], hi = hi, a[2]
	shrull (a, (64 - k))
	a[1] = normalize (bor (a[1], lo))
	a[2] = normalize (bor (a[2], hi))
end

local function equalull (a, b)
	return a[1] == b[1] and a[2] == b[2]
end

local function zeroull (x)
	return x[1] == 0 and x[2] == 0
end

local function tostringull (x)
	local x = { x[1], x[2], }
	local chars = {}
	while not zeroull (x) do
		local r = divull (x, 10)
		table.insert (chars, string.char (48 + r))
	end
	local str = ""
	for i = 0, #chars - 1 do
		str = str .. chars[#chars - i]
	end
	return str
end

local function stringtoull (x, str)
	local n, tmp = #str, ull (0, 0)
	x[1], x[2] = 0, 0

	for i = 1, n do
		local value = string.byte (str:sub (i, i))
		if value < 48 or value > 57 then
			return false
		end
		if mulull (x, 10) ~= 0 then
			return false
		end
		local lo, hi = x[1], x[2]
		tmp[1], tmp[2] = value - 48, 0
		addull (x, tmp)
		tmp[1], tmp[2] = lo, hi
		if ltull (tmp, x) then
			return false
		end
	end
	return true
end

local tmp = ull (0, 0)

local function mul2ull (a, b)
	local lo, hi = a[1], a[2]
	local lb, hb = b[1], b[2]
	mulull (a, lb)
	a[1], lo = lo, a[1]
	a[2], hi = hi, a[2]
	mulull (a, hb)
	shlull (a, 32)
	tmp[1] = lo
	tmp[2] = hi
	addull (a, tmp)
end

if detect_luajit () then
	local str = [[
	local bxor = bit.bxor
	local band = bit.band
	local bnot = bit.bnot
	local bor = bit.bor
	local rshift = bit.rshift
	local lshift = bit.lshift
	local rol = bit.rol
	local arshift = bit.arshift
	local UINT_MAX = 4294967295
	local tonumber = tonumber

	local function mulull (a, m)
		local a_lo, a_hi = a[1], a[2]

		-- Long multiplication of two 32 bit operands into a
		-- 64 bit product.
		local m1 = m * 1ull
		local lo = a_lo * m1
		local hi = a_hi * m1
		local excess = rshift (hi, 32)
		local lohi = rshift (lo, 32)
		local carry

		hi = band (hi, 0xffffffffull)
		carry = rshift ((UINT_MAX - lohi) - hi, 63)
		excess = excess + carry
		hi = band (hi + lohi, 0xffffffffull)
		a[1] = tonumber (band (lo, 0xffffffffull))
		a[2] = tonumber (hi)
		return tonumber (excess)
	end

	local function addull (a, b)
		local along = 0x100000000ull * a[2] + a[1]
		local blong = 0x100000000ull * b[2] + b[1]
		local value = along + blong
		a[1] = tonumber (band (value, 0xffffffffull))
		a[2] = tonumber (rshift (value, 32))
	end

	local function addkull (a, k)
		local along = 0x100000000ull * a[2] + a[1]
		local value = along + k
		a[1] = tonumber (band (value, 0xffffffffull))
		a[2] = tonumber (rshift (value, 32))
	end

	-- Avoid expensive normalization by performing unsigned
	-- arithmetic.
	local function andull (a, b)
		a[1] = tonumber (band (a[1] * 1ull, b[1] * 1ull))
		a[2] = tonumber (band (a[2] * 1ull, b[2] * 1ull))
	end

	local function xorull (a, b)
		a[1] = tonumber (bxor (a[1] * 1ull, b[1] * 1ull))
		a[2] = tonumber (bxor (a[2] * 1ull, b[2] * 1ull))
	end

	local function rotlull (a, k)
		local along = 0x100000000ull * a[2] + a[1]
		local value = rol (along, k)
		a[1] = tonumber (band (value, 0xffffffffull))
		a[2] = tonumber (rshift (value, 32))
	end

	local function shrull (a, k)
		local along = 0x100000000ull * a[2] + a[1]
		local value = rshift (along, k)
		a[1] = tonumber (band (value, 0xffffffffull))
		a[2] = tonumber (rshift (value, 32))
	end

	local function ashrull (a, k)
		local along = 0x100000000ull * a[2] + a[1]
		local value = arshift (along, k)
		a[1] = tonumber (band (value, 0xffffffffull))
		a[2] = tonumber (rshift (value, 32))
	end

	local function shlull (a, k)
		local along = 0x100000000ull * a[2] + a[1]
		local value = lshift (along, k)
		a[1] = tonumber (band (value, 0xffffffffull))
		a[2] = tonumber (rshift (value, 32))
	end

	local function mul2ull (a, b)
		local along = 0x100000000ull * a[2] + a[1]
		local blong = 0x100000000ull * b[2] + b[1]
		local value = along * blong
		a[1] = tonumber (band (value, 0xffffffffull))
		a[2] = tonumber (rshift (value, 32))
	end
	return mulull, addull, addkull, andull, xorull,
		rotlull, shrull, ashrull, shlull, mul2ull
]]
	local fn = loadstring (str)
	mulull, addull, addkull, andull, xorull,
		rotlull, shrull, ashrull, shlull, mul2ull = fn ()
end

local function lj_test_assert (cond)
	assert (cond, [[PRNG validation failed.
Your LuaJIT installation (or Lua interpreter) is out-of-date and does not generate pseudo-random numbers correctly.  Mineclonia will not function under such a configuration in order to avoid scenarios where structure or level generation proceeds erroneously or inconsistently.  Please refer to https://luajit.org/install.html for details as regards updating your LuaJIT installation.]])
end

-- Tests.
if true then
	local x = ull (UINT_MAX, UINT_MAX)
	lj_test_assert (tostringull (x) == "18446744073709551615")

	local x = ull (0, UINT_MAX - 1)
	addull (x, ull (0, 2))
	lj_test_assert (tostringull (x) == tostring (UINT_MAX + 1))
	local x = ull (UINT_MAX, UINT_MAX)
	addull (x, ull (65535, 1))
	lj_test_assert (tostringull (x) == "281470681743360")
	local x = ull (UINT_MAX, UINT_MAX)
	negull (x)
	lj_test_assert (tostringull (x) == "1")
	local x = ull (0, 473902)
	subull (x, ull (0, 473904))
	local y = ull (0, 2)
	negull (y)
	lj_test_assert (equalull (x, y))
	lj_test_assert (tostringull (ull (2654435769, 2135587861)) == "11400714819323198485")
	lj_test_assert (tostringull (ull (1779033703, 4089235721)) == "7640891576956012809")

	local x = ull (0, UINT_MAX)
	shlull (x, 32)
	lj_test_assert (tostringull (x) == "18446744069414584320")
	shlull (x, 31)
	lj_test_assert (tostringull (x) == "9223372036854775808")
	local y = ull (0, UINT_MAX)
	shlull (y, 24)
	lj_test_assert (tostringull (y) == "72057594021150720")
	shlull (y, 8)
	lj_test_assert (tostringull (y) == "18446744069414584320")
	local y = ull (0, 1)
	shlull (y, 63)
	lj_test_assert (tostringull (y) == "9223372036854775808")

	local x = ull (UINT_MAX, 0)
	shrull (x, 32)
	lj_test_assert (tostringull (x) == tostring (UINT_MAX))

	local x = ull (0xffff, 0xffff0000)
	rotlull (x, 32)
	lj_test_assert (tostringull (x) == "18446462598732906495")

	local x = ull (0x8416021, 0x7307451e)
	rotlull (x, 17)
	lj_test_assert (tostringull (x) == "13853888353868189826")

	local x = ull (0x8416021, 0x7307451e)
	shrull (x, 47)
	lj_test_assert (tostringull (x) == "4226")

	local x = ull (0x9e3779b9, 0x7f4a7c15)
	shlull (x, 49)
	lj_test_assert (tostringull (x) == "17882105270427975680")

	local x = ull (0x9e3779b9, 0x7f4a7c15)
	shrull (x, 15)
	lj_test_assert (tostringull (x) == "347922205179540")

	local x = ull (0x9e3779b9, 0x7f4a7c15)
	lj_test_assert (divull (x, 2) == 1)
	lj_test_assert (tostringull (x) == "5700357409661599242")

	local x = ull (0x9e3779b9, 0x7f4a7c15)
	lj_test_assert (divull (x, 17) == 15)
	lj_test_assert (tostringull (x) == "670630283489599910")

	local x = ull (0x9e3779b9, 0x7f4a7c15)
	lj_test_assert (divull (x, 0x7fff) == 21333)
	lj_test_assert (tostringull (x) == "347932823246656")

	local x = ull (1024, 546633999)
	mulull (x, 64)
	lj_test_assert (tostringull (x) == "281509961286592")

	local x = ull (1024, 546633999)
	lj_test_assert (mulull (x, 0xffffffff) == 1024)
	lj_test_assert (tostringull (x) == "2347770749993551601")

	local x = ull (1024, 546633999)
	lj_test_assert (mulull (x, 0xffffaaaa) == 1024)
	lj_test_assert (tostringull (x) == "2251683482738776566")

	dtoull (x, 1.000000001 * 9.223372e18)
	lj_test_assert (tostringull (x) == "9223372009223372800")

	dtoull (x, -1.000000001 * 9.223372e18)
	lj_test_assert (tostringull (x) == "9223372064486178816")

	dtoull (x, -1.6168570900701e+18)
	lj_test_assert (tostringull (x) == "16829886983639451648")

	dtoull (x, -6.772123677161575 * 1034383538)
	lj_test_assert (tostringull (x) == "18446744066704578368")

	dtoull (x, -6.43123677161575 * 1034383538)
	lj_test_assert (tostringull (x) == "18446744067057186171")

	local x = ull (0xffffffff, 0xffffffff)
	local z = ull (0xffffffff, 0xffffffff)
	ashrull (x, 32)
	lj_test_assert (equalull (x, z))

	local x = ull (0xffffffff, 0xffffffff)
	local z = ull (0, 0xffffffff)
	shrull (x, 32)
	lj_test_assert (equalull (x, z))
end

mcl_levelgen.tostringull = tostringull
mcl_levelgen.ull = ull
mcl_levelgen.addull = addull
mcl_levelgen.addkull = addkull
mcl_levelgen.negull = negull
mcl_levelgen.subull = subull
mcl_levelgen.divull = divull
mcl_levelgen.mulull = mulull
mcl_levelgen.ashrull = ashrull
mcl_levelgen.shrull = shrull
mcl_levelgen.shlull = shlull
mcl_levelgen.rotlull = rotlull
mcl_levelgen.andull = andull
mcl_levelgen.xorull = xorull
mcl_levelgen.extull = extull
mcl_levelgen.extkull = extkull
mcl_levelgen.dtoull = dtoull
mcl_levelgen.stringtoull = stringtoull
mcl_levelgen.ltull = ltull

------------------------------------------------------------------------
-- General random-number generator facilities.
------------------------------------------------------------------------

local function sext (int)
	return band (int, 0x80000000) ~= 0 and UINT_MAX or 0
end

local mathsqrt = math.sqrt
local mathlog = math.log

local function marsaglia_polar_function (next_double)
	local spare = nil
	return function ()
		if spare then
			local v = spare
			spare = nil
			return v
		end

		local u, v, s
		repeat
			u = 2.0 * next_double () - 1.0
			v = 2.0 * next_double () - 1.0
			s = u * u + v * v
		until not (s >= 1.0 or s == 0.0)
		s = mathsqrt (-2.0 * mathlog (s) / s)
		spare = v * s
		return u * s
	end, function ()
		spare = nil
	end
end

------------------------------------------------------------------------
-- Minecraft-compatible JVM LCG.
-- https://maven.fabricmc.net/docs/yarn-1.21.5+build.1/net/minecraft/util/math/random/Random.html
-- https://maven.fabricmc.net/docs/yarn-1.21.5+build.1/net/minecraft/util/math/random/LocalRandom.html
------------------------------------------------------------------------

local MULTIPLIER = ull (5, 3740067437)
local SEED_MASK = ull (0xffff, 0xffffffff)

local function jvm_lcg (seed0)
	local seed, tmp = ull (seed0[2], seed0[1]), ull (0, 0)

	xorull (seed, MULTIPLIER)
	andull (seed, SEED_MASK)

	return function (nbits)
		tmp[1], tmp[2] = seed[1], seed[2]
		mulull (tmp, 0x5)
		shlull (tmp, 32)
		mulull (seed, 0xdeece66d)
		addull (seed, tmp)
		addkull (seed, 11)
		andull (seed, SEED_MASK)
		tmp[1], tmp[2] = seed[1], seed[2]
		-- https://bugs.mojang.com/browse/MC/issues/MC-239059
		ashrull (tmp, 48 - nbits)
		return tmp[1]
	end, seed
end

mcl_levelgen.jvm_lcg = jvm_lcg

function mcl_levelgen.jvm_random (seed)
	local fn, seed_storage = jvm_lcg (seed)
	local r24 = 1 / 0xffffff
	local r53 = 1 / 0x1fffffffffffff
	local scratch = ull (nil, nil)
	local scratch1 = ull (nil, nil)

	local function next_double (_)
		local ull = ull (0, fn (26))
		shlull (ull, 27)
		addkull (ull, fn (27))
		return (ull[2] * (UINT_MAX + 1) + ull[1]) * r53
	end
	local next_gaussian, reset_gaussian
		= marsaglia_polar_function (next_double)

	-- It is guaranteed that `next_integer' and `next_within' may
	-- safely be cached.
	return {
		next_long = function (self)
			local hi, lo = fn (32), fn (32)
			scratch[2] = hi
			scratch[1] = 0
			scratch1[2] = sext (lo)
			scratch1[1] = lo
			addull (scratch, scratch1)
			return scratch
		end,
		next_integer = function (self)
			return bor (fn (32), 0) -- Sign conversion only.
		end,
		next_within = function (self, y)
			if band (y, y - 1) == 0 then -- If power of 2.
				-- Use optimized routine.
				extkull (scratch, fn (31))
				extkull (scratch1, y)
				mul2ull (scratch, scratch1)
				ashrull (scratch, 31)
				return scratch[1]
			end

			local n, m
			n = fn (31)
			m = n % y
			while (n - m + (y - 1)) >= 0x7fffffff do
				n = fn (31)
				m = n % y
			end
			return m
		end,
		next_boolean = function (self)
			return fn (1) ~= 0
		end,
		next_float = function (self)
			return fn (24) * r24
		end,
		next_double = next_double,
		fork = function (self)
			return mcl_levelgen.jvm_random (self:next_long ())
		end,
		fork_into = function (self, other)
			other:reseed (self:next_long ())
		end,
		consume = function (self, n)
			for i = 1, n do
				fn (32)
			end
		end,
		reseeding_data = {
			false, seed_storage,
		},
		reseed = function (self, seed)
			local storage = seed_storage
			storage[1] = seed[1]
			storage[2] = seed[2]
			xorull (storage, MULTIPLIER)
			andull (storage, SEED_MASK)
			reset_gaussian ()
		end,
		next_gaussian = next_gaussian,
		reset_gaussian = reset_gaussian,
	}, seed_storage
end

if true then
	local source
		= mcl_levelgen.jvm_random (ull (0, 1000))
	local source_1
		= mcl_levelgen.jvm_random (ull (0, 1000))
	local other = mcl_levelgen.jvm_random (ull (0, 0))

	for i = 1, 100 do
		local fork = source:fork ()
		source_1:fork_into (other)

		for i = 1, 1000 do
			local a, b = fork:next_integer (3000), other:next_integer (3000)
			lj_test_assert (a == b)
		end
	end
end

------------------------------------------------------------------------
-- Biome position randomization.
------------------------------------------------------------------------

-- Simple LCG.
local MULTIPLIER = ull (0x5851f42d, 0x4c957f2d)
local INCREMENT = ull (0x14057b7e, 0xf767814f)

local tmp = ull (0, 0)

local function lcj_next (seed, increment)
	tmp[1] = seed[1]
	tmp[2] = seed[2]

	-- seed = (seed * (seed * MULTIPLIER + INCREMENT))
	mul2ull (tmp, MULTIPLIER)
	addull (tmp, INCREMENT)
	mul2ull (seed, tmp)
	addull (seed, increment)
end

if detect_luajit () then
	local str = [[
	local band = bit.band
	local rshift = bit.rshift
	local tonumber = tonumber
	local function lcj_next (seed, increment)
		local cseed = 0x100000000ull * seed[2] + seed[1]
		local increment
			= 0x100000000ull * increment[2] + increment[1]
		cseed = cseed * (cseed * 0x5851f42d4c957f2dull
				 + 0x14057b7ef767814full)
			+ increment
		seed[1] = tonumber (band (cseed, 0xffffffff))
		seed[2] = tonumber (rshift (cseed, 32))
	end
	return lcj_next
]]
	local fn = loadstring (str)
	lcj_next = fn ()
end

mcl_levelgen.lcj_next = lcj_next

-- luacheck: push ignore 511
if true then
	local seed = ull (99012, 99374)
	local incr = ull (339487593, 444335790)
	local function test (seed, value)
		if false then
			print (seed)
		else
			lj_test_assert (seed == value)
		end
	end
	-- print ("seed: ", tostringull (seed), "incr: ", tostringull (incr))
	lcj_next (seed, incr)
	test (tostringull (seed), "226211238292676308")
	lcj_next (seed, incr)
	test (tostringull (seed), "6872378287299025514")
	lcj_next (seed, incr)
	test (tostringull (seed), "17378588871388729976")
	lcj_next (seed, incr)
	test (tostringull (seed), "1242224386663429366")
	lcj_next (seed, incr)
	test (tostringull (seed), "1805386566417395244")
	lcj_next (seed, incr)
	test (tostringull (seed), "12805274662464243346")
	lcj_next (seed, incr)
	test (tostringull (seed), "14060706522678048432")
	lcj_next (seed, incr)
	test (tostringull (seed), "12111425423540952062")
	lcj_next (seed, incr)
	test (tostringull (seed), "7280341539614422212")
	lcj_next (seed, incr)
	test (tostringull (seed), "7655099306983539706")

	local seed1 = ull (0, 0)
	stringtoull (seed1, "2520521153677540398")
	stringtoull (incr, "162")
	lcj_next (seed1, incr)
	test (tostringull (seed1), "14919993831747797192")
end
-- luacheck: pop
