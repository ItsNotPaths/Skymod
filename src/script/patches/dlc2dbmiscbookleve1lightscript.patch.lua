-- pex: dothedamage c15d755d
-- pex: onactivate 1712aec2
-- pex: oncellattach 6fbdd2bc
-- DoTheDamage looped every 0.5 s while bDoDamage; OnCellAttach waited 3 s (if linked) to start a
-- translation chain, then polled the player's light level forever, every 0.5 s. `damageT` carries
-- the damage cadence; `attach`/`attachT` carry the one-shot link wait, then the endless poll.
local rt = require('skymod.rt')

local Attach = rt.sequence("Idle", "LinkWait", "Looping")

return function(C)
	C.__vars.damageT = rt.timer(0.0)
	C.__vars.attach = Attach.Idle
	C.__vars.attachT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	function C:DoTheDamage()
		if not self.bdodamage then
			self.bdoingdamage = false
			return
		end
		self.bdoingdamage = true
		rt.static("Game", "GetPlayer"):DamageActorValue("Health", 5)
		self.damageT = 0.5
	end

	function C:OnActivate(akActionRef)
		self:DoTheDamage()
		if self.bstarttranslation == true then
			self.bstarttranslation = false
			self:DoLightMovement()
		end
	end

	function C:OnCellAttach()
		if self.attach ~= Attach.Idle then return end -- a run happens once per attach
		if self:GetLinkedRef() then
			self.attach, self.attachT = Attach.LinkWait, 3.0
		else
			self.attach, self.attachT = Attach.Looping, 0.0
		end
	end

	function C:OnTick()
		if self.bdoingdamage then
			if not self.bdodamage then
				self.bdoingdamage = false
			elseif self.damageT <= 0 then
				rt.static("Game", "GetPlayer"):DamageActorValue("Health", 5)
				self.damageT = 0.5
			end
		end

		if self.attach == Attach.LinkWait then
			if self.attachT > 0 then return end
			self.ilinkchaincount = self:CountLinkedRefChain()
			self.bstarttranslation = true
			self:Activate(self)
			self.attach, self.attachT = Attach.Looping, 0.0
			return
		end
		if self.attach == Attach.Looping then
			if self.attachT > 0 then return end
			if rt.static("Game", "GetPlayer"):GetLightLevel() < 30 then
				self.bdodamage = true
				if not self.bdoingdamage then self:Activate(self) end
			else
				self.bdodamage = false
			end
			self.attachT = 0.5
		end
	end
end
