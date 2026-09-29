-- pex: planted.onactivate 533e9577
-- Clearing a planted planter asked to confirm, then read the pick at once. The event now asks;
-- OnTick in "planted" reads the answer. empty:OnActivate only reads Actor.ShowGiftMenu (no gift
-- screen yet) and is untouched.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)
	local Planted = rt.state(C, "planted")

	local function player() return rt.static("Game", "GetPlayer") end

	function Planted:OnActivate(TriggerRef)
		if TriggerRef ~= player() then return end
		self.asking = true
		self.PlanterClearMessage:Show()
	end

	function Planted:OnTick()
		if not self.asking then return end
		local choice = self.PlanterClearMessage:Answer()
		if choice < 0 then return self.PlanterClearMessage:Show() end
		self.asking = false
		self.ClearPlanterChoice = choice
		if choice ~= 1 then return end
		self.PlanterContainer.PlantedFloraRef:Delete()
		self.PlanterContainer.PlantedFloraRef = rt.None
		self.PlanterContainer.PlantedFloraBase = rt.None
		self:PlayAnimation("PlayAnim01")
		self:GotoState("empty")
		self.PlanterContainer:Activate(player(), false)
	end
end
