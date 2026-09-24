-- pex: onactivate 3987572e
-- Placing or taking the mask played the bust's on/off animation and waited for it, activation
-- blocked. Now a Busy state polls the bust's animation and unblocks when it ends.
local rt = require('skymod.rt')

return function(C)
	C.__vars.anim = rt.string("") -- the bust animation playing
	C.__vars.TickRate = rt.float(0.1)
	local Busy = rt.state(C, "Busy")

	local function play(self, name)
		self.anim = name
		self:GotoState("Busy")
		self.myBustActivator:PlayAnimation(name)
	end

	function C:OnActivate(actronaut)
		if not self.placed then
			if actronaut:GetItemCount(self.ArmorDragonPriestMaskUltraHelmet) < 1 then
				return self.defaultLackTheItemMSG:Show()
			end
			self:BlockActivation()
			actronaut:RemoveItem(self.ArmorDragonPriestMaskUltraHelmet, 1)
			self.placed = true
			play(self, "on")
		else
			self:BlockActivation()
			actronaut:AddItem(self.ArmorDragonPriestMaskUltraHelmet, 1)
			self.placed = false
			play(self, "off")
		end
	end

	function Busy:OnActivate(actronaut) end -- a run happens once

	function Busy:OnTick()
		if self.myBustActivator:IsAnimRunning(self.anim) then return end
		self.anim = ""
		self:BlockActivation(false)
		self:GotoState("")
	end
end
