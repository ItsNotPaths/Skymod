-- pex: waiting.onactivate e8bc7354
-- With the witch's head in hand the sconce asked to cure lycanthropy; button 0 removed the head,
-- disabled the wolf spirit and moved to state done. OnTick in Waiting reads the pick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)
	local Waiting = rt.state(C, "Waiting")

	function Waiting:OnActivate(akActivator)
		if self.CR13:IsRunning() or self.C06:IsRunning() then return end
		if akActivator ~= rt.static("Game", "GetPlayer") then return end
		if not self.C00.PlayerHasBeastBlood then return end
		if rt.static("Game", "GetPlayer"):GetItemCount(self.WitchHead) <= 0 then return end
		self.asking = true
		self.CureMessage:Show()
	end

	function Waiting:OnTick()
		if not self.asking then return end
		local choice = self.CureMessage:Answer()
		if choice < 0 then return self.CureMessage:Show() end
		self.asking = false
		if choice ~= 0 then return end
		self:GotoState("done")
		rt.static("Game", "GetPlayer"):RemoveItem(self.WitchHead, 1, false)
		self.WolfSpirit:GetReference():Enable(false)
	end
end
