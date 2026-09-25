-- pex: fadein 23d3238f
-- pex: fadeout 511de094
-- pex: firsttimetravel 713fe08e edd7b922
-- pex: setsail 9b8eeb92 e70abdf2
-- SetSail waited for Gjalund to stop talking, faded out (2.1 s), travelled and faded in (3 s).
-- The first trip to Solstheim instead rode the boat: fade in, 7 s, the ride idle's
-- BoatRideFadeOut event, fade out, 2 s of FinishBoatRide, then up to 3 s for the boat to load.
-- Now `sail` is the step, `sail_t` its clock, and the player's event ends the ride.
local rt = require('skymod.rt')

return function(C)
	C.Sail = rt.sequence("Idle", "Talking", "FadingOut", "RideFadingIn", "Riding", "RideEnding",
		"RideFadingOut", "Disembarking", "BoatLoading", "FadingIn")
	local S = C.Sail
	C.__vars.sail = S.Idle
	C.__vars.sail_t = rt.timer(0.0)
	C.__vars.speaker = rt.form("Actor")
	C.__vars.cost = rt.int(1)
	C.__vars.TickRate = rt.float(0.1)
	local split_tick = C.__fn.ontick

	local function player() return rt.static("Game", "GetPlayer") end
	local function go(self, step, t)
		self.sail = step
		self.sail_t = t or 0.0
	end

	function C:FadeOut() self.FadeToBlack:Apply() end
	function C:FadeIn() self.HoldBlack:PopTo(self.FadeFromBlack) end

	function C:SetSail(akSpeaker, iCostFlag)
		if self.sail ~= S.Idle then return end
		self.speaker, self.cost = akSpeaker, iCostFlag or 1
		rt.static("Game", "DisablePlayerControls", true, true, true, true, true, true, true, true)
		player():StopCombatAlarm()
		go(self, S.Talking)
		self:OnTick()
	end

	function C:FirstTimeTravel()
		self.RidingTheBoat = true
		rt.static("Game", "ForceFirstPerson")
		self.DLC2RRASGjalundAlias:GetActorRef():MoveTo(self.GjalundOutOfSightMarker)
		for i = 0, rt.alen(self.DisableList) - 1 do self.DisableList[i]:DisableNoWait() end
		self.BoatNavmeshCutter:Enable()
		rt.static("Game", "FastTravel", self.BoatRideTarget)
		self:StowFollowers()
		player():PlayIdle(self.BoatRideAnim)
		self.ArrivalMusic:Add()
		self:FadeIn()
		go(self, S.RideFadingIn, 3.0)
	end

	local function pay(self)
		local price = (self.cost == 1 and self.DLC2CostToSail) or (self.cost == 2 and self.DLC2CostToSailx2)
		if price then player():RemoveItem(self.pGold001, price:GetValueInt()) end
	end

	local function arrive(self)
		rt.static("Game", "EnablePlayerControls")
		self:FadeIn()
		go(self, S.FadingIn, 3.0)
	end

	local function sail_tick(self)
		local s = self.sail
		if s == S.Idle or self.sail_t > 0 then return end
		if s == S.Talking then
			if self.speaker:IsInDialogueWithPlayer() then return end
			self:FadeOut()
			go(self, S.FadingOut, 2.1)
		elseif s == S.FadingOut then
			self.FadeToBlack:PopTo(self.HoldBlack)
			pay(self)
			if player():GetWorldSpace() == self.DLC2SolstheimWorld then
				rt.static("Game", "FastTravel", self.pDLC2RRWindhelmLandingMarker)
				arrive(self)
			elseif self.FirstTimeToSolstheim then
				self.FirstTimeToSolstheim = false
				self:FirstTimeTravel()
			else
				rt.static("Game", "FastTravel", self.pDLC2RRSolstheimLandingMarker)
				arrive(self)
			end
		elseif s == S.RideFadingIn then
			self.FadeFromBlack:Remove()
			go(self, S.Riding, 7.0)
		elseif s == S.Riding then
			self.GjalundShouldTalk = true
			self:RegisterForAnimationEvent(player(), "BoatRideFadeOut")
			go(self, S.RideEnding)
		elseif s == S.RideFadingOut then
			self.FadeToBlack:PopTo(self.HoldBlack)
			player():PlayIdle(self.IdleStop)
			self:FinishBoatRide()
			go(self, S.Disembarking, 2.0)
		elseif s == S.Disembarking then
			self.RidingTheBoat = false
			go(self, S.BoatLoading, 3.0)
		elseif s == S.FadingIn then
			self.FadeFromBlack:Remove()
			go(self, S.Idle)
			rt.static("Game", "RequestAutoSave")
		end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if self.sail ~= S.RideEnding or akSource ~= player() or asEventName ~= "BoatRideFadeOut" then return end
		self:FadeOut()
		go(self, S.RideFadingOut, 2.1)
	end

	function C:OnTick()
		split_tick(self)
		-- the boat wait ends when it loads or after 3 s, so it is checked before the clock guard
		if self.sail == S.BoatLoading and (self.RavenRockBoat:Is3DLoaded() or self.sail_t <= 0) then arrive(self) end
		sail_tick(self)
	end
end
