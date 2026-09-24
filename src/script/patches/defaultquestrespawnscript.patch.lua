-- pex: trytorespawn 1ff10048
-- TryToRespawn rolled a wait, waited it, then respawned the alias if it still wanted respawning.
-- The wait belongs to the alias (several aliases can be mid-respawn on one quest at once), so this
-- only checks eligibility and starts the alias's timer; defaultaliasrespawnscript's OnTick finishes
-- the job through the quest ref it was given.
local rt = require('skymod.rt')

return function(C)
	function C:TryToRespawn(aliasToRespawn)
		local ok = (self.startstage == 0 or (self.startstage > 0 and self:GetStageDone(self.startstage)))
			and (self.donestage == 0 or (self.donestage > 0 and not self:GetStageDone(self.donestage)))
			and (self.respawnpool == 0 or (self.respawnpool > 0 and self.respawncount < self.respawnpool))
		if not ok then return end
		self.respawncount = self.respawncount + 1
		aliasToRespawn.respawn_t = rt.static("Utility", "RandomInt", self.respawntimemin, self.respawntimemax)
		aliasToRespawn.respawn_quest = self
	end
end
