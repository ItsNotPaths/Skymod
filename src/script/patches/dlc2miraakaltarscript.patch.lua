-- pex: openbook be36fed5
-- pex: showrewards 41e8b61c 0a38b278
-- pex: waiting.onactivate 019d8ccb
-- OpenBook played Stage1 and waited for "Open"; ShowRewards then lit the constellations along the
-- LinkCustom01 chain 0.1 s apart and enabled the way back. Activating went Busy until the read and
-- the rewards were over. Now "Open" ends the opening, `next_star` is the next constellation to
-- light, and OnTick steps both.
local rt = require('skymod.rt')

return function(C)
	C.__vars.opening = rt.bool(false)
	C.__vars.showing = rt.bool(false)
	C.__vars.next_star = rt.form("ObjectReference")
	C.__vars.star_t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "Busy")

	local function controller(self) return rt.cast(self.DLC2BookDungeonController, "DLC2BookDungeonControllerScript") end

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

	function C:OnTick()
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
