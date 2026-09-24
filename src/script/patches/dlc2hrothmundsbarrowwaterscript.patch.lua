-- pex: movewater 84fd5f27
-- MoveWater ran a straight-line sequence of waits down (11 steps) or up (11 steps), picked by
-- bMoveWaterDown/bCurrentlyUp, then fell into the OTHER guard at the end (Papyrus has two
-- sequential if-blocks, not an else). Now a stopwatch plus a step index walk the same list in
-- OnTick; the tail calls MoveWater() again, which is a no-op unless the flags changed mid-run.
local rt = require('skymod.rt')

local function shake(self, amount) rt.static("Game", "ShakeCamera", self, amount, 2.0) end

local function translate_to(self, what, to)
	what:TranslateTo(to:GetPositionX(), to:GetPositionY(), to:GetPositionZ(),
		to:GetAngleX(), to:GetAngleY(), to:GetAngleZ(), 40.0)
end

local function start_rumble(self)
	self.rumbleID = self.QSTUstengravRumble2DLPM:Play(self)
	self:RampRumble(1.0, 10, 1600.0)
end

local function ring(self, i) return self["WaterfallRing0" .. i] end
local function ring_start(self, i) return self["WaterfallRingStart0" .. i] end
local function ring_end(self, i) return self["WaterfallRingEnd0" .. i] end

-- Explicit [N] keys throughout: this Lua fork is 0-based for positional { a, b } literals, and
-- these lists are walked by a 1-based step field.
local DOWN_T = { [1] = 0, [2] = 1, [3] = 3, [4] = 4, [5] = 5, [6] = 6, [7] = 7, [8] = 8, [9] = 9, [10] = 10, [11] = 11 }
local DOWN = {
	[1] = function(self) start_rumble(self); shake(self, 0.3) end,
	[2] = function(self) translate_to(self, self.WaterDynamic, self.WaterLower) end,
	[3] = function(self) shake(self, 0.4) end,
	[4] = function(self) self.LightMarker01:EnableNoWait() end,
	[5] = function(self) shake(self, 0.4) end,
	[6] = function(self) self.LightMarker02:EnableNoWait() end,
	[7] = function(self) shake(self, 0.4) end,
	[8] = function(self) self.LightMarker03:EnableNoWait() end,
	[9] = function(self) shake(self, 0.3) end,
	[10] = function(self) self.LightMarker04:EnableNoWait() end,
	[11] = function(self)
		rt.static("Sound", "StopInstance", self.rumbleID)
		shake(self, 0.2)
		self.bCurrentlyMoving = false
		self.bCurrentlyUp = false
		self:MoveWater() -- falls through to the Up guard, as Papyrus's second if does
	end,
}

local UP_T = { [1] = 0, [2] = 1, [3] = 2, [4] = 3, [5] = 4, [6] = 6, [7] = 8, [8] = 10, [9] = 12, [10] = 14, [11] = 15 }
local UP = {
	[1] = function(self)
		for i = 1, 4 do ring(self, i):MoveTo(ring_start(self, i)) end
		for i = 1, 4 do ring(self, i):EnableNoWait() end
		self.LightMarker04:DisableNoWait()
	end,
	[2] = function(self)
		self.WaterfallMarker01:EnableNoWait()
		self.LightMarker03:DisableNoWait()
	end,
	[3] = function(self) self.LightMarker02:DisableNoWait() end,
	[4] = function(self)
		self.LightMarker01:DisableNoWait()
		start_rumble(self)
		shake(self, 0.3)
	end,
	[5] = function(self)
		for i = 1, 4 do translate_to(self, ring(self, i), ring_end(self, i)) end
		translate_to(self, self.WaterDynamic, self.WaterUpper)
	end,
	[6] = function(self) shake(self, 0.4) end,
	[7] = function(self) shake(self, 0.4) end,
	[8] = function(self) shake(self, 0.4) end,
	[9] = function(self) shake(self, 0.3) end,
	[10] = function(self)
		self.WaterfallMarker01:DisableNoWait(false)
		for i = 1, 4 do ring(self, i):DisableNoWait(false) end
		rt.static("Sound", "StopInstance", self.rumbleID)
		shake(self, 0.2)
	end,
	[11] = function(self)
		self.bCurrentlyMoving = false
		self.bCurrentlyUp = true
		if self.bMoveWaterDown then self:MoveWater() end
	end,
}

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.sw = rt.stopwatch(0.0)
	C.__vars.step = rt.int(0) -- 0 idle, else 1-based index into the running direction's list
	C.__vars.rumbleID = rt.int(0)

	local function run_due(self)
		while self.bCurrentlyMoving do
			local seq, ts = self.bCurrentlyUp and DOWN or UP, self.bCurrentlyUp and DOWN_T or UP_T
			local fn = seq[self.step]
			if not fn or self.sw < ts[self.step] then return end
			self.step = self.step + 1
			fn(self)
		end
	end

	local function start(self)
		self.bCurrentlyMoving = true
		self.sw = 0.0
		self.step = 1
		run_due(self)
	end

	function C:MoveWater()
		if self.bMoveWaterDown and self.bCurrentlyUp and not self.bCurrentlyMoving then
			return start(self)
		end
		if not self.bMoveWaterDown and not self.bCurrentlyUp and not self.bCurrentlyMoving
			and not self.bStopMovingWaterUp then
			start(self)
		end
	end

	function C:OnTick()
		if not self.bCurrentlyMoving then return end
		run_due(self)
	end
end
