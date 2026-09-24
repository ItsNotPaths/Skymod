-- pex: ansilvundsummoneffect 3d22f705
-- pex: fragment_0 3bd95d37
-- pex: fragment_1 2ca0a624
-- pex: fragment_2 6a7ddae4
-- Each fragment shook the camera, then called ansilvundSummonEffect (FX, a 1s wait, activate)
-- once per alias in order, then waited out the rest of the camera shake and removed the
-- crossfade. Each alias's wait is now a timer; a fragment's alias list is fixed, so its place in
-- the list is an index, not a stored plan. Commented-out per-alias delays in the source are
-- dropped as in the original (they never ran).
local rt = require('skymod.rt')

return function(C)
	local split_tick = C.__fn.ontick
	local FRAGS = {
		[1] = { shake = 0.3, l = "controllershakel01", r = "controllershaker01", dur = "controllershakeduration01",
			aliases = { "alias_summonlightenable104", "alias_summonlightenable103", "alias_summonlightenable102", "alias_summonlightenable101" } },
		[2] = { shake = 0.5, l = "controllershakel02", r = "controllershaker02", dur = "controllershakeduration02",
			aliases = { "alias_summonlightenable201", "alias_summonlightenable202", "alias_summonlightenable203", "alias_summonlightenable204", "alias_summonlightenable205" } },
		[3] = { shake = 0.7, l = "controllershakel03", r = "controllershaker03", dur = "controllershakeduration03",
			aliases = { "alias_summonlightenable301", "alias_summonlightenable302", "alias_summonlightenable303", "alias_summonlightenable304", "alias_summonlightenable305", "alias_summonlightenable306", "alias_summonlightenable307" } },
	}
	local DELAY = 0.2

	C.__vars.summonBusy = rt.bool(false) -- ansilvundSummonEffect is mid-wait
	C.__vars.summonT = rt.timer(0.0)
	C.__vars.summonAlias = rt.form("ReferenceAlias")
	C.__vars.frag = rt.int(0)   -- which fragment owns the running summon queue, 0 = none
	C.__vars.fragIdx = rt.int(0)

	function C:ansilvundSummonEffect(myAlias)
		if self.summonBusy then return end -- a run happens once
		local aliasRef = myAlias:GetReference()
		self.trailfx:Play(aliasRef, self.fdelay, aliasRef:GetLinkedRef())
		self.trailfx02:Play(aliasRef:GetLinkedRef(), self.fdelay, aliasRef)
		self.summonsound:Play(aliasRef)
		self.summonBusy = true
		self.summonAlias = myAlias
		self.summonT = 1.0
	end

	local function start_fragment(self, n)
		if self.frag ~= 0 or self.summonBusy then return end -- a run happens once
		local f = FRAGS[n]
		if self.dunansilvundsummonismd then self.dunansilvundsummonismd:ApplyCrossFade(1.5) end
		rt.static("Game", "ShakeCamera", rt.None, f.shake, 0.0)
		rt.static("Game", "ShakeController", self[f.l], self[f.r], self[f.dur])
		self.frag = n
		self.fragIdx = 0 -- 0-based: aliases is a plain array literal, indices start at 0
		self:ansilvundSummonEffect(self[f.aliases[0]])
	end

	function C:Fragment_0() start_fragment(self, 1) end
	function C:Fragment_1() start_fragment(self, 2) end
	function C:Fragment_2() start_fragment(self, 3) end

	function C:OnTick()
		split_tick(self)
		if self.summonBusy and self.summonT <= 0 then
			self.summonBusy = false
			local aliasRef = self.summonAlias:GetReference()
			aliasRef:Activate(aliasRef)
			if self.frag ~= 0 then
				local f = FRAGS[self.frag]
				self.fragIdx = self.fragIdx + 1
				if self.fragIdx < #f.aliases then
					self:ansilvundSummonEffect(self[f.aliases[self.fragIdx]])
				else
					self.summonT = self[f.dur] - DELAY * #f.aliases
				end
			end
			return
		end
		if self.frag ~= 0 and not self.summonBusy and self.summonT <= 0
			and self.fragIdx >= #FRAGS[self.frag].aliases then
			rt.static("ImageSpaceModifier", "RemoveCrossFade", 1.5)
			self.frag = 0
			self.fragIdx = 0
		end
	end
end
