-- pex: attacktargetarea 7a928277
-- pex: attackwithfullsweep 5bb09da8
-- Both activated a tentacle chain link, waited attackTimer, walked to GetLinkedRef(), and
-- repeated until the chain ran out. AttackWithFullSweep does that for all six chains in a row.
-- Now OnTick walks the same chain(s) on a timer; atkChainIdx is 0 for the single-target attack
-- and 1..6 while sweeping, so both share one tick function.
local rt = require('skymod.rt')

local function full_start(self, i) return self["DLC2MQBossTentacleChainStart00" .. i] end

local function tick_attack(self)
	if self.atkT > 0 or not self.atkActive then return end
	if not self.atkNext then
		if self.atkChainIdx == 0 or self.atkChainIdx >= 6 then
			self.atkActive = false
			return self:GotoState("Waiting")
		end
		self.atkChainIdx = self.atkChainIdx + 1
		self.atkNext = full_start(self, self.atkChainIdx)
	end
	self.atkNext:Activate(self)
	self.atkT = self.atkT + self.attackTimer
	self.atkNext = self.atkNext:GetLinkedRef()
end

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.atkActive = rt.bool(false)
	C.__vars.atkNext = rt.form("ObjectReference")
	C.__vars.atkChainIdx = rt.int(0)
	C.__vars.atkT = rt.timer(0.0)

	function C:AttackTargetArea()
		local start
		if not self.clockwise then
			-- positional { a, b } is 0-based in this Lua fork, matching targetArea's own 0-based range
			local starts = { self.DLC2MQBossTentacleChainStartCenter, self.DLC2MQBossTentacleChainStart001,
				self.DLC2MQBossTentacleChainStart002, self.DLC2MQBossTentacleChainStart003,
				self.DLC2MQBossTentacleChainStart004, self.DLC2MQBossTentacleChainStart005,
				self.DLC2MQBossTentacleChainStart006 }
			start = starts[self.targetArea]
		end
		-- clockwise true: Papyrus itself does nothing here ("NEED to do other attack here")
		self.targetArea = 0
		if not start then return self:GotoState("Waiting") end
		self.atkChainIdx = 0
		self.atkNext = start
		self.atkActive = true
		self.atkT = 0.0
		self:OnTick()
	end

	function C:AttackWithFullSweep()
		if self.clockwise then return self:GotoState("Waiting") end
		self.atkChainIdx = 1
		self.atkNext = full_start(self, 1)
		self.atkActive = true
		self.atkT = 0.0
		self:OnTick()
	end

	function C:OnTick() tick_attack(self) end
end
