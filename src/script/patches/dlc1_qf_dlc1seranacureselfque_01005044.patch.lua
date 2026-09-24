-- pex: fragment_4 2d850897
-- Fragment_4 re-evaluated Serana's package once MM.Dismiss (2 s DismissFollower) returned. It now
-- waits for DialogueFollower to leave "Dismissing" (`packageOwed`), beside the split Fragment_3 tick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.packageOwed = rt.bool(false) -- Serana's package is not re-evaluated since the dismissal
	local split_tick = C.__fn.ontick

	function C:Fragment_4()
		self.MM:Dismiss()
		self.packageOwed = true
		self:OnTick()
	end

	function C:OnTick()
		split_tick(self)
		if not self.packageOwed then return end
		if rt.cast(self.MM.DialogueFollower, "DialogueFollowerScript"):GetState() == "Dismissing" then return end
		self.packageOwed = false
		self.Alias_Serana:GetActorRef():EvaluatePackage()
	end
end
