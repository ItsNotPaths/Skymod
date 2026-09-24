-- pex: openexitdoor 3b3586c4
-- OpenExitDoor(bOpen, bWaitForPlayerToExitTrigger=true) polled every 1s, only when closing and
-- told to wait, until the player left the exit trigger (or entered the party trigger), then
-- locked and set the door open state. Now a shared desired-state field settled in OnTick; a
-- second call while waiting updates it instead of being dropped, since it is a value (the wanted
-- open state), not a one-shot action.
local rt = require('skymod.rt')

return function(C)
	C.__vars.doorWaiting = rt.bool(false)
	C.__vars.doorOpen = rt.bool(false)
	C.__vars.TickRate = rt.float(1.0) -- the original polled with Wait(1)
	rt.params(C, "OpenExitDoor", { { "bOpen" }, { "bWaitForPlayerToExitTrigger", true } })

	local function finish(self, bOpen)
		self.Alias_PartyExitDoor:GetReference():Lock(not bOpen)
		self.Alias_PartyExitDoor:GetReference():SetOpen(bOpen)
	end

	function C:OpenExitDoor(bOpen, bWaitForPlayerToExitTrigger)
		if not bOpen and bWaitForPlayerToExitTrigger
			and self.PlayerInExitPartyTrigger and not self.PlayerInPartyTrigger then
			self.doorWaiting = true
			self.doorOpen = bOpen
			return
		end
		self.doorWaiting = false
		finish(self, bOpen)
	end

	function C:OnTick()
		if not self.doorWaiting then return end
		if self.PlayerInExitPartyTrigger and not self.PlayerInPartyTrigger then return end
		self.doorWaiting = false
		finish(self, self.doorOpen)
	end
end
