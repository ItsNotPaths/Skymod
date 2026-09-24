-- pex: waiting.ontriggerenter 8468f5e9
-- The smasher rose, held fDelayReturn, fell and rested fDelayReset, all inside one trigger event.
-- Now each rise and fall ends on its TransitionComplete event and each hold is a timer.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Rising", "Up", "Falling", "Down")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.victim = rt.form("ObjectReference") -- the down sound plays on whoever stepped in
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "Busy")

	function Waiting:OnTriggerEnter(akActionRef)
		if self.bPlayerOnly and akActionRef ~= self.PlayerREF then return end
		self:GotoState("Busy")
		self.victim = akActionRef
		self.ccBGS_TRP_TRPARFloorSmasherUp01SD:Play(akActionRef)
		self.step = S.Rising
		self:RegisterForAnimationEvent(self, "TransitionComplete")
		self:PlayAnimation("Stage2")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "TransitionComplete" then return end
		if self.step == S.Rising then
			self.step = S.Up
			self.t = self.fDelayReturn
		elseif self.step == S.Falling then
			self.step = S.Down
			self.t = self.fDelayReset
		end
	end

	function Busy:OnTick()
		if self.t > 0 then return end
		if self.step == S.Up then
			self.step = S.Falling
			self.ccBGS_TRP_TRPARFloorSmasherDown01SD:Play(self.victim)
			self:PlayAnimation("Stage1")
		elseif self.step == S.Down then
			self.step = S.Idle
			self:GotoState("Waiting")
		end
	end
end
