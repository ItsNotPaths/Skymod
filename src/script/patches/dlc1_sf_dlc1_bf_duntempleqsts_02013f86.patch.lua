-- pex: fragment_0 ac05be23
-- The scene shifted a werewolf player back, and only then checked for a Vampire Lord to shift
-- back. It now waits in "ShiftingBack" until the werewolf's `back` run is Idle.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local ShiftingBack = rt.state(C, "ShiftingBack")

	local function quest(self) return rt.cast(self:GetOwningQuest(), "DLC1_BF_DunTempleQstSCRIPT") end
	local function werewolf(self) return rt.cast(quest(self).PlayerWerewolfQuest, "PlayerWerewolfChangeScript") end

	local function vampire(self)
		local q = quest(self).DLC1PlayerVampireQuest
		if q:IsRunning() then rt.cast(q, "DLC1PlayerVampireChangeScript"):ShiftBack() end
	end

	function C:Fragment_0()
		if not quest(self).PlayerWerewolfQuest:IsRunning() then return vampire(self) end
		self:GotoState("ShiftingBack")
		werewolf(self):ShiftBack()
		self:OnTick()
	end

	function ShiftingBack:Fragment_0() end -- a run is under way

	function ShiftingBack:OnTick()
		if werewolf(self).back.name ~= "Idle" then return end
		self:GotoState("")
		vampire(self)
	end
end
