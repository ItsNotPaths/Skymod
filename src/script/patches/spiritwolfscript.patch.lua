-- pex: extract 27400f9b
-- Extract woke after Utility.Wait(1) to play the VFX, sound, and idle-sync check, then the ghost
-- shader. Now Extract starts a timer; OnTick in the Extracting state runs the rest when it is due.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.Stage = rt.sequence("Idle", "Extracting")
	C.__vars.stage = C.Stage.Idle
	C.__vars.extractPartner = rt.form("Actor")
	C.__vars.extractT = rt.timer(0.0)
	local Extracting = rt.state(C, "Extracting")

	function C:Extract(extractionPartner)
		if self.stage ~= C.Stage.Idle then return end -- a second start is dropped
		self.stage = C.Stage.Extracting
		self.extractPartner = extractionPartner
		self.extractT = 1.0
		self:Enable()
		self:SetAlpha(0)
		self:GotoState("Extracting")
	end

	function Extracting:OnTick()
		if self.extractT > 0 then return end
		local partner = self.extractPartner
		self.WerewolfExtractVFX:Play(partner, -1.0, self)
		self.QSTWolfChest:Play(partner)
		if partner:PlayIdleWithTarget(self.pa_ExtractWereWolfSpirit, self) then
			rt.static("Debug", "Trace", "C06: Played synced anim.")
		else
			rt.static("Debug", "Trace", "C06: Failed anim.")
		end
		self:SetAlpha(0.3)
		self.GhostShader:Play(self, -1.0)
		self:EvaluatePackage()
		self.stage = C.Stage.Idle
		self:GotoState("")
	end
end
