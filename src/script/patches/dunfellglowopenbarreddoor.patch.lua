-- pex: ontrigger 7a06e951
-- Orthorn in the trigger raised the bar (waiting while it moved), then opened the exit. Now the
-- Opening state waits for the bar to leave busy, then opens the door.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Opening = rt.state(C, "Opening")

	function C:OnTrigger(obj)
		if self.OrthornRef:GetActorRef() ~= obj or self.exitDoor:GetOpenState() ~= 3 then return end
		rt.cast(self.bar, "doorBar"):SetBarPosition(true)
		self:GotoState("Opening")
		self:OnTick()
	end

	function Opening:OnTrigger(obj) end

	function Opening:OnTick()
		if rt.cast(self.bar, "doorBar"):GetState() == "busy" then return end
		self.exitDoor:SetOpen(true)
		self:GotoState("")
	end
end
