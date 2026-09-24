-- pex: active.onactivate 1eb4f7c4
-- pex: inactive.onactivate e10edb62
-- The resonator went busy, opened or closed and waited for Trans01/Trans02 before activating its
-- linked ref. The event now does that; the two names say which way it went.
local rt = require('skymod.rt')

return function(C)
	local Inactive, Active, Busy = rt.state(C, "Inactive"), rt.state(C, "Active"), rt.state(C, "Busy")

	local function move(self, anim, done)
		self:GotoState("Busy")
		self:RegisterForAnimationEvent(self, done)
		self:PlayAnimation(anim)
	end

	function Inactive:OnActivate(akActivator) move(self, "Open", "Trans01") end
	function Active:OnActivate(akActivator) move(self, "Close", "Trans02") end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or (asEventName ~= "Trans01" and asEventName ~= "Trans02") then return end
		self:GetLinkedRef(self.LinkKeyword):Activate(self)
		self:GotoState(asEventName == "Trans01" and "Active" or "Inactive")
	end
end
