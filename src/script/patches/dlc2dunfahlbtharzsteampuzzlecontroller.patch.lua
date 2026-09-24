-- pex: addsteam c150e073
-- pex: controllights d926ca03
-- AddSteam walked the light meter to the new charge one light at a time (each fill waited for
-- the meter's animation, then LightChangeRate), then opened the door or, over the limit, vented,
-- emptied the meter, punished and reset the resonators. Now `steam` is AddSteam's step and
-- `lighting` the meter walk: `light_i` the charge shown, `light_end` its target, `light_meter`
-- the meter filling now.
local rt = require('skymod.rt')

return function(C)
	C.Steam = rt.sequence("Idle", "Filling", "Venting")
	local S = C.Steam
	C.__vars.steam = S.Idle
	C.__vars.resonator = rt.form("DLC2dunFahlbtharzResonatorScript")
	C.__vars.lighting = rt.bool(false)
	C.__vars.light_i = rt.int(0)
	C.__vars.light_end = rt.int(0)
	C.__vars.light_down = rt.bool(false)
	C.__vars.light_meter = rt.form("DLC2DweSteamMeterScript")
	C.__vars.light_t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)
	local split_tick = C.__fn.ontick

	-- the meter light for charge i, as each loop picked it
	local function empty_light(self, i)
		if i == 0 then return self.LightChain end
		return self.LightChain:GetNthLinkedRef(i > 20 and i - 21 or i - 1)
	end

	local function fill_light(self, i)
		if i == 1 then return self.LightChain end
		return self.LightChain:GetNthLinkedRef(i <= 20 and i - 1 or i - 21)
	end

	function C:ControlLights(endCharge)
		self.lighting = true
		self.light_i = self.CurrentSteamCharge
		self.light_end = endCharge
		self.light_down = self.CurrentSteamCharge >= endCharge
		self.light_meter = rt.None
		self.light_t = 0.0
	end

	local function light_tick(self)
		if not self.lighting or self.light_t > 0 then return end
		if self.light_meter then
			if self.light_meter.filling ~= "" then return end
			self.light_meter = rt.None
			self.light_t = self.LightChangeRate
			return
		end
		local i = self.light_i
		if self.light_down and i > self.light_end then
			local l = empty_light(self, i)
			if l then rt.cast(l, "DLC2DweSteamMeterScript"):EmptyMeter() end
			self.light_i = i - 1
			self.light_t = self.LightChangeRate
		elseif not self.light_down and i < self.light_end then
			i = i + 1
			self.light_i = i
			local l = fill_light(self, i)
			if i > 20 then
				self.OBJFahlbtharzFail:Play(self.LightChain)
				rt.static("Game", "ShakeCamera", rt.None, 1.0)
				rt.static("Game", "ShakeController", self.ControllerShakeL, self.ControllerShakeR, self.ControllerShakeDuration)
			end
			if l then
				self.light_meter = rt.cast(l, "DLC2DweSteamMeterScript")
				self.light_meter:FillMeter()
			else
				self.light_t = self.LightChangeRate
			end
		else
			self.lighting = false
			self.CurrentSteamCharge = math.max(self.light_end, 0)
		end
	end

	function C:AddSteam(SteamCharge, resonator)
		if self.steam ~= S.Idle then return end
		self.resonator = resonator
		self.steam = S.Filling
		self:ControlLights(self.CurrentSteamCharge + SteamCharge)
	end

	local function steam_tick(self)
		if self.steam == S.Idle or self.lighting then return end
		if self.steam == S.Filling then
			self.resonator:TurnOffSteam()
			if self.CurrentSteamCharge == self.SucessfulSteamCharge then
				self.steam = S.Idle
				return self:OpenDoor() -- isBusy stays set: the puzzle is done
			end
			if self.CurrentSteamCharge > self.SucessfulSteamCharge then
				self.SteamFail:Enable()
				self.SteamFail:EnableLinkChain()
				self.steam = S.Venting
				return self:ControlLights(0)
			end
		else
			self:PunishFailure()
			self:ResetResonators()
			self:EndSteamVent()
		end
		self.steam = S.Idle
		self.isBusy = false
	end

	function C:OnTick()
		split_tick(self)
		light_tick(self)
		steam_tick(self)
	end
end
