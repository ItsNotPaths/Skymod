-- pex: busy.onactivate 3c5d4600
-- pex: waiting.onactivate 778df25d
-- pex: setdefaultstate 5a5d5a98
-- pex: setopen c35c5aba
-- SetDefaultState and SetOpen played the open or close animation and waited for its event before
-- setting collision and the open flag. SetOpen first waited out a running move. Now `run` is the
-- move, its event finishes it, and a request during a move is kept in `want_open` and settled
-- when the move ends. A doOnce activation goes to done once its move ends.
local rt = require('skymod.rt')

return function(C)
	C.Run = rt.sequence("Idle", "DefaultOpen", "DefaultClose", "Opening", "Closing")
	local R = C.Run
	C.__vars.run = R.Idle
	C.__vars.want_open = rt.int(-1) -- -1: no request waiting; else 0 or 1
	C.__vars.done_after = rt.bool(false)
	local Waiting, Busy = rt.state(C, "waiting"), rt.state(C, "busy")

	local function collision(self, open)
		if open == not self.zInvertCollision then
			self:DisableLinkChain(self.TwoStateCollisionKeyword)
		else
			self:EnableLinkChain(self.TwoStateCollisionKeyword)
		end
	end

	function C:SetDefaultState()
		if self.run ~= R.Idle then return end
		if self.isOpen then
			self.run = R.DefaultOpen
			self:RegisterForAnimationEvent(self, self.openEvent)
			self:PlayAnimation(self.startOpenAnim)
		else
			self.run = R.DefaultClose
			self:RegisterForAnimationEvent(self, self.closeEvent)
			self:PlayAnimation(self.closeAnim)
		end
	end

	local function finish(self, open)
		collision(self, open)
		self.isOpen = open
		self.run = R.Idle
		self:GotoState(self.done_after and "done" or "waiting")
		self.isAnimating = false
		if self.want_open ~= -1 and not self.done_after then
			local want = self.want_open == 1
			self.want_open = -1
			self:SetOpen(want)
		end
	end

	function C:SetOpen(abOpen)
		if abOpen == nil then abOpen = true end
		if self:GetState() == "busy" then
			self.want_open = abOpen and 1 or 0
			return
		end
		self.isAnimating = true
		if abOpen == self.isOpen then
			self.isAnimating = false
			return
		end
		self:GotoState("busy")
		local anim = abOpen and self.openAnim or self.closeAnim
		if self.bAllowInterrupt or not self:Is3DLoaded() then
			self:PlayAnimation(anim)
			return finish(self, abOpen)
		end
		self.run = abOpen and R.Opening or R.Closing
		self:RegisterForAnimationEvent(self, abOpen and self.openEvent or self.closeEvent)
		self:PlayAnimation(anim)
	end

	function Waiting:OnActivate(triggerRef)
		if self.doOnce then self.done_after = true end
		self:SetOpen(not self.isOpen)
		if self.doOnce and self:GetState() ~= "busy" then self:GotoState("done") end
	end

	function Busy:OnActivate(triggerRef)
		if self.bAllowInterrupt then self:SetOpen(not self.isOpen) end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		local r = self.run
		if r == R.DefaultOpen and asEventName == self.openEvent then
			collision(self, true)
			self.myState = 0
			self.run = R.Idle
		elseif r == R.DefaultClose and asEventName == self.closeEvent then
			collision(self, false)
			self.myState = 1
			self.run = R.Idle
		elseif r == R.Opening and asEventName == self.openEvent then
			self.myOtherBridge:Enable()
			finish(self, true)
		elseif r == R.Closing and asEventName == self.closeEvent then
			finish(self, false)
		end
	end
end
