-- pex: onload 16cd1c2a
-- CritterSpawn.OnLoad polled ShouldSpawn every fCheckPlayerDistanceTime until it spawned or
-- bLooping went false. The poll is now OnTick in the waiting state, at that interval.
local rt = require('skymod.rt')

return function(C)
	local split_tick = C.__fn.ontick -- this class's S6 split waits; an OnTick here must run them
	C.__vars.TickRate = rt.float(C.__vars.fcheckplayerdistancetime.default)
	local Waiting = rt.state(C, "WaitingForPlayer")

	function C:OnLoad()
		self.bLooping = true
		self:GotoState("WaitingForPlayer")
		self:OnTick() -- Papyrus checked at once
	end

	-- OnUnload, OnCellDetach and ShouldSpawn clear bLooping; the state follows it.
	function Waiting:OnTick()
		if split_tick then split_tick(self) end
		if self.bLooping and self:ShouldSpawn() then
			self:SpawnInitialCritterBatch()
			self.bLooping = false
		end
		if not self.bLooping then self:GotoState("") end
	end
end
