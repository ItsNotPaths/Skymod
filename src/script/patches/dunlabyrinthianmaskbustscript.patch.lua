-- pex: onactivate 9452893b
-- Placing or taking the mask played the linked bust's on/off animation and waited for it, with
-- activation blocked, then told the master. Now the Moving state polls that animation;
-- `anim` is the one playing.
local rt = require('skymod.rt')

return function(C)
	C.__vars.anim = rt.string("")
	C.__vars.TickRate = rt.float(0.1)
	local Moving = rt.state(C, "Moving")

	local function move(self, anim)
		self.anim = anim
		self:GetLinkedRef():PlayAnimation(anim)
		self:GotoState("Moving")
		self:OnTick()
	end

	function C:OnActivate(actronaut)
		if not self.placed then
			if actronaut:GetItemCount(self.myMask) < 1 then return self.defaultLackTheItemMSG:Show() end
			self:BlockActivation()
			actronaut:RemoveItem(self.myMask, 1)
			self.placed = true
			move(self, "on")
		else
			self:BlockActivation()
			actronaut:AddItem(self.myMask, 1)
			self.placed = false
			move(self, "off")
		end
	end

	function Moving:OnActivate(actronaut) end -- blocked, as before

	function Moving:OnTick()
		if self:GetLinkedRef():IsAnimRunning(self.anim) then return end
		self.anim = ""
		self:GotoState("")
		self:updateMaster()
		self:BlockActivation(false)
	end
end
