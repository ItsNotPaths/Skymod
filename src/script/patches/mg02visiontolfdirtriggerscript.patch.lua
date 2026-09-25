-- pex: ontriggerenter b3d09a48
-- Same shape as MG02VisionPlayerTriggerScript: waits 2 s, calls TriggerVision, then Disable, which
-- now waits for MG02QuestScript.visionBusy since the original call blocks until Vision finishes.
local rt = require('skymod.rt')

return function(C)
	C.Stage = rt.sequence("Idle", "Delay", "AwaitVision")
	C.__vars.stage = C.Stage.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	local function player() return rt.static("Game", "GetPlayer") end
	local function quest(self) return rt.cast(self.MG02, "mg02questscript") end

	function C:OnTriggerEnter(ActionRef)
		if self.stage ~= C.Stage.Idle then return end -- a run under way drops a re-entry
		if ActionRef ~= self.MG02Tolfdir:GetReference() then return end
		local QuestScript = quest(self)
		if QuestScript.TolfdirUpdate == 1 then QuestScript.TolfdirUpdate = 2 end
		if QuestScript.PlayerVisionReady == 1 then
			if not self.MG02Tolfdir:GetActorReference():IsInCombat() and not player():IsInCombat() then
				self.stage = C.Stage.Delay
				self.t = 2.0
			end
		else
			self:Disable()
		end
	end

	function C:OnTick()
		if self.stage == C.Stage.Idle then return end
		if self.stage == C.Stage.Delay then
			if self.t > 0 then return end
			quest(self):TriggerVision()
			self.stage = C.Stage.AwaitVision
			return
		end
		if self.stage == C.Stage.AwaitVision then
			if quest(self).visionBusy then return end
			self:Disable()
			self.stage = C.Stage.Idle
		end
	end
end
