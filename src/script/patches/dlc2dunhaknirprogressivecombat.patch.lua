-- pex: runupdate 7fcc0327
-- pex: updatebattle eb09101a
-- pex: updateloop 63142a33
-- UpdateLoop polled RunUpdate every 1 s while isActive; RunUpdate called the latent UpdateBattle
-- and read its return. UpdateBattle's own while-loop activated enemies one at a time, waiting
-- `delay` (skipped once, the first time ever) plus an optional 0-0.5 s random gap between each.
-- `busy` (already a fact) still guards the spawn run; `loopT` carries the outer 1 s cadence.
local rt = require('skymod.rt')

local function tick_battle(self)
	while self.busy do
		if self.pendingActivate then
			if self.spawnT > 0 then return end
			self:ActivateNextEnemy()
			self.pendingActivate = false
		end
		if self:CountActiveEnemies(self.battlemanager, self.currentenemylink) < self.simultaneousenemies
			and self.currentenemylink < self.totalenemies then
			local w = 0.0
			if self.initialenemyactivated then w = self.delay else self.initialenemyactivated = true end
			if self.usesmallrandomdelay then w = w + rt.static("Utility", "RandomFloat", 0.0, 0.5) end
			self.spawnT, self.pendingActivate = w, true
			if self.spawnT > 0 then return end
		else
			self.busy = false
			local stillAlive = self:CountActiveEnemies(self.battlemanager, self.currentenemylink) ~= 0
			self.isactive = stillAlive
			if not stillAlive then self.refactivateoncomplete:Activate(self, false) end
			self.loopT = 1.0
		end
	end
end

return function(C)
	C.__vars.spawnT = rt.timer(0.0)
	C.__vars.pendingActivate = rt.bool(false)
	C.__vars.loopT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)

	function C:UpdateBattle()
		if self.busy then return end -- a run happens once
		self.busy, self.spawnT, self.pendingActivate = true, 0.0, false
		tick_battle(self) -- Papyrus's while checks its condition at once, no wait first
	end

	function C:RunUpdate()
		if self.isactive then self:UpdateBattle() end
	end

	function C:UpdateLoop()
		self.loopT = 0.0
		self:OnTick() -- Papyrus checks isActive && !breakLoop and calls RunUpdate() at once
	end

	function C:OnTick()
		if self.busy then return tick_battle(self) end
		if self.isactive and not self.breakloop then
			if self.loopT > 0 then return end
			self:RunUpdate()
		else
			self.breakloop = false
		end
	end
end
