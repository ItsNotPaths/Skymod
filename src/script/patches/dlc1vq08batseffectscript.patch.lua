-- pex: oneffectfinish ff32b87c
-- pex: onupdate b48dbc70
-- OnUpdate moved the bats toward Harkon every 0.2 s while bBatsLoopContinue, then sent them home
-- and deleted them 0.25 s later; OnEffectFinish cleared the flag 2 s after the reform. Now OnTick
-- paces both: `bats` is the flight, `stop_t` the 2 s before the flag clears.
local rt = require('skymod.rt')

return function(C)
	C.Bats = rt.sequence("Idle", "Following", "Returning")
	local B = C.Bats
	C.__vars.bats = B.Idle
	C.__vars.bats_sw = rt.stopwatch(0.0)
	C.__vars.stop_t = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(0.1)
	local split_tick = C.__fn.ontick
	local function pairs_of(self) return { { self.MyBatsFXObjectRef, self.CasterActor } } end
	local function clear(self) self.MyBatsFXObjectRef = rt.None end

	function C:OnEffectFinish(akTarget, akCaster)
		akCaster:SetGhost(false)
		rt.cast(self.DLC1VQ08HarkonAlias, "DLC1dunHarkonBatTeleport"):BatsAllDone()
		if not self.bBatsAreGoCheck then return end
		if not self.bAnimDidHappen then
			local caster = self.CasterActor
			caster:SetSubGraphFloatVariable("fdampRate", 0.02)
			caster:SetSubGraphFloatVariable("ftoggleBlend", 0.0)
			self.DLC1VampireBatsReformFXS:Play(caster, 0.2)
			self.DLC1VampireBatsReformBATSFXS:Play(caster, 0.2)
		end
		self.stop_t = 2.0
	end

	function C:OnUpdate()
		if self.bats ~= B.Idle then return end
		self.bats = B.Following
		self.bats_sw = 0.2 -- the first move is now
		self:OnTick()
	end

	local function bats_tick(self)
		if self.bats == B.Following then
			if self.bBatsLoopContinue then
				if self.bats_sw < 0.2 then return end
				self.bats_sw = self.bats_sw - 0.2
				for _, p in ipairs(pairs_of(self)) do
					p[0]:TranslateToRef(p[1], p[1]:GetDistance(p[0]) + self.fTranslationSpeed, 1)
				end
				return
			end
			for _, p in ipairs(pairs_of(self)) do p[0]:TranslateToRef(p[1], self.fTranslationSpeed, 1) end
			self.bats = B.Returning
			self.bats_sw = 0.0
		elseif self.bats == B.Returning and self.bats_sw >= 0.25 then
			self.bats = B.Idle
			for _, p in ipairs(pairs_of(self)) do
				p[0]:Disable()
				p[0]:Delete()
			end
			clear(self)
		end
	end

	function C:OnTick()
		split_tick(self)
		if self.stop_t ~= rt.None and self.stop_t <= 0 then
			self.stop_t = rt.None
			self.bBatsLoopContinue = false
		end
		bats_tick(self)
	end
end
