-- pex: activateandkillallenemies 921ae4f2
-- pex: runupdate f616d3be
-- pex: updatebattle eb09101a
-- pex: updateloop 63142a33
-- Same shape as dunProgressiveCombatScript (see that patch): UpdateLoop/RunUpdate/UpdateBattle
-- become a 1s cadence plus an activation burst on two timers. ActivateAndKillAllEnemies activates
-- the rest of the chain one at a time (spaced by `delay`), then kills every linked enemy at once
-- (no wait there, so no ticking needed for that half). The three burst helpers are plain methods,
-- not OnTick, so dunFolgunthurBossBattle and its subclasses (their own OnTick) can call them too.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.05)
	C.__vars.burstT = rt.timer(0.0) -- UpdateBattle: spacing between ActivateNextEnemy calls
	C.__vars.runT = rt.timer(0.0)   -- UpdateLoop's own Wait(1) between RunUpdate passes
	C.__vars.killT = rt.timer(0.0)  -- ActivateAndKillAllEnemies: spacing while activating the rest
	C.__vars.killing = rt.bool(false)

	C.__vars.looping = rt.bool(false) -- UpdateLoop's while runs; only UpdateLoop starts it

	function C:UpdateLoop()
		if self.looping then return end -- a second start while one runs is dropped
		self.looping = true
		self.runT = 0.0 -- run RunUpdate at once, as Papyrus did before its first Wait(1)
	end

	function C:RunUpdate()
		if not self.isactive then return end
		if self.busy then return end -- UpdateBattle's own lock: a burst already runs
		self.busy = true
		self.burstT = 0.0
	end

	-- Papyrus's UpdateBattle is a public function of its own, not just RunUpdate's helper.
	-- A direct call (a mod) starts the same burst, drained by _pcsBurstTick.
	function C:UpdateBattle()
		if self.busy then return true end -- a burst already runs
		self.busy = true
		self.burstT = 0.0
		return true
	end

	function C:ActivateAndKillAllEnemies()
		if self.killing then return end -- a second start during a run is dropped
		self.killing = true
		self.killT = 0.0
	end

	function C:_pcsRunTick()
		if self.looping and self.isactive and not self.breakloop then
			if self.runT <= 0 then
				self.runT = self.runT + 1.0
				self:RunUpdate()
			end
		elseif self.looping then
			self.looping, self.breakloop = false, false -- the while ends; the next OnLoad starts it again
		end
	end

	function C:_pcsBurstTick()
		while self.busy and self.burstT <= 0 do
			if self:CountActiveEnemies(self.battlemanager, self.currentenemylink) < self.simultaneousenemies
				and self.currentenemylink < self.totalenemies then
				if self.initialenemyactivated then
					self.burstT = self.burstT + self.delay
				else
					self.initialenemyactivated = true
				end
				if self.usesmallrandomdelay then
					self.burstT = self.burstT + rt.static("Utility", "RandomFloat", 0.0, 0.5)
				end
				self:ActivateNextEnemy()
			else
				self.busy = false
				self.isactive = self:CountActiveEnemies(self.battlemanager, self.currentenemylink) ~= 0
				if not self.isactive then
					self.refactivateoncomplete:Activate(self:GetReference(), false)
				end
			end
		end
	end

	function C:_pcsKillTick()
		if not self.killing then return end
		if self.currentenemylink < self.totalenemies then
			if self.killT > 0 then return end
			self:ActivateNextEnemy()
			self.killT = self.killT + self.delay
			return
		end
		for i = 0, self.totalenemies - 1 do
			local link = self.battlemanager:GetNthLinkedRef(i):GetLinkedRef(self.enemylinkkeyword)
			rt.cast(link, "Actor"):Kill()
		end
		self.killing = false
	end

	function C:OnTick()
		self:_pcsRunTick()
		self:_pcsBurstTick()
		self:_pcsKillTick()
	end
end
