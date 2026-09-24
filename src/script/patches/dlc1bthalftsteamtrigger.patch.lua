-- pex: waitingforhit.onhit b8a87dd8
-- The first hit opened the valve, waited for "done" and then activated the linked steam. The
-- event now activates it, in the BeenHit state the hit left it in.
local rt = require('skymod.rt')

return function(C)
	C.__vars.vented = rt.bool(false)
	local Waiting, BeenHit = rt.state(C, "WaitingForHit"), rt.state(C, "BeenHit")

	function Waiting:OnHit(akAggressor, akSource, akProjectile, abPowerAttack, abSneakAttack, abBashAttack, abHitBlocked)
		self:GotoState("BeenHit")
		self:RegisterForAnimationEvent(self, "done")
		self:PlayAnimation("open")
	end

	function BeenHit:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "done" or self.vented then return end
		self.vented = true
		self:UnregisterForAnimationEvent(self, "done")
		self:GetLinkedRef(self.LinkKeyword):Activate(self)
	end
end
