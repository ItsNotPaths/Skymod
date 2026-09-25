-- pex: runupdate 7fcc0327
-- pex: updatebattle eb09101a
-- pex: updateloop 63142a33
-- UpdateLoop called RunUpdate then Wait(1), forever while isActive. UpdateBattle's own busy lock
-- ran a burst of ActivateNextEnemy calls, each preceded by delay + (if set) a small random wait.
-- Now one OnTick: the 1s outer cadence and the burst are two timers, both drained by the same tick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.05)
	C.__vars.burstT = rt.timer(0.0) -- spacing between ActivateNextEnemy calls, inside a burst
	C.__vars.runT = rt.timer(0.0)   -- UpdateLoop's own Wait(1) between RunUpdate passes

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
	-- A direct call (a mod) starts the same burst, drained by OnTick.
	function C:UpdateBattle()
		if self.busy then return true end -- a burst already runs
		self.busy = true
		self.burstT = 0.0
		return true
	end

	function C:OnTick()
		if self.looping and self.isactive and not self.breakloop then
			if self.runT <= 0 then
				self.runT = self.runT + 1.0
				self:RunUpdate()
			end
		elseif self.looping then
			self.looping, self.breakloop = false, false -- the while ends; the next OnLoad starts it again
		end
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
					self.refactivateoncomplete:Activate(self, false)
				end
			end
		end
	end
end
