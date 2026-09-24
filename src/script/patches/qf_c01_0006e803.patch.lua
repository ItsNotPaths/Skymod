-- pex: fragment_2 df790a11
-- pex: fragment_4 b486d11d
-- Fragment_2 set up the observer after SwapFollowers (2 s dismissal) returned; Fragment_4 shut
-- down the radiant quests after CompleteStoryQuest returned. Both callees now return at once, so
-- the rest of each waits in state "Waiting" for the fact it needs; the state ends when neither is owed.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.observerOwed = rt.bool(false) -- the observer is not set up as the follower yet
	C.__vars.shutdownOwed = rt.bool(false) -- the radiant quests are not shut down yet
	local Waiting = rt.state(C, "Waiting")

	local function central(self) return rt.cast(rt.cast(self, "C01QuestScript").CentralQuest, "CompanionsHousekeepingScript") end

	function C:Fragment_2()
		if self.observerOwed then return end
		if not self:GetStageDone(20) then self:SetObjectiveCompleted(10, true) end -- Skjor observed, stage 20 never ran
		self.Alias_DungeonMarker:GetReference():AddToMap()
		self.ToggleMarker:Disable()
		self.Alias_MacGuffin:GetRef():SetNoFavorAllowed(true)
		self.Alias_Observer:GetActorReference():SetPlayerTeammate(true, false)
		self.observerOwed = true
		self:GotoState("Waiting")
		central(self):SwapFollowers()
		self:OnTick()
	end

	function C:Fragment_4()
		if self.shutdownOwed then return end
		local c00, observer = central(self), self.Alias_Observer:GetActorReference()
		rt.cast(self.FragmentTracking, "CompanionsBladeFragmentTracking"):ReturnFragment(self.Alias_MacGuffin:GetRef())
		rt.static("Game", "GetPlayer"):RemoveItem(self.Alias_MacGuffin:GetRef(), 1)
		observer:SetPlayerTeammate(false, false)
		c00:CleanupFollowerState()
		c00:UnShutup(observer)
		c00.CurrentFollower:Clear()
		self.Alias_Observer:GetActorRef():AddToFaction(self.IsGuardFaction)
		self.shutdownOwed = true
		self:GotoState("Waiting")
		c00:CompleteStoryQuest(rt.cast(self, "C01QuestScript"))
		self:OnTick()
	end

	function Waiting:OnTick()
		local c00 = central(self)
		if self.observerOwed and c00.FollowerScript:GetState() ~= "Dismissing" then
			self.observerOwed = false
			local observer = self.Alias_Observer:GetActorReference()
			c00:Shutup(observer)
			c00.CurrentFollower:ForceRefTo(self.Alias_Observer:GetRef())
			self.Alias_Observer:GetActorRef():RemoveFromFaction(self.IsGuardFaction)
			self:SetObjectiveCompleted(20, true)
			self:SetObjectiveDisplayed(30, true)
		end
		if self.shutdownOwed and not c00.endingStory then
			self.shutdownOwed = false
			c00:ShutDownRadiantQuests()
		end
		if not self.observerOwed and not self.shutdownOwed then self:GotoState("") end
	end
end
