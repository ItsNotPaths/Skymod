-- pex: ondying cfc36860
-- OnDying: shaders on, [alpha 0 after fDelayAlpha], the ash pile after fDelay, the end after
-- fDelayEnd. Now OnTick in Dissolving walks the steps on one stopwatch.
-- HOLE(magic, gap): runs on an effect instance, which nothing makes yet.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Alpha", "Pile", "End")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.sw = rt.stopwatch(0.0)
	C.__vars.TickRate = rt.float(0.05)
	local Dissolving = rt.state(C, "Dissolving")

	function C:OnDying(Killer)
		if self.step ~= S.Idle then return end
		self.DLC2AshSpawnDisintegrateFXS:Play(self.Victim, self.ShaderDuration)
		self.DLC2AshSpawnDisintegrateFXS02:Play(self.Victim, self.ShaderDuration)
		self.step = self.bSetAlphaToZeroEarly and S.Alpha or S.Pile
		self.sw = 0.0
		self:GotoState("Dissolving")
	end

	function Dissolving:OnTick()
		local v = self.Victim
		if self.step == S.Alpha and self.sw >= self.fDelayAlpha then
			self.sw = self.sw - self.fDelayAlpha
			self.step = S.Pile
			v:SetAlpha(0.0, true)
		end
		if self.step == S.Pile and self.sw >= self.fDelay then
			self.sw = self.sw - self.fDelay
			self.step = S.End
			v:AttachAshPile(self.DLC2AshSpawnAshPile)
		end
		if self.step == S.End and self.sw >= self.fDelayEnd then
			self.step = S.Idle
			if self.DLC2AshSpawnDisintegrateFXS then
				self.DLC2AshSpawnDisintegrateFXS:Stop(v)
				self.DLC2AshSpawnDisintegrateFXS02:Stop(v)
			end
			v:SetCriticalStage(v.CritStage_DisintegrateEnd)
			self:GotoState("")
		end
	end
end
