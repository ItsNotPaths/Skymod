-- pex: runupdate 7fcc0327
-- pex: updatebattle 7122b20c
-- pex: updateloop 63142a33
-- The Kolbjorn twin of dlc2dunhaknirprogressivecombat: same UpdateLoop/RunUpdate/UpdateBattle
-- shape (1 s poll, a busy spawn run with `delay` skipped once plus an optional 0-0.5 s random gap
-- between activations). `loopT` carries the outer cadence.
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
	local Running = rt.state(C, "Running") -- OnTick only while the loop is actually running

	function C:UpdateBattle()
		if self.busy then return end -- a run happens once
		self.busy, self.spawnT, self.pendingActivate = true, 0.0, false
		self:GotoState("Running")
		tick_battle(self) -- Papyrus's while checks its condition at once, no wait first
	end

	function C:RunUpdate()
		if self.isactive then self:UpdateBattle() end
	end

	function C:UpdateLoop()
		self.loopT = 0.0
		if self.isactive and not self.breakloop then
			self:GotoState("Running")
			self:OnTick() -- Papyrus checks isActive && !breakLoop and calls RunUpdate() at once
		else
			self.breakloop = false
		end
	end

	function Running:OnTick()
		if self.busy then return tick_battle(self) end
		if self.isactive and not self.breakloop then
			if self.loopT > 0 then return end
			self:RunUpdate()
		else
			self.breakloop = false
			self:GotoState("")
		end
	end
end
