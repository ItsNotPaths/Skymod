-- pex: dothedamage b34ed940
-- pex: onactivate 28903c5d
-- pex: oncellattach b444dca8
-- Two Papyrus poll loops become one OnTick: OnCellAttach checked the player's light level every
-- 0.1 s, and DoTheDamage (started through Activate) hurt the player every 0.25 s while bDoDamage.
local rt = require('skymod.rt')

local function player() return rt.static("Game", "GetPlayer") end

return function(C)
	C.__vars.TickRate = rt.float(0.05) -- divides both waits
	C.__vars.damageT = rt.timer(0.0)
	local Running = rt.state(C, "Running")

	-- One pass of DoTheDamage's loop, or its exit when the light came back.
	local function damage_step(self)
		if not self.bDoDamage then
			rt.static("Sound", "StopInstance", self.iDamageSoundID)
			if not self.bIsPlaytesting then rt.static("ImageSpaceModifier", "RemoveCrossFade", 0.5) end
			self.bDoingDamage = false
			return
		end
		if not self.bDoingDamage then
			self.iDamageSoundID = self.sDamageFromDarkSound:Play(player())
			if not self.bIsPlaytesting then self.imodDamgeFromDarkImagespaceModifier:ApplyCrossFade(4) end
		end
		self.bDoingDamage = true
		if not self.bIsPlaytesting then player():DamageActorValue("Health", self.fAmountToDamageThePlayer) end
		self.damageT = self.damageT + 0.25
	end

	function C:OnCellAttach()
		self.bCheckLightLevel = true
		self:CheckPlayerHealthPercentage()
		self:GotoState("Running")
		self:OnTick() -- Papyrus checked at once
	end

	function C:DoTheDamage()
		if self.bDoingDamage then return end -- a run happens once
		self:GotoState("Running")
		self.damageT = 0.0
		damage_step(self)
	end

	function Running:OnTick()
		if self.bCheckLightLevel then
			self.bDoDamage = player():GetLightLevel() < 30
			if self.bDoDamage and not self.bDoingDamage then self:Activate(self) end
		end
		if self.bDoingDamage and self.damageT <= 0 then damage_step(self) end
		if not self.bCheckLightLevel and not self.bDoingDamage then self:GotoState("") end
	end
end
