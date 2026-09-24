-- pex: offpos.onactivate 66bc708c
-- Activation rotated the door and waited for its snap event before flipping startOpen. The door is
-- another ref, so busyState polls its animation; an activation meanwhile is dropped.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Off, Busy = rt.state(C, "OFFpos"), rt.state(C, "busyState")

	local function anim(self) return self.startOpen and "RotateOpen" or "RotateClosed" end

	function Off:OnActivate(triggerRef)
		self:GotoState("busyState")
		self.myDoor:PlayAnimation(anim(self))
	end

	function Busy:OnTick()
		if self.myDoor:IsAnimRunning(anim(self)) then return end
		self.startOpen = not self.startOpen
		self:GotoState("OFFpos")
	end
end
