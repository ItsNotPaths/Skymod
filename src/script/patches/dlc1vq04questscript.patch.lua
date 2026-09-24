-- pex: seranabite 1817529c
-- SeranaBite waited for DLC1VampireTurnScript.ReceiveSeranasGift (the gift's turn) before it moved
-- the quest on. It now waits in "Biting" until the turn script's `gift` run is Idle.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Biting = rt.state(C, "Biting")

	function C:SeranaBite()
		self:GotoState("Biting")
		self.pDLC1VampireTurn:ReceiveSeranasGift(self.pDLC1VQ04RNPCAlias:GetActorRef())
		self:OnTick()
	end

	function Biting:SeranaBite() end -- a run is under way

	function Biting:OnTick()
		if self.pDLC1VampireTurn.gift.name ~= "Idle" then return end
		self:GotoState("")
		self.pDLC1VQ04BecameVamp:SetValue(1)
		self.pDLC1VQ04SafeToEnter:SetValue(1)
		self.pDLC1VQ04VampireToggle:Disable()
		self.pDLC1VQ04PortalAreaEffectTriggerRef:Disable()
		self.MM.IsWillingToWait = false
		self.MM:EngageFollowBehavior(false)
		self.pDLC1VQ04RNPCAlias:GetActorRef():EvaluatePackage()
		rt.static("Game", "EnablePlayerControls")
		self:SetObjectiveCompleted(100, true)
		self:SetObjectiveDisplayed(120, true)
	end
end
