-- pex: vamplock 8628038e
-- VampLock shifted a Vampire Lord player back and then disallowed the form. It now publishes
-- `locking`, true until the shift back's `back` run is Idle and the global is set.
local rt = require('skymod.rt')

return function(C)
	C.__vars.locking = rt.bool(false)
	C.__vars.TickRate = rt.float(0.1)
	local Locking = rt.state(C, "Locking")

	function C:VampLock()
		if self.locking then return end
		self.locking = true
		self:GotoState("Locking")
		if rt.static("Game", "GetPlayer"):GetRace() == self.VampBeast then self.VampChangeTracker:ShiftBack() end
		self:OnTick()
	end

	function Locking:OnTick()
		if rt.cast(self.VampChangeTracker, "DLC1PlayerVampireChangeScript").back.name ~= "Idle" then return end
		self.locking = false
		self:GotoState("")
		self.DLC1VampireLordDisallow:SetValueInt(1)
	end
end
