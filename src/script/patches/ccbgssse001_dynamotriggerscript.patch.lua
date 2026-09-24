-- pex: off.onactivate 4c5d5b3e
-- pex: on.onactivate 3c1055b9
-- The dynamo played its on or off animation and waited for doneEvent in the busy state; the event
-- now finishes the switch. `switching_on` says which way.
local rt = require('skymod.rt')

return function(C)
	C.__vars.switching_on = rt.bool(false)
	local Off, On, Busy = rt.state(C, "off"), rt.state(C, "on"), rt.state(C, "busy")

	function Off:OnActivate(akActivator)
		self:GotoState("busy")
		if akActivator ~= rt.static("Game", "GetPlayer") or self.alreadyTriggered then return self:GotoState("off") end
		if akActivator:GetItemCount(self.requiredItem) < 1 then
			self.itemNeededMessage:Show()
			return self:GotoState("off")
		end
		akActivator:RemoveItem(self.requiredItem, 1, true)
		self.switching_on = true
		self:RegisterForAnimationEvent(self, self.doneEvent)
		self:PlayAnimation(self.onAnim)
	end

	function On:OnActivate(akActivator)
		self:GotoState("busy")
		if self.itemIsNotRemovable then return self:GotoState("on") end
		akActivator:AddItem(self.requiredItem, 1, true)
		self.switching_on = false
		self:RegisterForAnimationEvent(self, self.doneEvent)
		self:PlayAnimation(self.offAnim)
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= self.doneEvent then return end
		if self.switching_on then
			self:Activate(self, true)
			self.isOn = true
			if self.itemIsNotRemovable then self:SetDestroyed(true) end
			self.alreadyTriggered = true
			self:GotoState("on")
		else
			self.isOn = false
			self:GotoState("off")
			self:SetDestroyed(true)
		end
	end
end
