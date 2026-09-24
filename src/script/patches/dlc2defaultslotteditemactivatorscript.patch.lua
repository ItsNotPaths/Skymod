-- pex: busy.onactivate 7b1067c4
-- pex: off.onactivate eff647a8
-- pex: on.onactivate ffb4be02
-- Switching played the on or off animation and waited for doneEvent, opened or closed the linked
-- chain, and waited waitTime before the next state. Now the event does the switch and a timer
-- ends the wait; `switching_on` says which way. Busy's 1 s wait after its message held nothing.
local rt = require('skymod.rt')

return function(C)
	C.__vars.switching_on = rt.bool(false)
	C.__vars.settle = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(0.1)
	local Off, On, Busy = rt.state(C, "off"), rt.state(C, "on"), rt.state(C, "busy")

	local function rest(self, on)
		self:GotoState(self.DoOnce and "Done" or (on and "on" or "off"))
	end

	local function start(self, on)
		self.switching_on = on
		self:RegisterForAnimationEvent(self, self.doneEvent)
		self:PlayAnimation(on and self.onAnim or self.offAnim)
	end

	function Off:OnActivate(akActivator)
		self:GotoState("busy")
		if akActivator:GetItemCount(self.requiredItem) >= 1 or self.noItemRequired then
			if not self.doesNotRemoveItem then akActivator:RemoveItem(self.requiredItem, 1, self.silenceContainerMessage) end
			return start(self, true)
		end
		if akActivator == rt.static("Game", "GetPlayer") and self.itemNeededMessage then self.itemNeededMessage:Show() end
		rest(self, true)
	end

	function On:OnActivate(akActivator)
		self:GotoState("busy")
		if self.itemIsNotRemovable then return self:GotoState("on") end
		if not self.doesNotRemoveItem then akActivator:AddItem(self.requiredItem, 1, self.silenceContainerMessage) end
		start(self, false)
	end

	function Busy:OnActivate(akActivator)
		if self.busyMessage then self.busyMessage:Show() end
	end

	local function opens(r)
		return r and (rt.cast(r, "default2stateActivator") or rt.cast(r:GetBaseObject(), "Door"))
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= self.doneEvent or self.settle ~= rt.None then return end
		local on = self.switching_on
		self:Activate(self, true)
		self.isOn = on
		if on and self.itemIsNotRemovable then self:SetDestroyed(true) end
		local link = self:GetLinkedRef()
		if opens(link) then
			link:SetOpen(on)
			while opens(link:GetLinkedRef()) do
				link = link:GetLinkedRef()
				link:SetOpen(on)
			end
		end
		self.settle = self.waitTime
	end

	function Busy:OnTick()
		if self.settle == rt.None or self.settle > 0 then return end
		self.settle = rt.None
		rest(self, self.switching_on)
	end
end
