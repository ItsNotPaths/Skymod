-- pex: dismiss 2cd1fe0a f40e4040
-- pex: finishwaiting 464a5349 b5786f89
-- FinishWaiting re-evaluated Serana's package once Dismiss (2 s DismissFollower) returned. It now
-- waits for DialogueFollower to leave "Dismissing" (`packageOwed`). Dismiss is unchanged: its
-- SetPlayerTeammate(false) repeats what DismissFollower already did at once.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.packageOwed = rt.bool(false) -- Serana's package is not re-evaluated since the dismissal
	local split_tick = C.__fn.ontick

	function C:FinishWaiting()
		self.IsWaiting = false
		self.RNPC:GetActorReference():SetAV("WaitingForPlayer", 0)
		if self.CanBeDismissed then
			self:DisengageFollowBehavior()
			self:Dismiss()
			self.packageOwed = true
			self:OnTick()
		else
			self.RNPC:GetActorReference():EvaluatePackage() -- no dismissal started, so no wait either
		end
	end

	function C:OnTick()
		split_tick(self)
		if not self.packageOwed then return end
		if rt.cast(self.DialogueFollower, "DialogueFollowerScript"):GetState() == "Dismissing" then return end
		self.packageOwed = false
		self.RNPC:GetActorReference():EvaluatePackage()
	end
end
