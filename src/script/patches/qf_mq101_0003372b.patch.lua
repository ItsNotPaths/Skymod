-- pex: fragment_175 08772782
-- pex: fragment_27 1941028e
-- pex: fragment_156 e9ac7a8e
-- Fragment_175 (Helgen carts, stage 12): polled 0.2s while nine actors were not yet 3D loaded
-- (the original list skips Alias_StormcloakPrisoner01, kept as is), then tethered both carts,
-- waited 1s, and put everyone in place. A stage plus one timer now does the same in OnTick. The
-- class already ticks for other fragments' splits; call it first.
-- Fragment_27 and Fragment_156 (race menu, stages 10 and 5): each waited 1s, opened the race
-- menu, waited 1s more, then asked which side to take (already split by S6 into their own
-- `fragment_27.*`/`fragment_156.*` vars and OnTick, but the ask happens mid-split and can't be
-- reached there). Ours runs the two 1s waits itself, asks, and never touches the split's own vars
-- so its dormant continuation never fires.
local rt = require('skymod.rt')

return function(C)
	C.Cart = rt.sequence("Idle", "AwaitLoad", "Tethered")
	C.__vars.cart = C.Cart.Idle
	C.__vars.cartT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.2)
	local S = C.Cart

	local function all_loaded(self)
		return self.Alias_ImperialSoldier01:GetActorRef():Is3DLoaded()
			and self.Alias_Ralof:GetActorRef():Is3DLoaded()
			and self.Alias_Prisoner01:GetActorRef():Is3DLoaded()
			and self.Alias_Ulfric:GetActorRef():Is3DLoaded()
			and rt.static("Game", "GetPlayer"):Is3DLoaded()
			and self.Alias_ImperialSoldier02:GetActorRef():Is3DLoaded()
			and self.Alias_StormcloakPrisoner02:GetActorRef():Is3DLoaded()
			and self.Alias_StormcloakPrisoner03:GetActorRef():Is3DLoaded()
			and self.Alias_StormcloakPrisoner04:GetActorRef():Is3DLoaded()
	end

	local function board(self)
		local player = rt.static("Game", "GetPlayer")
		local i01, ralof, p01, ulfric = self.Alias_ImperialSoldier01:GetActorRef(), self.Alias_Ralof:GetActorRef(),
			self.Alias_Prisoner01:GetActorRef(), self.Alias_Ulfric:GetActorRef()
		local i02, sp01, sp02, sp03, sp04 = self.Alias_ImperialSoldier02:GetActorRef(), self.Alias_StormcloakPrisoner01:GetActorRef(),
			self.Alias_StormcloakPrisoner02:GetActorRef(), self.Alias_StormcloakPrisoner03:GetActorRef(), self.Alias_StormcloakPrisoner04:GetActorRef()
		local cart1, cart2 = self.Alias_Cart1:GetRef(), self.Alias_Cart2:GetRef()

		i01:SetVehicle(cart2); ralof:SetVehicle(cart2); p01:SetVehicle(cart2); ulfric:SetVehicle(cart2); player:SetVehicle(cart2)
		i02:SetVehicle(cart1); sp02:SetVehicle(cart1); sp03:SetVehicle(cart1); sp04:SetVehicle(cart1); sp01:SetVehicle(cart1)

		i01:PlayIdle(self.IdleCartDriverSway); ralof:PlayIdle(self.IdleCartPrisonerDSway)
		p01:PlayIdle(self.IdleCartPrisonerBSway); ulfric:PlayIdle(self.IdleCartPrisonerASway)
		player:PlayIdle(self.IdleCartPrisonerCIdle)
		i02:PlayIdle(self.IdleCartDriverSway); sp02:PlayIdle(self.IdleCartPrisonerBSway)
		sp03:PlayIdle(self.IdleCartPrisonerDSway); sp04:PlayIdle(self.IdleCartPrisonerASway)
		sp01:PlayIdle(self.IdleCartPrisonerCSway)

		ulfric:EquipItem(self.ArmorGag, false, false)
	end

	function C:Fragment_175()
		if self.cart ~= S.Idle then return end -- a run happens once
		rt.static("Game", "SetHudCartMode")
		self.cart = S.AwaitLoad
	end

	C.Race = rt.sequence("Idle", "PreMenu", "PostMenu")
	local R = C.Race
	C.__vars.race27 = R.Idle
	C.__vars.race27T = rt.timer(0.0)
	C.__vars.asking27 = rt.bool(false)
	C.__vars.race156 = R.Idle
	C.__vars.race156T = rt.timer(0.0)
	C.__vars.asking156 = rt.bool(false)

	function C:Fragment_27()
		if self.race27 ~= R.Idle or self.asking27 then return end -- a call while it waits is dropped
		rt.static("Game", "SetInChargen", false, false, false)
		rt.static("Game", "GetPlayer"):MoveTo(self.HelgenEndMarker, 0.0, 0.0, 0.0, true)
		rt.static("Game", "FadeOutGame", false, true, 1.0, 1.0)
		self.race27 = R.PreMenu
		self.race27T = 1.0
	end

	local function answerRace27(self)
		if self.race27 == R.PreMenu and self.race27T <= 0 then
			rt.static("Game", "ShowRaceMenu")
			self.race27 = R.PostMenu
			self.race27T = 1.0
		elseif self.race27 == R.PostMenu and self.race27T <= 0 then
			self.race27 = R.Idle
			rt.cast(self, "MQ101QuestScript"):AddRaceSpells()
			self.asking27 = true
			self.TempChooseSidesMessage:Show()
		elseif self.asking27 then
			local choice = self.TempChooseSidesMessage:Answer()
			if choice < 0 then return self.TempChooseSidesMessage:Show() end
			self.asking27 = false
			if choice == 0 then
				self.Alias_Hadvar:GetReference():MoveTo(self.HelgenFriendMarker, 0.0, 0.0, 0.0, true)
				self.MQ102A:SetStage(1)
			else
				self.Alias_Ralof:GetReference():MoveTo(self.HelgenFriendMarker, 0.0, 0.0, 0.0, true)
				self.MQ102B:SetStage(1)
			end
			self:SetStage(25)
			self:SetStage(26)
			self:SetStage(1000)
			self.MUSDungeonChargen:Remove()
			self.MUSCombatBossChargen:Remove()
			self.ExtHelgenAttackASREF:Disable(false)
			self:Stop()
		end
	end

	function C:Fragment_156()
		if self.race156 ~= R.Idle or self.asking156 then return end -- a call while it waits is dropped
		rt.static("Game", "SetInChargen", false, false, false)
		rt.static("Game", "DisablePlayerControls", true, true, false, false, false, true, true, false, 0)
		local player = rt.static("Game", "GetPlayer")
		player:RemoveAllItems(rt.None, false, false)
		player:EquipItem(self.ClothesPrisoner, false, false)
		player:EquipItem(self.ClothesPrisonerShoes, false, false)
		player:MoveTo(self.HelgenEndMarker, 0.0, 0.0, 0.0, true)
		self.race156 = R.PreMenu
		self.race156T = 1.0
	end

	local function answerRace156(self)
		if self.race156 == R.PreMenu and self.race156T <= 0 then
			rt.static("Game", "ShowRaceMenu")
			self.race156 = R.PostMenu
			self.race156T = 1.0
		elseif self.race156 == R.PostMenu and self.race156T <= 0 then
			self.race156 = R.Idle
			self.asking156 = true
			self.TempChooseSidesMessage2:Show()
		elseif self.asking156 then
			local choice = self.TempChooseSidesMessage2:Answer()
			if choice < 0 then return self.TempChooseSidesMessage2:Show() end
			self.asking156 = false
			self:SetStage(choice == 0 and 6 or 7)
			rt.static("Game", "EnablePlayerControls", true, false, false, true, true, false, false, true, 0)
		end
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		answerRace27(self)
		answerRace156(self)
		if self.cart == S.Idle then return end
		if self.cart == S.AwaitLoad then
			if not all_loaded(self) then return end
			self.Alias_Cart1:GetRef():TetherToHorse(self.Alias_CartHorse1:GetActorRef())
			self.Alias_Cart2:GetRef():TetherToHorse(self.Alias_CartHorse2:GetActorRef())
			self.cart = S.Tethered
			self.cartT = 1.0
			return
		end
		if self.cartT > 0 then return end
		self.cart = S.Idle
		board(self)
	end
end
