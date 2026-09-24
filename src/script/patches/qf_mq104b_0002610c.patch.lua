-- pex: fragment_47 f4854c91
-- Stage 200 put the watchtower's fort back in the war, then removed the created soldiers and
-- stopped the quest once setOwner's reset was done. That clean-up now waits for CWScript's
-- resettingGarrisons.
local rt = require('skymod.rt')

return function(C)
	C.__vars.cleanupOwed = rt.bool(false)
	local split_tick = C.__fn.ontick

	local function remove(ref)
		ref:Disable()
		ref:Delete()
	end

	local function cleanup_tick(self)
		if not self.cleanupOwed or rt.cast(self.CW, "CWScript").resettingGarrisons then return end
		self.cleanupOwed = false
		remove(self.Alias_Messenger:GetReference())
		remove(self.Alias_Survivor:GetRef())
		for i = 1, 6 do remove(self["Alias_Soldier" .. i]:GetReference()) end
		self:Stop()
	end

	function C:Fragment_47()
		if self.cleanupOwed then return end
		self:UnregisterForUpdate()
		self.FortAttackFXEnableMarker:Disable()     -- attack FX (fires) off
		self.FortAttackNearbySpawnsMarker:Enable()  -- nearby encounters back
		self.FortSoldiersEnableMarker:Enable()      -- normal soldiers on
		self.cleanupOwed = true
		rt.cast(self.CW, "CWScript"):AddGarrisonBackToWar(rt.cast(self, "MQ104Script").FortLocation, 0, false)
		cleanup_tick(self)
	end

	function C:OnTick()
		split_tick(self)
		cleanup_tick(self)
	end
end
