-- pex: fragment_1 1765f7d7
-- The ambush waited for PlayerWerewolfChangeScript.ShiftBack before it took the controls and set
-- the bounty. It now waits in "ShiftingBack" until the werewolf's `back` run is Idle.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local ShiftingBack = rt.state(C, "ShiftingBack")

	local function werewolf(self) return rt.cast(self.PlayerWerewolfQuest, "PlayerWerewolfChangeScript") end

	local function arrest(self)
		local p = rt.static("Game", "GetPlayer")
		if self.DLC1PlayerVampireQuest:IsRunning() then self.DLC1RevertForm:Cast(p, p) end
		rt.static("Game", "DisablePlayerControls")
		self.HaafingarFaction:ModCrimeGold(1500)
	end

	function C:Fragment_1()
		if not self.PlayerWerewolfQuest:IsRunning() then return arrest(self) end
		self:GotoState("ShiftingBack")
		werewolf(self):ShiftBack()
		self:OnTick()
	end

	function ShiftingBack:Fragment_1() end -- a run is under way

	function ShiftingBack:OnTick()
		if werewolf(self).back.name ~= "Idle" then return end
		self:GotoState("")
		arrest(self)
	end
end
