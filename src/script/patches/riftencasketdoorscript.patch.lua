-- pex: busy.onactivate 930b9162
-- pex: waiting.onactivate 72d7e823
-- pex: setopen 8ecd5ba3
-- SetOpen waited while busy (1 s polls), then opened or closed, waiting for the end event when
-- loaded and not interruptible. Now a request is a desired-state field (`want_open`, `wanted`)
-- settled when busy ends, and the end event finishes the move. `one_shot` is doOnce's use.
local rt = require('skymod.rt')

return function(C)
	C.__vars.wanted = rt.bool(false)
	C.__vars.want_open = rt.bool(false)
	C.__vars.one_shot = rt.bool(false)
	C.__vars.opening = rt.bool(false)
	local Waiting, Busy = rt.state(C, "waiting"), rt.state(C, "busy")

	local function finish(self)
		self.isOpen = self.opening
		self:GotoState("waiting")
		self.isAnimating = false
		if self.one_shot then
			self.one_shot = false
			self:GotoState("done")
		end
		if self.wanted then self:SetOpen(self.want_open) end
	end

	local function move(self, open, anim, event)
		self:GotoState("busy")
		self.opening = open
		local link = self:GetLinkedRef()
		if link then if open then link:Disable() else link:Enable() end end
		if self.bAllowInterrupt or not self:Is3DLoaded() then
			self:PlayAnimation(anim)
			return finish(self)
		end
		self:RegisterForAnimationEvent(self, event)
		self:PlayAnimation(anim)
	end

	function C:SetOpen(abOpen)
		if abOpen == nil or abOpen == rt.None then abOpen = true end
		if self:GetState() == "busy" then
			self.wanted, self.want_open = true, abOpen
			return
		end
		self.wanted = false
		self.isAnimating = true
		if abOpen and not self.isOpen then return move(self, true, self.openAnim, self.openEvent) end
		if not abOpen and self.isOpen then return move(self, false, self.closeAnim, self.closeEvent) end
		self.isAnimating = false
	end

	function Waiting:OnActivate(triggerRef)
		self.one_shot = self.doOnce
		self:SetOpen(not self.isOpen)
		if self.one_shot and self:GetState() == "waiting" then -- nothing moved: done at once
			self.one_shot = false
			self:GotoState("done")
		end
	end

	function Busy:OnActivate(triggerRef)
		if self.bAllowInterrupt then self:SetOpen(not self.isOpen) end
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if asEventName == (self.opening and self.openEvent or self.closeEvent) then finish(self) end
	end
end
