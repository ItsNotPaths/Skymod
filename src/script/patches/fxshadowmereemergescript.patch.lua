-- pex: onactivate d4d1608e
-- OnActivate enabled Shadowmere, polled Is3DLoaded every 0.05s, then ran a fixed chain of
-- animation/wait steps (3s, 5s, 10s) before releasing the weather override. Now a stage plus one
-- stopwatch; a step's overshoot carries into the next wait instead of resetting to 0.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.Stage = rt.sequence("Idle", "AwaitLoad", "Streaking", "FadeIn", "Equip")
	C.__vars.stage = C.Stage.Idle
	C.__vars.sw = rt.stopwatch(0.0)

	function C:OnActivate(akActionRef)
		if self.stage ~= C.Stage.Idle then return end -- a second start is dropped
		self.myshadowmereref:Enable()
		self.stage = C.Stage.AwaitLoad
		self.sw = 0.0
	end

	function C:OnTick()
		if self.stage == C.Stage.Idle then return end
		if self.stage == C.Stage.AwaitLoad then
			if not self.myshadowmereref:Is3DLoaded() then return end
			self.myshadowmereref:UnequipItem(self.horsesaddleshadowmere)
			self.myshadowmereref:PlaySubGraphAnimation("SkinGone")
			self:PlayAnimation("PlayAnim01")
			self.stage = C.Stage.Streaking
			self.sw = 0.0
			return
		end
		if self.stage == C.Stage.Streaking then
			if self.sw < 3.0 then return end
			self.sw = self.sw - 3.0
			self.myshadowmereref:MoveTo(self)
			self.myshadowmereref:PlaySubGraphAnimation("SkinFadeIn")
			self.stage = C.Stage.FadeIn
			return
		end
		if self.stage == C.Stage.FadeIn then
			if self.sw < 5.0 then return end
			self.sw = self.sw - 5.0
			self.myshadowmereref:EquipItem(self.horsesaddleshadowmere)
			self.stage = C.Stage.Equip
			return
		end
		if self.stage == C.Stage.Equip then
			if self.sw < 10.0 then return end
			self.sw = self.sw - 10.0
			rt.static("Weather", "ReleaseOverride")
			self.cleanuptime = 1
			self.stage = C.Stage.Idle
		end
	end
end
