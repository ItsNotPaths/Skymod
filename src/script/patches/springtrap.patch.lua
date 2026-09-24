-- pex: active.onbeginstate 035eb792
-- Entering Active fired the spring and waited for "reset" in DoNothing. The event now ends it.
local rt = require('skymod.rt')

return function(C)
	local Active, DoNothing = rt.state(C, "Active"), rt.state(C, "DoNothing")

	function Active:OnBeginState()
		self:GotoState("DoNothing")
		self.pressEffect:Fire(self)
		self:Activate(self)
		local who = self.lastTriggerRef
		local springImpulse = 30 * who:GetMass()
		if rt.cast(who, "Actor") then
			self:PushActorAway(rt.cast(who, "Actor"), 10)
		else
			who:ApplyHavokImpulse(0.0, 0.0, 1.0, springImpulse)
		end
		self:RegisterForAnimationEvent(self, "reset")
		self:PlayAnimation("trigger")
	end

	function DoNothing:OnAnimationEvent(akSource, asEventName)
		if akSource == self and asEventName == "reset" then self:GotoState("Inactive") end
	end
end
