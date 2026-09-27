-- pex: ondeath a2076999
-- OnDeath waited a second at a time until the garrison quest finished its first count, then reported
-- the death. The wait is now a state entered only then, so a soldier ticks only while it waits.
local rt = require('skymod.rt')

return function(C)
	C.__fn.ontick = nil
	local Waiting = rt.state(C, "WaitingForCount")

	-- true once the quest took the death
	local function report(self)
		local observers = rt.cast(self:GetOwningQuest(), "cwgarrisonobserverscript")
		if not rt.get(observers, "DoneSettingInitialCount") then return false end
		rt.call(observers, "ProcessSoldierDeath", self:GetActorReference())
		return true
	end

	function C:OnDeath(akKiller)
		if report(self) then return end
		self.vars["ondeath.t"] = 1.0
		self:GotoState("WaitingForCount")
	end

	function Waiting:OnDeath(akKiller) end

	function Waiting:OnTick()
		if self.vars["ondeath.t"] > 0 then return end
		if report(self) then
			self.vars["ondeath.t"] = rt.None
			self:GotoState("")
		else
			self.vars["ondeath.t"] = 1.0
		end
	end
end
