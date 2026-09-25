-- pex: setopen c64b864b
-- SetOpen waited while the door was busy, then (if closed) played openAnim and waited for
-- openEvent; the door always ended open and done. A call while busy therefore changes nothing:
-- the run under way already ends open. Now the event ends the opening.
local rt = require('skymod.rt')

return function(C)
	local Busy = rt.state(C, "busy")

	local function opened(self)
		self.isOpen = true
		self:GotoState("done")
		self.isAnimating = false
	end

	function C:SetOpen(abOpen)
		if self:GetState() == "busy" then return end
		self.isAnimating = true
		if self.isOpen then return opened(self) end
		self:GotoState("busy")
		self:RegisterForAnimationEvent(self, self.openEvent)
		self:PlayAnimation(self.openAnim)
	end
	rt.params(C, "SetOpen", { { "abOpen", true } })

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource == self and asEventName == self.openEvent then opened(self) end
	end
end
