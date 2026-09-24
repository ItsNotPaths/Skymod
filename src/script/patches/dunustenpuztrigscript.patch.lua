-- pex: triggered.onbeginstate 09cf8469
-- pex: triggered.ontriggerleave 2ef9dd5c
-- OnBeginState (lever path) waited 1s then called CloseGate, itself a 1.5s wait, then waited
-- 0.5s more before returning to Waiting. OnTriggerLeave skipped the first 1s wait. Both are now
-- a stage: an optional lever delay, a wait for the gate's own `closing` fact to clear, then a
-- settle wait before GotoState("Waiting").
local rt = require('skymod.rt')

return function(C)
	C.Close = rt.sequence("Idle", "LeverDelay", "AwaitGate", "Settle")
	C.__vars.closeStage = C.Close.Idle
	C.__vars.closeT = rt.timer(0.0)
	local Triggered = rt.state(C, "Triggered")

	local function start_close(self, viaLever)
		if self.closeStage ~= C.Close.Idle then return end -- a second start is dropped
		if viaLever then
			self.closeStage = C.Close.LeverDelay
			self.closeT = 1.0
		else
			self.mylinkedref:CloseGate()
			self.closeStage = C.Close.AwaitGate
		end
	end

	function Triggered:OnBeginState()
		if self.dunustengravqst:GetStageDone(50) then return end
		if not self.activatedbylever then return end
		self.activatedbylever = false
		start_close(self, true)
	end

	function Triggered:OnTriggerLeave(triggerRef)
		if self.dunustengravqst:GetStageDone(50) then return end
		if triggerRef ~= rt.static("Game", "GetPlayer") then return end
		self.dragonstone01:PlayAnimation("stop")
		self.dragonstone01:PlayAnimation("quickstop")
		self.dragonstonelight01:Disable()
		start_close(self, false)
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.closeStage == C.Close.LeverDelay and self.closeT <= 0 then
			self.mylinkedref:CloseGate()
			self.closeStage = C.Close.AwaitGate
		end
		if self.closeStage == C.Close.AwaitGate and not self.mylinkedref.closing then
			rt.static("Debug", "Trace", "Waiting")
			self.closeStage = C.Close.Settle
			self.closeT = 0.5
		end
		if self.closeStage == C.Close.Settle and self.closeT <= 0 then
			self.closeStage = C.Close.Idle
			self:GotoState("Waiting")
		end
	end
end
