-- pex: handleplayersat a8c5daaa
-- pex: trytotravel f18623e3
-- HandlePlayerSat still decides accept/reject synchronously (dead driver, combat, encumbered, no
-- destination); once accepted it used to block for the whole ride (chatter, fade, fade, travel).
-- It now returns true as soon as the ride starts, and a stopwatch plus a stage finish it in
-- OnTick. TryToTravel forwards that same true/false and needs no change.
local rt = require('skymod.rt')

local function trace(msg) rt.static("Debug", "Trace", "CarriageSystem: " .. msg) end

local Ride = rt.sequence("Idle", "Chatter", "FadeOut", "Hold")

return function(C)
	C.__vars.ride = Ride.Idle
	C.__vars.rideWait = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	function C:HandlePlayerSat()
		if self.ride ~= Ride.Idle then
			trace("HandlePlayerSat dropped: a ride is under way")
			return false
		end
		local player = rt.static("Game", "GetPlayer")
		if self.kCurrentDriver:IsDead() then
			self:ClearWaitingState()
			return false
		end
		if player:IsInCombat() then return false end
		if self.bPreventPlayerTravelingOverencumbered
			and player:GetActorValue(self.sInventoryWeightAV) > player:GetActorValue(self.sCarryWeightAV) then
			return false
		end
		if not self.kTargetDestination then return false end

		rt.static("Game", "DisablePlayerControls")
		local driverScript = rt.cast(self.kCurrentDriver, "carriagedriverscript")
		if driverScript and driverScript.bSitting then
			self.kCurrentDriver:PlayIdle(self.IdleCartDriverIdle)
		end
		self:PayForCarriage()
		self.kCurrentDriver:SetActorValue(self.sDriverChatterControlAV, 2)
		self.kCurrentDriver:Say(self.DialogueCarriageChatterTopic)
		self.ride = Ride.Chatter
		self.rideWait = self.gAllowCarriageDriverChatterTime:GetValue()
		trace("player sat; chatter for " .. self.rideWait .. " s")
		return true
	end

	-- the class already ticks for the mechanical OnUpdate split; keep it running every tick,
	-- and never put this in a state (script-api.md, "A class that already has OnTick")
	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.ride == Ride.Idle or self.rideWait > 0 then return end
		if self.ride == Ride.Chatter then
			self.ride = Ride.FadeOut
			self.rideWait = self.rideWait + 2.0
			self.FadeToBlackImod:Apply()
			trace("fade out")
		elseif self.ride == Ride.FadeOut then
			self.ride = Ride.Hold
			self.rideWait = self.rideWait + 2.0
			self.FadeToBlackImod:PopTo(self.FadeToBlackHoldImod)
			trace("hold black")
		else
			self.ride = Ride.Idle
			self.kCurrentDriver:SetActorValue(self.sDriverChatterControlAV, 0)
			self:SkipToDestinationSimple()
			rt.static("Game", "EnablePlayerControls")
			trace("arrived; controls back")
		end
	end
end
