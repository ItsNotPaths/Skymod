-- pex: waitingtobeopened.onopen 336a8c5a
-- OnOpen removed each present prisoner from the faction, waited 0.1s, then evaluated its package,
-- one prisoner at a time. Now a walking index plus one timer; each tick finishes the previous
-- prisoner's EvaluatePackage and starts the next one's RemoveFromFaction in the same step.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.t = rt.timer(0.0)
	C.__vars.pi = rt.int(-1)
	local Waiting = rt.state(C, "WaitingToBeOpened")

	local function prisoners(self)
		return { self.prisoner01, self.prisoner02, self.prisoner03, self.prisoner04, self.prisoner05, self.prisoner06, self.prisonerlink }
	end

	function Waiting:OnOpen(triggerRef)
		self.pi = 0
		self.t = 0
		self:OnTick()
	end

	function Waiting:OnTick()
		if self.pi < 0 then return end
		if self.t > 0 then return end
		local list = prisoners(self)
		rt.static("Debug", "Trace", string.format("DEBUG pi=%s t=%s list1=%s list1type=%s #list=%s", tostring(self.pi), tostring(self.t), tostring(list[1]), type(list[1]), #list))
		if self.pi > 0 then
			local p = rt.cast(list[self.pi], "actor")
			p:EvaluatePackage()
		end
		while self.pi < #list do
			self.pi = self.pi + 1
			local p = list[self.pi]
			if p then
				rt.cast(p, "actor"):RemoveFromFaction(self.dunprisonerfaction)
				self.t = self.t + 0.1
				return
			end
		end
		self.pi = -1
		self:GotoState("AlreadyOpened")
	end
end
