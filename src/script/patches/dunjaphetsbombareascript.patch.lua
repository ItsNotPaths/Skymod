-- pex: continuebombing 04fd92a7
-- continueBombing called itself through Wait(3): every 3s, stop if the player has left, else go
-- on. The recursion becomes a repeating timer in a new state "Bombing". A second start while one
-- run is under way (the recursive Papyrus chain, or a fresh StartBombing) is dropped.
local rt = require('skymod.rt')

local PERIOD = 3.0

return function(C)
	C.__vars.bombWait = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Bombing = rt.state(C, "Bombing")

	function C:continueBombing()
		if self:GetState() == "Bombing" then return end
		self.bombWait = PERIOD
		self:GotoState("Bombing")
	end

	function Bombing:OnTick()
		if self.bombWait > 0 then return end
		if self.inTrigger then
			self.bombWait = self.bombWait + PERIOD
			return
		end
		self:GotoState("")
		self:stopBombing()
	end
end
