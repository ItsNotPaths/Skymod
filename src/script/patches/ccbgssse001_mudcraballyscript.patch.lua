-- pex: trytoaddmudcrabally a940b11b
-- TryToAddMudcrabAlly waited while `working` was set. Every body that sets it also clears it
-- with no wait between, so no call ever sees it set: the wait loop is gone.
local rt = require('skymod.rt')

return function(C)
	function C:TryToAddMudcrabAlly(akTarget, akCaster)
		local aliases = self.crabAliases
		local n = rt.alen(aliases)
		if self.mudcrabAllyCount >= n then return rt.None end
		self.AnimalAllyFXS:Play(akTarget)
		akTarget:StopCombat()
		akCaster:StopCombat()
		self.mudcrabAllyCount = self.mudcrabAllyCount + 1
		akTarget:SetPlayerTeammate(true, false)
		for i = 0, n - 1 do
			local a = rt.aget(aliases, i)
			if not a:GetActorRef() then
				a:ForceRefTo(akTarget)
				return a
			end
		end
		return rt.None
	end
end
