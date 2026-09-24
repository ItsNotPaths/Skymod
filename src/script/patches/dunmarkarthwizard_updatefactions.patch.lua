-- pex: waiting.ontriggerenter cd54f98c
-- The first guard through barred the door behind them, waiting until the bar was down, before the
-- guard's Variable06, the link swap and the package. Now the Barring state waits for the bar;
-- `guard` is who went through. Other entries in the meantime still run their faction part.
local rt = require('skymod.rt')

return function(C)
	C.__vars.guard = rt.form("ObjectReference")
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Barring = rt.state(C, "Waiting"), rt.state(C, "Barring")

	local function secure(self, alias)
		local a = alias:GetActorReference()
		a:AddToFaction(self.SecureAreaFaction)
		a:SetAV("Aggression", 1)
		a:EvaluatePackage()
	end

	local function finish(self, obj)
		if self:GetLinkedRef(self.LinkCustom02) then
			self:GetLinkedRef(self.LinkCustom03):Enable()
			self:GetLinkedRef(self.LinkCustom02):Disable()
		end
		rt.cast(obj, "Actor"):EvaluatePackage()
	end

	local function enter(self, obj)
		local stage = self.TG06:GetStage()
		if stage < self.StageMustBeAbove or stage >= self.StageMustBeBelow then return end
		secure(self, self.Actor1)
		secure(self, self.Actor2)
		local bar = rt.cast(self:GetLinkedRef(), "DoorBar")
		if bar and not self.activatedLinkedRef then
			self.activatedLinkedRef = true
			bar:SetBarPosition(false)
			self.guard = obj
			self:GotoState("Barring")
			return self:OnTick()
		end
		finish(self, obj)
	end

	Waiting.OnTriggerEnter = enter
	Barring.OnTriggerEnter = enter

	function Barring:OnTick()
		local bar = rt.cast(self:GetLinkedRef(), "DoorBar")
		if bar.lowerWanted or bar:GetState() == "busy" then return end
		rt.cast(self.guard, "Actor"):SetActorValue("Variable06", 1)
		finish(self, self.guard)
		self:GotoState("Waiting")
	end
end
