-- pex: oncellattach d7681b40
-- OnCellAttach played the sound, then waited RandomFloat(delayMin, delayMax), while bRunning and
-- loaded. The loop is now OnTick in the running state, on a timer.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.delayT = rt.timer(0.0)
	local Running = rt.state(C, "Running")

	function C:OnCellAttach()
		self.bRunning = true
		self.delayT = 0.0
		self:GotoState("Running")
		self:OnTick()
	end

	function Running:OnTick()
		if self.delayT > 0 then return end
		if not (self.bRunning and self:Is3DLoaded()) then return self:GotoState("") end
		self.SoundDescriptor:Play(self)
		self.delayT = self.delayT + rt.static("Utility", "RandomFloat", self.delayMin, self.delayMax)
	end
end
