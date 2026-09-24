-- pex: pulledposition.onactivate dd080df7
-- The lever activated its target, pushed (waiting for FullPushedUp), waited fDelay, activated it
-- again, pulled (waiting for FullPulledDown), and after 0.5 s re-enabled the blocker. Now the two
-- events and two timers walk those steps in busy.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Pushing", "Holding", "Pulling", "Blocking")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Busy = rt.state(C, "busy")

	rt.state(C, "pulledPosition").OnActivate = function(self, triggerRef)
		local sister = self:GetLinkedRef(self.linkSisterSwitch)
		if sister and sister:GetState() == "busy" then return end -- the other switch is busy: act busy too
		self:Activate(self, true)
		if self.blocker then self.blocker:Disable() end
		self:GotoState("busy")
		self.step = S.Pushing
		self:RegisterForAnimationEvent(self, "FullPushedUp")
		self:RegisterForAnimationEvent(self, "FullPulledDown")
		self:PlayAnimation("FullPush")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.step == S.Pushing and asEventName == "FullPushedUp" then
			self.step = S.Holding
			self.t = self.fDelay
		elseif self.step == S.Pulling and asEventName == "FullPulledDown" then
			if not self.blocker then
				self.step = S.Idle
				return self:GotoState("pulledPosition")
			end
			self.step = S.Blocking
			self.t = 0.5
		end
	end

	function Busy:OnTick()
		if self.t > 0 then return end
		if self.step == S.Holding then
			self.step = S.Pulling
			self:Activate(self, true)
			self:PlayAnimation("FullPull")
		elseif self.step == S.Blocking then
			self.step = S.Idle
			self.blocker:Enable()
			self:GotoState("pulledPosition")
		end
	end
end
