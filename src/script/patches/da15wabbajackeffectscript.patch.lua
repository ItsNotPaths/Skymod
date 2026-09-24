-- pex: createashpile 4f2d5ef1
-- pex: spawngold 83c0eb36
-- pex: spawnsweetroll 94abe292
-- createAshPile burned the victim for fDelayEnd; spawnSweetRoll and spawnGold waited around it
-- (0.7 + 0.1 s before the sweet roll's ash, 0.1 s after the gold's). Now `ash` and `step` are
-- the two runs, stepped by OnTick after the split functions' ticks.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "SweetFlash", "SweetMarker", "SweetAsh", "GoldAsh", "GoldDrop")
	C.Ash = rt.sequence("Idle", "Burning")
	local S, A = C.Step, C.Ash
	C.__vars.step = S.Idle
	C.__vars.step_t = rt.timer(0.0)
	C.__vars.ash = A.Idle
	C.__vars.ash_t = rt.timer(0.0)
	C.__vars.target = rt.form("Actor")
	local split_tick = C.__fn.ontick

	local function immune(self)
		local list = self.pDisintegrationMainImmunityList
		if not list then return false end
		local base = rt.cast(self.victim:GetBaseObject(), "ActorBase")
		self.VictimRace = base:GetRace()
		return list:HasForm(self.VictimRace) or list:HasForm(base)
	end

	function C:createAshPile()
		self.TargetIsImmune = immune(self)
		if self.TargetIsImmune then return end
		local v = self.victim
		v:Kill(rt.static("Game", "GetPlayer"))
		v:SetCriticalStage(v.CritStage_DisintegrateStart)
		if self.pGhostDeathFXShader then self.pGhostDeathFXShader:Play(v, self.ShaderDuration) end
		v:SetAlpha(0.0, true)
		v:AttachAshPile(self.pDefaultAshPileGhost)
		self.ash = A.Burning
		self.ash_t = self.fDelayEnd
	end

	local function ash_tick(self)
		if self.ash ~= A.Burning or self.ash_t > 0 then return end
		self.ash = A.Idle
		local v = self.victim
		if self.pGhostDeathFXShader then self.pGhostDeathFXShader:Stop(v) end
		if self.bSetAlphaZero then v:SetAlpha(0.0, true) end
		v:SetCriticalStage(v.CritStage_DisintegrateEnd)
	end

	local function raise_marker(self, dz)
		local t = self.target
		self.explosionMarker:SetPosition(t.x, t.y, t.z + dz)
	end

	function C:spawnSweetRoll(targ)
		if self.step ~= S.Idle then return end
		self.target = targ
		targ:PlaceAtMe(self.visualExplosion)
		self.step = S.SweetFlash
		self.step_t = 0.7
	end

	function C:spawnGold(targ)
		if self.step ~= S.Idle then return end
		self.target = targ
		targ:PlaceAtMe(self.visualExplosion)
		self.step = S.GoldAsh
		self:createAshPile()
	end

	local function step_tick(self)
		local st = self.step
		if st == S.SweetFlash and self.step_t <= 0 then
			raise_marker(self, 10)
			self.step = S.SweetMarker
			self.step_t = self.step_t + 0.1
		elseif st == S.SweetMarker and self.step_t <= 0 then
			self.step = S.SweetAsh
			self:createAshPile()
		elseif st == S.SweetAsh and self.ash == A.Idle then
			self.step = S.Idle
			self.explosionMarker:PlaceAtMe(self.sweetRoll)
		elseif st == S.GoldAsh and self.ash == A.Idle then
			raise_marker(self, 100)
			self.step = S.GoldDrop
			self.step_t = 0.1
		elseif st == S.GoldDrop and self.step_t <= 0 then
			self.step = S.Idle
			self.explosionMarker:PlaceAtMe(self.gold, 50)
			self.explosionMarker:PlaceAtMe(self.forceExplosion)
		else
			return false
		end
		return true
	end

	function C:OnTick()
		split_tick(self)
		ash_tick(self)
		while step_tick(self) do ash_tick(self) end
	end
end
