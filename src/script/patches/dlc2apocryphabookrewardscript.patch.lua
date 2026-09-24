-- pex: openbook dc8d5074
-- pex: showrewards ca1f51bc
-- pex: waiting.onactivate f90e7608
-- OpenBook played Stage1 and waited for "Open"; ShowRewards opened the book first, then played
-- Stage2 and waited for "Done" before enabling the three reward activators. Activating went Busy
-- until the controller's read and the rewards were over. Now the events end each animation;
-- `opening` and `showing` are the runs, and Busy waits in OnTick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.opening = rt.bool(false)
	C.__vars.showing = rt.bool(false)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "Busy")

	local function controller(self) return rt.cast(self.DLC2BookDungeonController, "DLC2BookDungeonControllerScript") end

	local function reveal(self)
		self:DisableBothActivators()
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation("Stage2")
	end

	function C:OpenBook()
		if self.hasOpenedBook then return end
		self.hasOpenedBook = true
		self:DisableBothActivators()
		self.opening = true
		self:RegisterForAnimationEvent(self, "Open")
		self:PlayAnimation("Stage1")
	end

	function C:ShowRewards()
		if self.showing then return end
		self.showing = true
		self:OpenBook()
		if not self.opening then reveal(self) end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if asEventName == "Open" and self.opening then
			self.opening = false
			if self.showing then reveal(self) end
		elseif asEventName == "Done" and self.showing and not self.opening then
			self.RewardActivator01:Enable()
			self.RewardActivator02:Enable()
			self.RewardActivator03:Enable()
			self.rewardsShown = true
			self.showing = false
		end
	end

	function Waiting:OnActivate(akActivator)
		if akActivator ~= rt.static("Game", "GetPlayer") then return end
		self:GotoState("Busy")
		controller(self):ReadApocryphaBook(self, self.requireQuestStageToMove, self.requireRewardsShownToMove,
			self.rewardsShown, self.showRewardsOnActivation)
		self:OnTick()
	end

	function Busy:OnTick()
		local c = controller(self)
		if c.read.name == "Idle" and not c.rewards_book and not self.showing then self:GotoState("Waiting") end
	end
end
