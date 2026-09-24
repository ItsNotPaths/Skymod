-- pex: power.onactivate 1662df5b 8c99e836
-- With power, the room played Stage1 and waited for Ready (done), then showed the book, played
-- Stage2 and set stage 550. If the cell unloaded mid-animation the wait returned false: the
-- same steps ran without going to done. Now Ready, or OnCellDetach, finishes it.
local rt = require('skymod.rt')

return function(C)
	local Power, Animating = rt.state(C, "power"), rt.state(C, "animating")

	local function finish(self)
		self:GetLinkedRef():Enable()
		self:PlayAnimation("Stage2")
		self.DLC2MQ04:SetStage(550)
	end

	function Power:OnActivate(akActionRef)
		if not self.DLC2MQ04.bReadingRoomPowered then return end
		self:GotoState("animating")
		self:RegisterForAnimationEvent(self, "Ready")
		if not self:PlayAnimation("Stage1") then finish(self) end
	end

	function Animating:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Ready" then return end
		self:GotoState("done")
		finish(self)
	end

	function Animating:OnCellDetach()
		self:UnregisterForAnimationEvent(self, "Ready")
		finish(self)
	end
end
