-- pex: triggervision b57e1104
-- TriggerVision set dressing then blocked on Nerien's 3D, then two more waits before starting the
-- scene. It is now a stage sequence; visionBusy is the fact the two trigger scripts wait on before
-- disabling themselves, since Papyrus's synchronous call means the caller resumes only after this
-- whole chain (including the two later waits) finishes.
local rt = require('skymod.rt')

return function(C)
	C.Stage = rt.sequence("Idle", "AwaitLoad", "Intro", "Outro")
	C.__vars.stage = C.Stage.Idle
	C.__vars.visionBusy = rt.bool(false)
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	function C:TriggerVision()
		if self.visionBusy then return end -- a second start while one runs is dropped
		self.visionBusy = true
		self.TolfdirUpdate = 3
		self.MG02MonkSceneQuest:Start()
		self.MG02VisionCollisionPlane:Enable()
		self.MG02NerienAlias:GetReference():Enable()
		self.MG02NerienAlias:GetActorReference():SetAlpha(0)
		self.stage = C.Stage.AwaitLoad
	end

	function C:OnTick()
		if self.stage == C.Stage.Idle then return end
		if self.stage == C.Stage.AwaitLoad then
			if not self.MG02NerienAlias:GetReference():Is3DLoaded() then return end
			self.introFX:apply()
			self.stage = C.Stage.Intro
			self.t = self.FDelay
			return
		end
		if self.t > 0 then return end
		if self.stage == C.Stage.Intro then
			self.introFX:PopTo(self.LoopFX)
			self.PSGD:apply(self.FadeInTime)
			self.MGTeleportInEffect:Play(self.MG02NerienAlias:GetReference(), 3.6)
			self.MG02NerienAlias:GetActorReference():SetAlpha(1, true)
			self.stage = C.Stage.Outro
			self.t = self.t + 1.5
			return
		end
		if self.stage == C.Stage.Outro then
			self.pMG02VisionScene:Start()
			self.stage = C.Stage.Idle
			self.visionBusy = false
		end
	end
end
