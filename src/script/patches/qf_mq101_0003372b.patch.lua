-- pex: fragment_175 08772782
-- Fragment_175 (Helgen carts, stage 12): polled 0.2s while nine actors were not yet 3D loaded
-- (the original list skips Alias_StormcloakPrisoner01, kept as is), then tethered both carts,
-- waited 1s, and put everyone in place. A stage plus one timer now does the same in OnTick. The
-- class already ticks for other fragments' splits; call it first.
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

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
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
