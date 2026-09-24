-- pex: ondying f1c5cddd
-- pex: oneffectfinish e10405b7
-- pex: turntoash e3ff377e
-- TurnToAsh started the disintegration, attached the ash pile fDelay later and ended it fDelayEnd
-- after that; its callers then set AshPileCreated. Now AshPileCreated is set when the burn
-- starts, and OnTick in Burning walks the two steps.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Burning", "Ending")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.step_t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)
	local Burning = rt.state(C, "Burning")

	function C:TurnToAsh()
		local v = self.victim
		v:SetCriticalStage(v.CritStage_DisintegrateStart)
		if self.MagicEffectShader then self.MagicEffectShader:Play(v, self.ShaderDuration) end
		if self.bSetAlphaToZeroEarly then v:SetAlpha(0.0, true) end
		self.step = S.Burning
		self.step_t = self.fDelay
		self:GotoState("Burning")
	end

	local function burn(self)
		if self.TargetIsImmune or self.AshPileCreated then return end
		self.AshPileCreated = true
		self:TurnToAsh()
	end

	function C:OnDying(Killer) burn(self) end
	function C:OnEffectFinish(Target, Caster) burn(self) end

	function Burning:OnTick()
		if self.step_t > 0 then return end
		local v = self.victim
		if self.step == S.Burning then
			v:AttachAshPile(self.AshPileObject)
			self.step = S.Ending
			self.step_t = self.step_t + self.fDelayEnd
		else
			self.step = S.Idle
			if self.MagicEffectShader then self.MagicEffectShader:Stop(v) end
			if self.bSetAlphaZero then v:SetAlpha(0.0, true) end
			v:SetCriticalStage(v.CritStage_DisintegrateEnd)
			self:GotoState("")
		end
	end
end
