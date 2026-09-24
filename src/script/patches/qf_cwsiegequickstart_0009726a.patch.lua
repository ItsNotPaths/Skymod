-- pex: fragment_0 62a148d1
-- pex: fragment_1 bbe19804
-- pex: fragment_2 b05fbef5
-- pex: fragment_4 7430711f
-- The four Whiterun quick starts cleaned up the giant attack and the Companions once
-- QuickStartSiege returned. QuickStartSiege now runs on (CWSiegeQuickStartScript `quick`), so the
-- clean-up is owed until that run is Idle.
local rt = require('skymod.rt')

return function(C)
	C.__vars.companionsHomeOwed = rt.bool(false) -- the player's side keeps the Companions in Whiterun
	C.__vars.companionsGoneOwed = rt.bool(false) -- the Sons attack with the player: they leave
	local split_tick = C.__fn.ontick

	local function quick_start(self) return rt.cast(self, "CWSiegeQuickStartScript") end

	local function cleanup_tick(self)
		if not (self.companionsHomeOwed or self.companionsGoneOwed) then return end
		local q = quick_start(self)
		if q.quick ~= q.quick.seq.Idle then return end
		q.C00GiantAttack:SetStage(200)
		local companions = { q.AelaTheHuntressREF, q.FarkasREF, q.AthisREF, q.RiaREF }
		if self.companionsHomeOwed then
			self.companionsHomeOwed = false
			for i = 0, 3 do companions[i]:MoveToMyEditorLocation() end
			return
		end
		self.companionsGoneOwed = false
		for i = 0, 3 do companions[i]:Disable() end
		q.MQ103:Stop()
		q.C00GiantREF:Disable()
		q.C00GiantREF:MoveTo(q.RunilREF) -- he would not disable
	end

	local function whiterun(self, attacker, allegiance, owed)
		self[owed] = true
		quick_start(self):QuickStartSiege(4, attacker, allegiance, 1, false, false)
		cleanup_tick(self)
	end

	function C:Fragment_0() whiterun(self, 1, 1, "companionsHomeOwed") end
	function C:Fragment_1() whiterun(self, 2, 1, "companionsHomeOwed") end
	function C:Fragment_2() whiterun(self, 2, 2, "companionsGoneOwed") end
	function C:Fragment_4() whiterun(self, 1, 2, "companionsHomeOwed") end

	function C:OnTick()
		split_tick(self)
		cleanup_tick(self)
	end
end
