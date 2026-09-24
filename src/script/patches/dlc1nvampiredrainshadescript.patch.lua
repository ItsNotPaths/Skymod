-- pex: createashpile 43730c17
-- pex: ondying e48d9cce
-- OnDying exploded the victim, burned it to ash for fDelayEnd (unless immune), waited 0.1 s and
-- raised the necro lord. Now OnTick in the Burning state walks those steps.
-- HOLE(magic, gap): runs on an effect instance, which nothing makes yet.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Burning", "Rising")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.step_t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)
	local Burning = rt.state(C, "Burning")

	local function immune(self)
		local list = self.pDisintegrationMainImmunityList
		if not list then return false end
		local base = rt.cast(self.victim:GetBaseObject(), "ActorBase")
		self.VictimRace = base:GetRace()
		return list:HasForm(self.VictimRace) or list:HasForm(base)
	end

	-- starts the burn; the finish runs in OnTick
	function C:createAshPile()
		self.TargetIsImmune = immune(self)
		if self.TargetIsImmune then return false end
		local v = self.victim
		v:Kill(rt.static("Game", "GetPlayer"))
		v:SetCriticalStage(v.CritStage_DisintegrateStart)
		if self.pGhostDeathFXShader then self.pGhostDeathFXShader:Play(v, self.ShaderDuration) end
		v:SetAlpha(0.0, true)
		v:AttachAshPile(self.pDefaultAshPileGhost)
		return true
	end

	function C:OnDying(akkiller)
		if self.step ~= S.Idle then return end
		self.victim:PlaceAtMe(self.necroExplosion)
		self:GotoState("Burning")
		if self:createAshPile() then
			self.step = S.Burning
			self.step_t = self.fDelayEnd
		else
			self.step = S.Rising
			self.step_t = 0.1
		end
	end

	function Burning:OnTick()
		if self.step_t > 0 then return end
		local v = self.victim
		if self.step == S.Burning then
			if self.pGhostDeathFXShader then self.pGhostDeathFXShader:Stop(v) end
			if self.bSetAlphaZero then v:SetAlpha(0.0, true) end
			v:SetCriticalStage(v.CritStage_DisintegrateEnd)
			self.step = S.Rising
			self.step_t = self.step_t + 0.1
		elseif self.step == S.Rising then
			self.step = S.Idle
			v:PlaceAtMe(self.necroLord)
			self:GotoState("")
		end
	end
end
