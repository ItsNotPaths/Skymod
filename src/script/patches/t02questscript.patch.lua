-- pex: listenforanimevents 6d8d04fd
-- ListenForAnimEvents, the latent callee of SF_T02FenrigRuki Fragment_0: wait (poll 0.1 s) for
-- Fenrig's 3D, register for his T02Ascend, then the same for Ruki. Start-and-return; the fragment
-- calls it last, so the fragment itself needs no change. Polls in state Listening only.
local rt = require('skymod.rt')

local function trace(msg) rt.static("Debug", "Trace", "T02: " .. msg) end

return function(C)
	C.Listen = rt.sequence("Idle", "Fenrig", "Ruki", "Done")
	C.__vars.listen = C.Listen.Idle
	C.__vars.TickRate = rt.float(0.1) -- the original polls with Wait(0.1)
	local Listen = C.Listen

	function C:ListenForAnimEvents()
		if self.listen == Listen.Fenrig or self.listen == Listen.Ruki then return end
		self.listen = Listen.Fenrig
		self:GotoState("Listening")
		trace("listening, waiting for Fenrig's 3D")
		self:OnTick()
	end

	local Listening = rt.state(C, "Listening")
	function Listening:OnTick()
		local alias = self.listen == Listen.Fenrig and self.Fenrig or self.Ruki
		if not alias:GetActorReference():Is3DLoaded() then return end
		self:RegisterForAnimationEvent(alias:GetActorRef(), "T02Ascend")
		trace("registered for T02Ascend on " .. tostring(alias:GetActorRef()))
		self.listen = self.listen + 1
		if self.listen == Listen.Done then self:GotoState("") end
	end
end
