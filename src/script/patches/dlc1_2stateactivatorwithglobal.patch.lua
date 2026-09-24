-- (no pin: pexlatent emits no body hash for property functions, so the isOpen setter is unpinned)
-- The isOpen setter played the open or close animation and waited for its event before setting
-- collision, the state and the global. Now the event finishes it; `moving` is "open" or "close"
-- while it runs, and a set during a run is kept in `want` and settled when the run ends.
local rt = require('skymod.rt')

return function(C)
	C.__vars.moving = rt.string("")
	C.__vars.want = rt.int(-1) -- -1 none, 0 closed, 1 open

	local function collision(self, opened)
		if opened == not self.zInvertCollision then
			self:DisableLinkChain(self.TwoStateCollisionKeyword)
		else
			self:EnableLinkChain(self.TwoStateCollisionKeyword)
		end
	end

	local function finish(self, open)
		self.busy = false
		self.vars["currentopenstate"] = open
		self.myGlobalVar:SetValue(open and 1 or 0)
		if self.want ~= -1 then
			local w = self.want == 1
			self.want = -1
			self.isOpen = w
		end
	end

	C.__fn["__propset_isopen"] = function(self, newOpenState)
		if self.moving ~= "" then
			self.want = newOpenState and 1 or 0
			return
		end
		self.busy = true
		local g = self.myGlobalVar:GetValue()
		local open
		if newOpenState and g == 0 then
			open = true
		elseif not newOpenState and g == 1 then
			open = false
		else
			return finish(self, newOpenState)
		end
		local anim = open and self.openAnim or self.closeAnim
		if self.bAllowInterrupt or not self:Is3DLoaded() then
			self:PlayAnimation(anim)
			collision(self, open)
			return finish(self, newOpenState)
		end
		self.moving = open and "open" or "close"
		self:RegisterForAnimationEvent(self, open and self.openEvent or self.closeEvent)
		self:PlayAnimation(anim)
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or self.moving == "" then return end
		local open = self.moving == "open"
		if asEventName ~= (open and self.openEvent or self.closeEvent) then return end
		self.moving = ""
		collision(self, open)
		finish(self, open)
	end
end
