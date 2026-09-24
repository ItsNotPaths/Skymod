-- pex: _open 513ed873
-- pex: opened.onactivate 512e8758
-- _Open and a press played an animation and waited for "Done" in Busy. The event now ends Busy;
-- both end in Opened, whose OnBeginState picks up a close asked for meanwhile.
local rt = require('skymod.rt')

return function(C)
	local Opened, Busy = rt.state(C, "Opened"), rt.state(C, "Busy")

	local function play(self, anim)
		self:GotoState("Busy")
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation(anim)
	end

	function C:_Open()
		self.openNext = false
		play(self, "Open")
	end

	function Opened:OnActivate(akActivator)
		if akActivator == rt.static("Game", "GetPlayer") then play(self, "Trigger01") end
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource == self and asEventName == "Done" then self:GotoState("Opened") end
	end
end
