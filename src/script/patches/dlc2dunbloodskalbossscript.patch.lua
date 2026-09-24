-- pex: ondeath 4e411f15
-- The Bloodskal boss's death opened the exit portcullis and, once it had opened, the entrance.
-- Now OnTick in Opening waits while the exit animates.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Opening = rt.state(C, "Opening")

	function C:OnDeath(akKiller)
		if self.killedOnce then return end
		self.killedOnce = true
		self.ExitDoor = self.DLC2BloodskalBossExitPortullis
		self.EntranceDoor = self.DLC2BloodskalBossEntrancePortcullis
		self.ExitDoor:SetOpen(true)
		self:GotoState("Opening")
	end

	function Opening:OnTick()
		if self.ExitDoor.isAnimating then return end
		self:GotoState("")
		self.EntranceDoor:SetOpen(true)
	end
end
