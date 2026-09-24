-- pex: setdefaultstate afe9b6fd
-- pex: setopen d5caf84c
-- The Apocrypha extending hall is a default2StateActivator whose open also fades out its endcap
-- (a second animation that sends the same OpenEvent) and whose close brings the endcap back
-- first. Now `hall` says which animation is playing; the events step it, as in the base patch.
local rt = require('skymod.rt')

return function(C)
	C.__vars.hall = rt.string("") -- "opening", "endcap", "closing", "default_open", "default_endcap", "default_closed"
	local Busy = rt.state(C, "busy")
	rt.params(C, "SetOpen", { { "abOpen", true } })

	local function endcap(self) return self:GetLinkedRef(self.LinkCustom01) end

	local function collide(self, open)
		if open ~= self.zInvertCollision then
			self:DisableLinkChain(self.TwoStateCollisionKeyword)
		else
			self:EnableLinkChain(self.TwoStateCollisionKeyword)
		end
	end

	local function play(self, step, anim, event)
		self.hall = step
		self:RegisterForAnimationEvent(self, event)
		self:PlayAnimation(anim)
	end

	local function settle(self, open)
		self.hall = ""
		collide(self, open)
		self.isOpen = open
		local to = self.after_move ~= "" and self.after_move or "waiting"
		self.after_move = ""
		self:GotoState(to)
		self.isAnimating = false
		if self.want ~= "" then
			local w = self.want == "open"
			self.want = ""
			if to == "waiting" then self:SetOpen(w) end
		end
	end

	local function opened(self)
		local cap = endcap(self)
		if cap then return play(self, "endcap", self.fadeoutEndcapAnim, self.OpenEvent) end
		settle(self, true)
	end

	function C:SetOpen(abOpen)
		if self:GetState() == "busy" then
			self.want = abOpen and "open" or "closed"
			return
		end
		if abOpen == self.isOpen then return end
		self.isAnimating = true
		self:GotoState("busy")
		local quick = self.bAllowInterrupt or not self:Is3DLoaded()
		if abOpen then
			if quick then
				self:PlayAnimation(self.openAnim)
				return opened(self)
			end
			return play(self, "opening", self.openAnim, self.openEvent)
		end
		local cap = endcap(self)
		if cap then cap:Enable(true) end
		if quick then
			self:PlayAnimation(self.closeAnim)
			return settle(self, false)
		end
		play(self, "closing", self.closeAnim, self.closeEvent)
	end

	function C:SetDefaultState()
		if self.isOpen then
			play(self, "default_open", self.StartOpenAnim, self.openEvent)
		else
			play(self, "default_closed", self.startClosedAnim, self.closeEvent)
		end
	end

	local function on_event(self, akSource, asEventName)
		if akSource ~= self then return end
		local h = self.hall
		if h == "opening" and asEventName == self.openEvent then
			opened(self)
		elseif h == "endcap" and asEventName == self.OpenEvent then
			endcap(self):Disable(true)
			settle(self, true)
		elseif h == "closing" and asEventName == self.closeEvent then
			settle(self, false)
		elseif h == "default_open" and asEventName == self.openEvent then
			local cap = endcap(self)
			if cap then
				cap:Disable(false)
				return play(self, "default_endcap", self.fadeoutEndcapAnim, self.OpenEvent)
			end
			self.hall = ""
			collide(self, true)
			self.myState = 0
		elseif h == "default_endcap" and asEventName == self.OpenEvent then
			self.hall = ""
			collide(self, true)
			self.myState = 0
		elseif h == "default_closed" and asEventName == self.closeEvent then
			self.hall = ""
			local cap = endcap(self)
			if cap then cap:Enable(false) end
			collide(self, false)
			self.myState = 1
		end
	end
	C.OnAnimationEvent = on_event
	Busy.OnAnimationEvent = on_event
end
