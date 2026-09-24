-- pex: active.onbeginstate e519380d
-- Entering Active activated the plate (twice 0.1 s apart for trigger type 1), pressed it and
-- waited for TransitionComplete, then reset if the trigger was empty. Now a timer steps the
-- activation and the event ends the press.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Activating", "Settling", "Pressing")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)
	local Active, DoNothing = rt.state(C, "Active"), rt.state(C, "DoNothing")

	local function press(self)
		self.TriggerSound:Play(self)
		self:RegisterForAnimationEvent(self, "TransitionComplete")
		self.step = self:PlayAnimation("Stage2") and S.Pressing or S.Idle
	end

	function Active:OnBeginState()
		self:GotoState("DoNothing")
		if self.StoredTriggerType == 1 then
			self.Type = 3
			self.step = S.Activating
			self.t = 0.1
		else
			self:Activate(self)
			press(self)
		end
	end

	function DoNothing:OnTick()
		if self.t > 0 then return end
		if self.step == S.Activating then
			self:Activate(self)
			self.step = S.Settling
			self.t = self.t + 0.1
		elseif self.step == S.Settling then
			press(self)
		end
	end

	function DoNothing:OnAnimationEvent(akSource, asEventName)
		if self.step ~= S.Pressing or akSource ~= self or asEventName ~= "TransitionComplete" then return end
		self.step = S.Idle
		if self.ObjectsInTrigger == 0 then
			self:GotoState("Inactive")
			self:PlayAnimation("Stage1")
		end
	end
end
