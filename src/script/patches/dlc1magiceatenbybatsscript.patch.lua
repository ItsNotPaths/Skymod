-- pex: decalspray a9d5324d
-- pex: oneffectfinish 7d68bfc9
-- On a dead target, OnEffectFinish played the bats, waited 0.4 s, then sprayed blood twice
-- (impulse, 0.28 s, impulse, 0.38 s), stopped the splats and held the effect 5 s. Now OnTick
-- walks the spray; `sprays` counts the ones left. The closing 5 s hold did nothing and is gone.
-- HOLE(magic, gap): runs on an effect instance, which nothing makes yet.
local rt = require('skymod.rt')

return function(C)
	C.Spray = rt.sequence("Idle", "Delay", "First", "Second")
	local S = C.Spray
	C.__vars.spray = S.Idle
	C.__vars.spray_t = rt.timer(0.0)
	C.__vars.sprays = rt.int(0)
	C.__vars.bleeder = rt.form("Actor")
	C.__vars.vx = rt.float(0.0)
	C.__vars.vy = rt.float(0.0)
	local split_tick = C.__fn.ontick

	local function first(self)
		local rnd = function() return rt.static("Utility", "RandomFloat", -0.6, 0.6) end
		self.vx, self.vy = rnd(), rnd()
		self.bleeder:ApplyHavokImpulse(self.vx, self.vy, 0.7, 50.0)
		self.bleeder:PlayImpactEffect(self.BloodSprayBleedImpactSetRed, "MagicEffectsNode", self.vx, self.vy, -0.9, 512, false, false)
		self.spray = S.First
		self.spray_t = self.spray_t + 0.28
	end

	function C:DecalSpray(BleedingActor, xTimes)
		self.bleeder = BleedingActor
		self.sprays = xTimes
		if xTimes > 0 then self.spray_t = 0.0 first(self) end
	end

	function C:OnEffectFinish(Target, Caster)
		self.bleeder = Target
		if not Target:IsDead() then return self.DLC1BatsEatenBloodSplats:Stop(Target) end
		self.DLC1VampireBatsVFX:Play(Target, 1.0, Caster)
		self.DLC1VampBatsEatenByBatsSkinFXS:Play(Target, 5.0)
		self.spray = S.Delay
		self.spray_t = 0.4
	end

	local function spray_tick(self)
		if self.spray == S.Idle or self.spray_t > 0 then return end
		if self.spray == S.Delay then
			self.sprays = 2
			first(self)
		elseif self.spray == S.First then
			self.bleeder:ApplyHavokImpulse(self.vy, self.vx, 0.7, 45.0)
			self.spray = S.Second
			self.spray_t = self.spray_t + 0.38
		else
			self.sprays = self.sprays - 1
			if self.sprays > 0 then return first(self) end
			self.spray = S.Idle
			self.DLC1BatsEatenBloodSplats:Stop(self.bleeder)
		end
	end

	function C:OnTick()
		split_tick(self)
		spray_tick(self)
	end
end
