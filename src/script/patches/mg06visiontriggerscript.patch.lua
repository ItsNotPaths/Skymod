-- pex: ontriggerenter 486ae241
-- MG06VisionTrigger (set before the work it guards, as Papyrus already does) is the permanent
-- one-shot flag. The 3D wait plus two more delays become one stage sequence.
local rt = require('skymod.rt')

return function(C)
	C.Stage = rt.sequence("Idle", "AwaitLoad", "Intro", "Outro")
	C.__vars.stage = C.Stage.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	local function player() return rt.static("Game", "GetPlayer") end

	function C:OnTriggerEnter(AkActionRef)
		if AkActionRef ~= player() then return end
		if self.MG06:GetStage() ~= 60 then return end
		local MG06Script = rt.cast(self.MG06, "mg06questscript")
		if MG06Script.MG06VisionTrigger ~= 0 then return end
		MG06Script.MG06VisionTrigger = 1
		self.MG06NerienAlias:GetReference():Enable()
		self.MG06NerienAlias:GetActorReference():SetAlpha(0)
		rt.static("Game", "DisablePlayerControls")
		self.stage = C.Stage.AwaitLoad
	end

	function C:OnTick()
		if self.stage == C.Stage.Idle then return end
		if self.stage == C.Stage.AwaitLoad then
			if not self.MG06NerienAlias:GetReference():Is3DLoaded() then return end
			self.introFX:apply()
			self.stage = C.Stage.Intro
			self.t = self.FDelay
			return
		end
		if self.t > 0 then return end
		if self.stage == C.Stage.Intro then
			self.introFX:PopTo(self.LoopFX)
			self.PSGD:apply(self.FadeInTime)
			self.MGTeleportInEffect:Play(self.MG06NerienAlias:GetReference(), 3.6)
			self.MG06NerienAlias:GetActorReference():SetAlpha(1, true)
			self.stage = C.Stage.Outro
			self.t = self.t + 1.5
			return
		end
		if self.stage == C.Stage.Outro then
			self.MG06VisionScene:Start()
			self.stage = C.Stage.Idle
		end
	end
end
