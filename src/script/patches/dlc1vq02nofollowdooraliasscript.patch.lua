-- pex: waiting.onactivate 02c12cfa
-- A werewolf player at the blocked door waited for PlayerWerewolfChangeScript.ShiftBack, then the
-- door let them through. The door now stays Busy until the werewolf's `back` run is Idle.
local rt = require('skymod.rt')

return function(C)
	C.__vars.passer = rt.form("ObjectReference") -- the player the door lets through after the shift back
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "Busy")

	local function allowed(self, actorRef)
		if not actorRef then return false end
		for _, f in ipairs({ self.AllowDoorFaction01, self.AllowDoorFaction02, self.AllowDoorFaction03 }) do
			if actorRef:IsInFaction(f) then return true end
		end
		return self.myQuest and self.myQuest:GetStageDone(self.myQuestStage)
	end

	function Waiting:OnActivate(akActionRef)
		self:GotoState("Busy")
		if not self:GetReference():IsActivationBlocked() then return end -- stays Busy, as Papyrus does
		if akActionRef == rt.static("Game", "GetPlayer") then
			local q = self.PlayerWerewolfQuest
			if rt.cast(akActionRef, "Actor"):HasMagicEffect(self.WerewolfChangeEffect) or q:IsRunning() then
				rt.static("Game", "DisablePlayerControls", { abMovement = false, abFighting = true, abCamSwitch = false,
					abLooking = false, abSneaking = false, abMenu = true, abActivate = false, abJournalTabs = false })
				self.passer = akActionRef
				rt.cast(q, "PlayerWerewolfChangeScript"):ShiftBack()
				return self:OnTick()
			elseif self.isMainDoor then
				self:GetReference():Activate(akActionRef, true)
			end
		elseif allowed(self, rt.cast(akActionRef, "Actor")) then
			self:GetReference():Activate(akActionRef, true)
		elseif self.DoOnce == 0 then
			self.FollowerBlockedMessage:Show()
			self.DoOnce = 1
		end
		self:GotoState("Waiting")
	end

	function Busy:OnTick()
		if not self.passer then return end
		if rt.cast(self.PlayerWerewolfQuest, "PlayerWerewolfChangeScript").back.name ~= "Idle" then return end
		local passer = self.passer
		self.passer = rt.None
		self:GotoState("Waiting")
		self:GetReference():Activate(passer, true)
	end
end
