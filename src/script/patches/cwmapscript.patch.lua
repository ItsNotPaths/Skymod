-- pex: onload 88990899
-- OnLoad forced CWs.DebugOn to 1 (waiting 1s if it wasn't already), then polled
-- CWMapQuestS.IsRunning every 1s before placing the flags. Now a stage of rt.sequence plus a
-- timer, read from OnTick at the same 1 Hz cadence.
local rt = require('skymod.rt')

return function(C)
	C.Stage = rt.sequence("Idle", "DebugWait", "WaitQuest")
	C.__vars.stage = C.Stage.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(1.0)

	function C:OnLoad()
		if self.stage ~= C.Stage.Idle then return end -- a second start is dropped
		if self.CWs.DebugOn:GetValue() ~= 1 then
			self.CWs.DebugOn:SetValue(1)
			self.stage = C.Stage.DebugWait
			self.t = self.t + 1.0
			return
		end
		self.stage = C.Stage.WaitQuest
	end

	function C:OnTick()
		if self.stage == C.Stage.DebugWait then
			if self.t > 0 then return end
			self.stage = C.Stage.WaitQuest
			return
		end
		if self.stage == C.Stage.WaitQuest then
			if not self.CWMapQuestS:IsRunning() then return end
			self.stage = C.Stage.Idle
			self:PlaceFlags()
		end
	end
end
