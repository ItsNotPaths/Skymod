-- pex: openbook dc8d5074
-- pex: showrewards ca1f51bc
-- pex: waiting.onactivate f90e7608
-- pex: showpowerprompt 1c61cc81
-- OpenBook played Stage1 and waited for "Open"; ShowRewards opened the book first, then played
-- Stage2 and waited for "Done" before enabling the three reward activators. Activating went Busy
-- until the controller's read and the rewards were over. Now the events end each animation;
-- `opening` and `showing` are the runs, and Busy waits in OnTick. ShowPowerPrompt (called by a
-- reward activator, any time, in or out of Busy) asked which power to learn; `answerPower` reads
-- the pick from both OnTick and Busy's.
local rt = require('skymod.rt')

return function(C)
	C.__vars.opening = rt.bool(false)
	C.__vars.showing = rt.bool(false)
	C.__vars.askingPower = rt.bool(false)
	C.__vars.powerActivator = rt.form("ObjectReference")
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "Busy")

	local function controller(self) return rt.cast(self.DLC2BookDungeonController, "DLC2BookDungeonControllerScript") end

	local function power_message(self, activator)
		if activator == self.RewardActivator01 then return self.AbilityPrompt01 end
		if activator == self.RewardActivator02 then return self.AbilityPrompt02 end
		if activator == self.RewardActivator03 then return self.AbilityPrompt03 end
	end

	local function answerPower(self)
		if not self.askingPower then return end
		local msg = power_message(self, self.powerActivator)
		local choice = msg:Answer()
		if choice < 0 then return msg:Show() end
		self.askingPower = false
		if choice ~= 0 then return end
		self:SetPower(self.powerActivator)
		self:EnableToSolstheimActivator()
	end

	function C:ShowPowerPrompt(rewardActivator)
		if self.askingPower then return end -- a call while it waits is dropped
		local msg = power_message(self, rewardActivator)
		if not msg then return end
		self.powerActivator = rewardActivator
		self.askingPower = true
		msg:Show()
	end

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

	function C:OnTick()
		answerPower(self)
	end

	function Busy:OnTick()
		answerPower(self)
		local c = controller(self)
		if c.read.name == "Idle" and not c.rewards_book and not self.showing then self:GotoState("Waiting") end
	end
end
