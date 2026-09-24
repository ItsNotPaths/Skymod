-- pex: ontriggerenter eb482a92
-- The trigger waited 2 s then called TriggerVision, which Papyrus runs to completion before
-- Self.Disable() -- so Disable now waits for MG02QuestScript.visionBusy to clear.
local rt = require('skymod.rt')

return function(C)
	C.Stage = rt.sequence("Idle", "Delay", "AwaitVision")
	C.__vars.stage = C.Stage.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	local function player() return rt.static("Game", "GetPlayer") end
	local function quest(self) return rt.cast(self.MG02, "mg02questscript") end

	function C:OnTriggerEnter(ActionRef)
		if ActionRef ~= player() then return end
		local QuestScript = quest(self)
		QuestScript.PlayerVisionReady = 1
		if QuestScript.TolfdirUpdate == 2 then
			if not self.MG02TolfdirAlias:GetActorReference():IsInCombat() and not player():IsInCombat() then
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
