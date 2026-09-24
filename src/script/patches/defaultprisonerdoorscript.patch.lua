-- pex: waitingtobeopened.onopen 336a8c5a
-- OnOpen removed each present prisoner from the faction, waited 0.1s, then evaluated its package,
-- one prisoner at a time. Now a walking index plus one timer; each tick finishes the previous
-- prisoner's EvaluatePackage and starts the next one's RemoveFromFaction in the same step.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.t = rt.timer(0.0)
	C.__vars.pi = rt.int(-1) -- the next prisoner to walk; -1: no walk under way
	C.__vars.evaluating = rt.form("Actor") -- the prisoner whose EvaluatePackage is due after its 0.1 s
	local Waiting = rt.state(C, "WaitingToBeOpened")

	local function prisoners(self)
		return { self.prisoner01, self.prisoner02, self.prisoner03, self.prisoner04, self.prisoner05, self.prisoner06, self.prisonerlink }
	end

	function Waiting:OnOpen(triggerRef)
		if self.pi >= 0 then return end -- a second open during the walk is dropped
		self.pi, self.t = 0, 0
		self:OnTick()
	end

	function Waiting:OnTick()
		if self.pi < 0 or self.t > 0 then return end
		if self.evaluating then
			rt.cast(self.evaluating, "actor"):EvaluatePackage()
			self.evaluating = rt.None
		end
		local list = prisoners(self)
		while self.pi < #list do
			local p = list[self.pi]
			self.pi = self.pi + 1
			if p then
				rt.cast(p, "actor"):RemoveFromFaction(self.dunprisonerfaction)
				self.evaluating = p
				self.t = self.t + 0.1
				return
			end
		end
		self.pi = -1
		self:GotoState("AlreadyOpened")
	end
end
