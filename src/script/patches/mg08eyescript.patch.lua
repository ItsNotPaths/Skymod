-- pex: onmagiceffectapply 7e8091dd
-- The Eye of Magnus: the staff closes it for 10 s; Ancano's spell spawns an anomaly after 1 s and
-- reopens it for 10 s. EyeReady is the original's own busy guard. The quest script (MG08Script),
-- carried across the waits in Papyrus, is cast again from the MG08 property after each wait.
local rt = require('skymod.rt')

local Eye = rt.sequence("Idle", "Closed", "Charging", "Opened")

return function(C)
	C.__vars.eye = Eye.Idle
	C.__vars.eyeWait = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	local function quest(self) return rt.cast(self.MG08, "mg08questscript") end

	function C:OnMagicEffectApply(Caster, Effect)
		if quest(self).GoTime ~= 1 or self.EyeReady ~= 1 then return end
		local ancano = self.Ancano
		if Effect == self.StaffEffect then
			self.EyeReady = 0
			ancano:GetActorReference():SetGhost(false)
			self.AncanoEffect:Stop(ancano:GetReference())
			self:GetReference():PlayAnimation("Close")
			self.eye, self.eyeWait = Eye.Closed, 10.0
		elseif Effect == self.MG08AncanoSpellEffect then
			self.EyeReady = 0
			self.eye, self.eyeWait = Eye.Charging, 1.0
		end
	end

	function C:OnTick()
		if self.eye == Eye.Idle or self.eyeWait > 0 then return end
		if self.eye == Eye.Closed then
			quest(self).AncanoShield = 0
			self.EyeReady = 1
			self.eye = Eye.Idle
		elseif self.eye == Eye.Charging then
			self.eye, self.eyeWait = Eye.Opened, self.eyeWait + 10.0
			self.CreatureSpawnInt = rt.static("Utility", "RandomInt", 0, 2)
			local marker = ({ self.CreatureMarker1, self.CreatureMarker2, self.CreatureMarker3 })[self.CreatureSpawnInt]
			marker:PlaceAtMe(self.EncMagicAnomaly, 1, false, false)
			local ancano = self.Ancano
			ancano:GetActorReference():SetGhost()
			self.AncanoEffect:Play(ancano:GetReference(), -1.0)
			ancano:GetActorReference():EvaluatePackage()
			quest(self).AncanoShield = 1
			self:GetReference():PlayAnimation("Open")
		elseif self.eye == Eye.Opened then
			self.EyeReady = 1
			self.eye = Eye.Idle
		end
	end
end
