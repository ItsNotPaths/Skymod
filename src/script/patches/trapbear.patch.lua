-- pex: closed.onactivate 0e6b089f
-- pex: open.onactivate e38377cb
-- pex: open.ontriggerenter 75b86ddc
-- Snapping (a trigger or an activation) waited for Trans01 in Busy; resetting waited for Trans02
-- in Closed. The events now end both; `opening` says a reset is under way.
local rt = require('skymod.rt')

return function(C)
	C.__vars.opening = rt.bool(false)
	local Closed, Open, Busy = rt.state(C, "Closed"), rt.state(C, "Open"), rt.state(C, "Busy")

	function Closed:OnActivate(TriggerRef)
		if self.opening then return end -- a run happens once
		self.opening = true
		self:RegisterForAnimationEvent(self, "Trans02")
		self:PlayAnimation("Reset01")
	end

	function Closed:OnAnimationEvent(akSource, asEventName)
		if not self.opening or akSource ~= self or asEventName ~= "Trans02" then return end
		self.opening = false
		self:GotoState("Open")
	end

	function Open:OnTriggerEnter(TriggerRef)
		if not self:checkPerks(TriggerRef) then return end
		self:RegisterForAnimationEvent(self, "Trans01")
		self:PlayAnimation("Trigger01")
		self.hitBase:GotoState("CanHit")
		self:GotoState("Busy")
	end

	function Open:OnActivate(TriggerRef)
		self:GotoState("Busy")
		self.hitBase:GotoState("CannotHit")
		self:RegisterForAnimationEvent(self, "Trans01")
		self:PlayAnimation("Trigger01")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Trans01" then return end
		self.hitBase:GotoState("CannotHit")
		self:GotoState("Closed")
	end
end
