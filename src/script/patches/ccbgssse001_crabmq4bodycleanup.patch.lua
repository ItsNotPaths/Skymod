-- pex: crabdied d16744cf
-- pex: guarddied 753403f7
-- CrabDied/GuardDied busy-waited on their own flag (Wait(0.25) while workingCrabs/workingGuards)
-- so a second death mid-cleanup would queue behind the first. Nothing in the body yields anymore,
-- so one call always finishes before the next one starts: the flag can never be true when a call
-- begins. Drop the wait loop; the ring-buffer body is unchanged.
local rt = require('skymod.rt')

return function(C)
	function C:CrabDied(akActorRef)
		local idx = self.currentCrabIndex
		local dead = self.deadCrabs[idx]
		if dead ~= rt.None then
			dead:DisableNoWait()
			dead:Delete()
		end
		self.deadCrabs[idx] = akActorRef
		if idx >= self.ccbgssse001_crabmq4alloweddeadcrabs:GetValueInt() - 1 or idx >= #self.deadCrabs - 1 then
			self.currentCrabIndex = 0
		else
			self.currentCrabIndex = idx + 1
		end
	end

	function C:GuardDied(akActorRef)
		local idx = self.currentGuardIndex
		local dead = self.deadGuards[idx]
		if dead ~= rt.None then
			dead:DisableNoWait()
			dead:Delete()
		end
		self.deadGuards[idx] = akActorRef
		if idx >= self.ccbgssse001_crabmq4alloweddeadguards:GetValueInt() - 1 or idx >= #self.deadGuards - 1 then
			self.currentGuardIndex = 0
		else
			self.currentGuardIndex = idx + 1
		end
	end
end
