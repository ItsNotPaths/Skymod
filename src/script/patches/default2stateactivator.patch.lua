-- pex: busy.onactivate 3c5d4600
-- pex: setdefaultstate 5a5d5a98
-- pex: setopen c36d3edc
-- pex: waiting.onactivate 778df25d
-- SetOpen waited while busy, then played the open or close animation and, unless interruptible or
-- unloaded, waited for its event before setting the collision and isOpen. SetDefaultState did the
-- same for the start animation. Now the event finishes each move. A SetOpen during a move is a
-- desired state (`want`), settled when the move ends; a doOnce activation ends in `done`.
local rt = require('skymod.rt')

return function(C)
	C.__vars.want = rt.string("")        -- "open" or "closed": asked for during a move
	C.__vars.after_move = rt.string("")  -- the state a move ends in, when not "waiting"
	C.__vars.defaulting = rt.string("")  -- "open" or "closed" while SetDefaultState's animation plays
	local Waiting, Busy = rt.state(C, "waiting"), rt.state(C, "busy")
	rt.params(C, "SetOpen", { { "abOpen", true } })

	local function collide(self, open)
		if open ~= self.zInvertCollision then
			self:DisableLinkChain(self.TwoStateCollisionKeyword)
		else
			self:EnableLinkChain(self.TwoStateCollisionKeyword)
		end
	end

	local function settle(self, open)
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

	function C:SetOpen(abOpen)
		if self:GetState() == "busy" then
			self.want = abOpen and "open" or "closed"
			return
		end
		if abOpen == self.isOpen then return end
		self.isAnimating = true
		self:GotoState("busy")
		local anim, event = self.closeAnim, self.closeEvent
		if abOpen then anim, event = self.openAnim, self.openEvent end
		if self.bAllowInterrupt or not self:Is3DLoaded() then
			self:PlayAnimation(anim)
			return settle(self, abOpen)
		end
		self:RegisterForAnimationEvent(self, event)
		self:PlayAnimation(anim)
	end

	function Waiting:OnActivate(triggerRef)
		if self.doOnce then self.after_move = "done" end
		self:SetOpen(not self.isOpen)
		if self.doOnce and self:GetState() ~= "busy" then
			self.after_move = ""
			self:GotoState("done")
		end
	end

	function Busy:OnActivate(triggerRef)
		if self.bAllowInterrupt then self:SetOpen(not self.isOpen) end
	end

	function C:SetDefaultState()
		self.defaulting = self.isOpen and "open" or "closed"
		local anim, event = self.closeAnim, self.closeEvent
		if self.isOpen then anim, event = self.startOpenAnim, self.openEvent end
		self:RegisterForAnimationEvent(self, event)
		self:PlayAnimation(anim)
	end

	-- one handler for both runs; as in Papyrus, an event wakes every run waiting for it
	local function on_event(self, akSource, asEventName)
		if akSource ~= self then return end
		if self.defaulting ~= "" then
			local open = self.defaulting == "open"
			if asEventName == (open and self.openEvent or self.closeEvent) then
				self.defaulting = ""
				collide(self, open)
				self.myState = open and 0 or 1
			end
		end
		if self:GetState() ~= "busy" then return end
		local opening = not self.isOpen
		if asEventName == (opening and self.openEvent or self.closeEvent) then settle(self, opening) end
	end
	C.OnAnimationEvent = on_event
	Busy.OnAnimationEvent = on_event
end
