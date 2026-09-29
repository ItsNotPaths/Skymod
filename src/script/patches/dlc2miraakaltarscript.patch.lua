-- pex: openbook be36fed5
-- pex: showrewards 41e8b61c 0a38b278
-- pex: waiting.onactivate 019d8ccb
-- pex: constellationactivated 04e2502f
-- OpenBook played Stage1 and waited for "Open"; ShowRewards then lit the constellations along the
-- LinkCustom01 chain 0.1 s apart and enabled the way back. Activating went Busy until the read and
-- the rewards were over. Now "Open" ends the opening, `next_star` is the next constellation to
-- light, and OnTick steps both. ConstellationActivated (a linked activator) asked to confirm a
-- perk buy; OnTick reads that pick too, alongside the two loops above.
local rt = require('skymod.rt')

return function(C)
	C.__vars.opening = rt.bool(false)
	C.__vars.showing = rt.bool(false)
	C.__vars.next_star = rt.form("ObjectReference")
	C.__vars.star_t = rt.timer(0.0)
	C.__vars.askingConfirm = rt.bool(false)
	C.__vars.confirmSkill = rt.int(0)
	C.__vars.confirmCount = rt.int(0)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "Busy")

	local function controller(self) return rt.cast(self.DLC2BookDungeonController, "DLC2BookDungeonControllerScript") end

	local function confirm_message(self, constellationID, iPerkCount)
		local list = iPerkCount == 1 and self.DLC2AltarSkillMessagesSingular or self.DLC2AltarSkillMessagesPlural
		return list:GetAt(constellationID)
	end

	local function light(self)
		rt.static("Game", "GetPlayer"):PlaceAtMe(self.ExplosionIllusionMassiveLight01)
		self.next_star = self:GetLinkedRef(self.LinkCustom01)
		self.star_t = 0.0
		self:OnTick()
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
		if not self.opening then light(self) end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Open" or not self.opening then return end
		self.opening = false
		if self.showing then light(self) end
	end

	function C:ConstellationActivated(constellation, constellationID)
		local player = rt.static("Game", "GetPlayer")
		local iPerkCount = self:CountPerks(constellationID, false)
		if player:IsInCombat() then return self.DLC2AltarNotInCombatMSG:Show() end
		if player:GetActorValue("DragonSouls") == 0 then return self.DLC2AltarNoSoulsMSG:Show() end
		if iPerkCount == 0 then return self.DLC2AltarNoPerksInThisSkillMSG:Show() end
		self.confirmSkill, self.confirmCount = constellationID, iPerkCount
		self.askingConfirm = true
		confirm_message(self, constellationID, iPerkCount):Show(iPerkCount)
	end

	function C:OnTick()
		if self.askingConfirm then
			local msg = confirm_message(self, self.confirmSkill, self.confirmCount)
			local confirmed = msg:Answer()
			if confirmed < 0 then
				msg:Show(self.confirmCount)
			else
				self.askingConfirm = false
				if confirmed == 1 then
					local player = rt.static("Game", "GetPlayer")
					self.DLC2ApocryphaRewardSpell:Cast(player, rt.None)
					player:ModActorValue("DragonSouls", -1)
					local iPerkPoints = self:CountPerks(self.confirmSkill, true)
					rt.static("Game", "AddPerkPoints", iPerkPoints)
					if iPerkPoints > 1 then self.DLC2AltarPerkPointsRefundedPlural:Show(iPerkPoints)
					else self.DLC2AltarPerkPointsRefundedSingular:Show(iPerkPoints) end
				end
			end
		end
		if self.showing and not self.opening and self.star_t <= 0 then
			if self.next_star then
				self.next_star:EnableNoWait(true)
				self.next_star = self.next_star:GetLinkedRef(self.LinkCustom01)
				self.star_t = self.star_t + 0.1
			else
				self:EnableToSolstheimActivator()
				self.rewardsShown = true
				self.showing = false
			end
		end
		if self:GetState() == "Busy" then
			local c = controller(self)
			if c.read.name == "Idle" and not c.rewards_book and not self.showing then self:GotoState("Waiting") end
		end
	end

	function Waiting:OnActivate(akActivator)
		if akActivator ~= rt.static("Game", "GetPlayer") then return end
		self:GotoState("Busy")
		controller(self):ReadApocryphaBook(self, false, true, self.rewardsShown, true)
		self:OnTick()
	end
end
