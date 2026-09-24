-- pex: onupdate 9d9a64ba
-- OnUpdate without waits: Wait(0.5), AddDependent + idle(s), then Wait(2) or Wait(5) for the
-- player, then clean up.
local rt = require('skymod.rt')

local Chop = rt.sequence("Idle", "Settling", "Chopping")

local function T(self, s) rt.static("Debug", "Trace", "headchop " .. tostring(self.form) .. ": " .. s) end

return function(C)
	C.__vars.chop = Chop.Idle
	C.__vars.chopClock = rt.timer(0.0)
	C.__vars.isPlayer = rt.bool(false)
	C.__vars.TickRate = rt.float(0.1)

	function C:OnUpdate()
		if self.executioneeactor == rt.None or self.executioneractor == rt.None then return end
		if self.chop ~= Chop.Idle then return end
		self.chop, self.chopClock = Chop.Settling, 0.5
		T(self, "CHOPPING START, settling in 0.5 s")
	end

	local Chopping = rt.state(C, "chopping")
	function Chopping:OnTick()
		if self.chop == Chop.Idle or self.chopClock > 0 then return end
		if self.chop == Chop.Settling then
			local ok1 = self.executioneeactor:AddDependentAnimatedObjectReference(self.executioneractor)
			local ok2 = self.executioneeactor:AddDependentAnimatedObjectReference(self.executionguardactor)
			if not ok1 or not ok2 then rt.static("Debug", "Notification", "dependence broken.") end
			local victim = rt.cast(self.executioneeactor, "actor")
			local executioner = rt.cast(self.executioneractor, "actor")
			self.isPlayer = victim == rt.static("Game", "GetPlayer")
			if self.isPlayer then
				if not executioner:PlayIdle(self.playeranimidle) then T(self, "executioner play idle failed") end
				if not victim:PlayIdle(self.playeranimidle) then T(self, "player play idle failed") end
				self.chop, self.chopClock = Chop.Chopping, 5.0
			else
				if not victim:PlayIdle(self.animidle) then T(self, "play idle failed") end
				self.chop, self.chopClock = Chop.Chopping, 2.0
			end
			T(self, "idle played, clean up next")
		else
			if self.isPlayer then self.mq101:SetStage(98) end
			self.executioneeactor:RemoveDependentAnimatedObjectReference(self.executioneractor)
			self.executioneeactor:RemoveDependentAnimatedObjectReference(self.executionguardactor)
			self.executioneeactor = rt.None
			self.chop = Chop.Idle
			T(self, "CHOPPING END")
			self:GotoState("readyToChop")
		end
	end
end
