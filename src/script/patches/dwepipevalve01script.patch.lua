-- pex: waiting.onactivate 1346fbcc
-- The valve blocked activation, turned and waited for Trans01/Trans02, then flipped. Now the event
-- ends the turn; `turning` drops an activation during it (Papyrus ran it in parallel).
local rt = require('skymod.rt')

return function(C)
	C.__vars.turning = rt.bool(false)
	local Waiting = rt.state(C, "Waiting")

	function Waiting:OnActivate(triggerRef)
		if self.turning then return end
		self.turning = true
		self:BlockActivation(true)
		self:RegisterForAnimationEvent(self, self.flip and "Trans02" or "Trans01")
		self:PlayAnimation(self.flip and "trigger02" or "trigger01")
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if not self.turning or akSource ~= self or asEventName ~= (self.flip and "Trans02" or "Trans01") then return end
		self.turning = false
		self.flip = not self.flip
		self:BlockActivation(false)
	end
end
