-- pex: completechange 20623987 0319753f
-- pex: playerchangedlocationcompletechange 73187c85
-- pex: harkonbitesplayer f63604d2 1a9072f9
-- pex: receiveharkonsgift f51ac462 27633a4a
-- ReceiveHarkonsGift waited for PlayerVampireQuest.VampireChange (or 3 s if the player already was
-- a vampire) before the cure and the powers; HarkonBitesPlayer waited for the gift, or 5 s on a
-- refusal. Each is now a run stepped by OnTick in "Busy"; callers wait while `gift` is not Idle.
-- CompleteChange and PlayerChangedLocationCompleteChange need no change: ForceRefInto never waits now.
local rt = require('skymod.rt')

return function(C)
	C.Gift = rt.sequence("Idle", "Turning")
	C.Bite = rt.sequence("Idle", "Gifting", "Refusing")
	local G, B = C.Gift, C.Bite
	local v = C.__vars
	v.gift, v.gift_t = G.Idle, rt.timer(0.0)
	v.bite, v.bite_t = B.Idle, rt.timer(0.0)
	v.TickRate = rt.float(0.1)
	local Busy = rt.state(C, "Busy")
	rt.params(C, "ReceiveHarkonsGift", { { "GiftGiver" }, { "IsSeranaGiving", false }, { "PlayStandardBiteAnim", true } })
	rt.params(C, "HarkonBitesPlayer", { { "isPlayerRecieveingHarkonsGift", true } })

	local function player() return rt.static("Game", "GetPlayer") end
	local function busy(self)
		if self:GetState() ~= "Busy" then self:GotoState("Busy") end
	end

	function C:ReceiveHarkonsGift(GiftGiver, IsSeranaGiving, PlayStandardBiteAnim)
		if self.gift ~= G.Idle then return end
		local p = player()
		self.gift = G.Turning
		self.gift_t = 0.0
		busy(self)
		GiftGiver:PlayIdleWithTarget(PlayStandardBiteAnim and self.IdleVampireStandingFeedFront_Loose or self.pa_VampireLordChangePlayer, p)
		if p:GetRace():HasKeyword(self.Vampire) then
			self.gift_t = 3.0
		else
			self.PlayerVampireQuest:VampireChange(p)
		end
	end

	local function gift_tick(self)
		if self.gift ~= G.Turning or self.gift_t > 0 then return end
		if self.PlayerVampireQuest.change.name ~= "Idle" then return end
		self.gift = G.Idle
		if self.C00.PlayerHasBeastBlood then self.C00:CurePlayer() end
		player():AddSpell(self.DLC1VampireChange)
		player():AddPerk(self.DLC1VampireTurnPerk)
	end

	function C:HarkonBitesPlayer(isPlayerRecieveingHarkonsGift)
		if self.bite ~= B.Idle then return end
		busy(self)
		if isPlayerRecieveingHarkonsGift then
			self.bite = B.Gifting
			self.DLC1HarkonBiteFadeToBlackImod:Apply()
			self:ReceiveHarkonsGift(self.DLC1HarknonActorRef, false, false)
		else
			self.bite = B.Refusing
			self.bite_t = 5.0
			self.DLC1HarkonBiteFadeToBlackImod:Apply()
		end
	end

	local function bite_tick(self)
		local p = player()
		if self.bite == B.Gifting and self.gift == G.Idle then
			self.bite = B.Idle
			p:PlayIdle(self.DLC1PairEnd)
			p:MoveTo(self.DLC1VQ02PlayerWakeupMarker)
			self:HarkonChangeBackFromVampireLord()
			self.DLC1HarknonActorRef:MoveTo(self.DLC1VQ02HarkonWakeupMarker)
			self.DLC1HarkonBiteFadeToBlackImod:PopTo(self.SleepyTimeFadeIn)
			self.DLC1VQ02:SetStage(40)
		elseif self.bite == B.Refusing and self.bite_t <= 0 then
			self.bite = B.Idle
			p:MoveTo(self.DLC1VQ02PlayerWakeupMarkerReject)
			self.DLC1HarkonBiteFadeToBlackImod:PopTo(self.SleepyTimeFadeIn)
			self.DLC1VQ02:SetStage(30)
		end
	end

	-- the gift first, so the bite sees a gift that ended this tick
	function Busy:OnTick()
		gift_tick(self)
		bite_tick(self)
		if self.gift == G.Idle and self.bite == B.Idle then self:GotoState("") end
	end
end
