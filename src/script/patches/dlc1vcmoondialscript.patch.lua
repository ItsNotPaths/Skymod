-- pex: setopen 4b7f5a9e
-- SetOpen waited while the dial was busy, then played Open and waited for "Done". Only SetOpen
-- makes it busy, so a second call now is dropped; the event finishes the opening.
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
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation("Open")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource == self and asEventName == "Done" then opened(self) end
	end
end
