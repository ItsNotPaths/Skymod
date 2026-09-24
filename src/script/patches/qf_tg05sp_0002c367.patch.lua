-- pex: fragment_0 fc7aaf31
-- Karliah's arrow waited for the werewolf's and then the Vampire Lord's ShiftBack, knocked the
-- player down, and 7 s later moved them to the down marker. The run is `arrow`, stepped by OnTick.
local rt = require('skymod.rt')

return function(C)
	C.Arrow = rt.sequence("Idle", "Werewolf", "Vampire", "Down")
	local A = C.Arrow
	C.__vars.arrow, C.__vars.arrow_t = A.Idle, rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Busy = rt.state(C, "Busy")

	local function player() return rt.static("Game", "GetPlayer") end
	local function werewolf(self) return rt.cast(self.WerewolfQuest, "PlayerWerewolfChangeScript") end
	local function vampire(self) return rt.cast(self.DLC1PlayerVampireQuest, "DLC1PlayerVampireChangeScript") end

	function C:Fragment_0()
		if self.arrow ~= A.Idle then return end
		self.arrow = A.Werewolf
		self:GotoState("Busy")
		if self.WerewolfQuest:IsRunning() then werewolf(self):ShiftBack() end
		self:OnTick()
	end

	function Busy:OnTick()
		if self.arrow == A.Werewolf then
			if werewolf(self).back.name ~= "Idle" then return end
			self.arrow = A.Vampire
			if self.DLC1PlayerVampireQuest:IsRunning() then vampire(self):ShiftBack() end
		end
		if self.arrow == A.Vampire then
			if vampire(self).back.name ~= "Idle" then return end
			self.arrow = A.Down
			self.arrow_t = 7.0
			self.Alias_TG05SPMercerAlias:GetActorRef():StopCombat()
			rt.static("Game", "ForceFirstPerson")
			self.pTG05ArrowHitRef:Enable()
			self.pStrikeandFall:Apply()
			rt.static("Game", "DisablePlayerControls", true, true, true, true, true, true)
			player():PlayIdle(self.pKnockdown)
			self.TG05UnconsciousAudioRef:Enable()
		elseif self.arrow == A.Down and self.arrow_t <= 0 then
			self.arrow = A.Idle
			self:GotoState("")
			player():MoveTo(rt.cast(self, "TG05SPQuestScript").pTG05PlayerDownMarker)
			local karliah = self.Alias_TG05SPKarliahAlias:GetActorRef()
			karliah:Enable()
			karliah:EvaluatePackage()
			self:SetStage(20)
		end
	end
end
