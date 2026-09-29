-- pex: waiting.onactivate 79d7964e
-- pex: disarmed.onactivate 7e558b84
-- The trap's loot asked to disarm (button 1) or rearm; the pick flips trapself's own state along
-- with this one's. OnTick in each state reads the pick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)
	local Waiting, Disarmed = rt.state(C, "waiting"), rt.state(C, "Disarmed")

	function Waiting:OnActivate(TriggerRef)
		if TriggerRef ~= rt.static("Game", "GetPlayer") then return end
		self.asking = true
		self.DisarmTrapMessage:Show()
	end

	function Waiting:OnTick()
		if not self.asking then return end
		local iButton = self.DisarmTrapMessage:Answer()
		if iButton < 0 then return self.DisarmTrapMessage:Show() end
		self.asking = false
		if iButton ~= 1 then return end
		self.trapself:GotoState("Disarmed")
		self:GotoState("Disarmed")
	end

	function Disarmed:OnActivate(TriggerRef)
		if TriggerRef ~= rt.static("Game", "GetPlayer") then return end
		self.asking = true
		self.RearmTrapMessage:Show()
	end

	function Disarmed:OnTick()
		if not self.asking then return end
		local iButton = self.RearmTrapMessage:Answer()
		if iButton < 0 then return self.RearmTrapMessage:Show() end
		self.asking = false
		if iButton ~= 1 then return end
		self.trapself:GotoState("Idle")
		self:GotoState("waiting")
	end
end
