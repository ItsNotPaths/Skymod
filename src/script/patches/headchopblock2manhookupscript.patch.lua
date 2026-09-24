-- pex: onupdate db9ed9a8
-- HeadChopBlock2ManHookupScript.OnUpdate without waits: Wait(5), the idle, Wait(2), clean up.
-- Both branches of the player test wait 2 s, so the branch only decides whether the idle plays.
local rt = require('skymod.rt')

local Chop = rt.sequence("Idle", "Settling", "Chopping")

local function T(self, s) rt.static("Debug", "Trace", "headchop " .. tostring(self.form) .. ": " .. s) end

return function(C)
	C.__vars.chop = Chop.Idle
	C.__vars.chopClock = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	function C:OnUpdate()
		self:UnregisterForUpdate()
		if self.executioneeActor == rt.None or self.executionerActor == rt.None then return end
		if self.chop ~= Chop.Idle then return end
		self.chop, self.chopClock = Chop.Settling, 5.0
		T(self, "CHOPPING START, idle in 5 s")
	end

	local Chopping = rt.state(C, "chopping")
	function Chopping:OnTick()
		if self.chop == Chop.Idle or self.chopClock > 0 then return end
		if self.chop == Chop.Settling then
			if not self.executioneeActor:AddDependentAnimatedObjectReference(self.executionerActor) then
				rt.static("Debug", "Notification", "dependence broken.")
			end
			local victim = rt.cast(self.executioneeActor, "actor")
			if victim ~= rt.static("Game", "GetPlayer") and not victim:PlayIdle(self.animIdle) then
				T(self, "play idle failed")
			end
			self.chop = Chop.Chopping
			self.chopClock = self.chopClock + 2.0
			T(self, "idle played on " .. tostring(victim) .. ", clean up in 2 s")
		else
			self.executioneeActor:RemoveDependentAnimatedObjectReference(self.executionerActor)
			self.executioneeActor = rt.None
			self.chop = Chop.Idle
			T(self, "CHOPPING END")
			self:GotoState("readyToChop")
		end
	end
end
