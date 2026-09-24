-- pex: down.onactivate 29935377
-- pex: up.onactivate 7ae92c45
-- The portcullis moved and waited for TransitionComplete in the busy state; the event now ends
-- the move. `lowering` says which way it is moving.
local rt = require('skymod.rt')

return function(C)
	C.__vars.lowering = rt.bool(false)
	local Up, Down, Busy = rt.state(C, "Up"), rt.state(C, "Down"), rt.state(C, "Busy")

	local function may_open(self, akActionRef)
		return self.bCanActorsOpen or not rt.cast(akActionRef:GetBaseObject(), "ActorBase")
	end

	function Up:OnActivate(akActionRef)
		if not may_open(self, akActionRef) then return self.MessageToShow:Show() end
		self:GotoState("Busy")
		self.lowering = true
		self.SoundOpen:Play(self)
		self:RegisterForAnimationEvent(self, "TransitionComplete")
		self:PlayAnimation("Stage2")
	end

	function Down:OnActivate(akActionRef)
		if not may_open(self, akActionRef) then return self.MessageToShow:Show() end
		self:GotoState("Busy")
		self.lowering = false
		self:EnableLinkedRef()
		self.SoundClose:Play(self)
		self:RegisterForAnimationEvent(self, "TransitionComplete")
		self:PlayAnimation("Stage1")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "TransitionComplete" then return end
		if self.lowering then self:DisableLinkedRef() end
		if self.bDoOnce then
			self:GotoState("Finished")
		else
			self:GotoState(self.lowering and "Down" or "Up")
		end
	end
end
