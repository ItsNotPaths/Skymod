-- pex: dismissfollower 95ed6940
-- DismissFollower waited 2 s for the follower's parting line before it cleared the alias. It now
-- returns at once; state "Dismissing" is the published fact until the alias is cleared.
local rt = require('skymod.rt')

local messages = { "FollowerDismissMessage", "FollowerDismissMessageWedding", "FollowerDismissMessageCompanions",
	"FollowerDismissMessageCompanionsMale", "FollowerDismissMessageCompanionsFemale", "FollowerDismissMessageWait" }

return function(C)
	C.__vars.dismissMessage = rt.int(0)
	C.__vars.sayLine = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	rt.params(C, "DismissFollower", { { "iMessage", 0 }, { "iSayLine", 1 } })
	local Dismissing = rt.state(C, "Dismissing")

	local function finish(self)
		self.pFollowerAlias:Clear()
		self.iFollowerDismiss = 0
		if self.dismissMessage ~= 2 then self.pPlayerFollowerCount:SetValue(0) end -- Companions replace the follower
	end

	function C:DismissFollower(iMessage, iSayLine)
		if self:GetState() == "Dismissing" then return end
		local follower = self.pFollowerAlias and self.pFollowerAlias:GetActorRef()
		if not follower or follower:IsDead() then return end
		self[messages[iMessage] or messages[0]]:Show()
		follower:StopCombatAlarm()
		follower:AddToFaction(self.pDismissedFollower)
		follower:SetPlayerTeammate(false)
		follower:RemoveFromFaction(self.pCurrentHireling)
		follower:SetAV("WaitingForPlayer", 0)
		follower:RemoveItem(self.FollowerHuntingBow, 999, true)
		follower:RemoveItem(self.FollowerIronArrow, 999, true)
		self.HirelingRehireScript:DismissHireling(follower:GetActorBase())
		self.dismissMessage = iMessage
		if iSayLine ~= 1 then return finish(self) end
		self:GotoState("Dismissing")
		self.sayLine = 2.0
		self.iFollowerDismiss = 1
		follower:EvaluatePackage()
	end

	function Dismissing:OnTick()
		if self.sayLine > 0 then return end
		self:GotoState("")
		finish(self)
	end
end
