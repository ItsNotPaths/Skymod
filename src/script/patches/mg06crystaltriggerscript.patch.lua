-- pex: onactivate c9e7e5fa
-- Placing the crystal engaged the armillary from here: Engage on the armillary, waited for
-- TransSeq01, set it to position 1 and opened the three buttons one after another. Now OnTick in
-- Engaging polls the armillary's animation, then each button's state; `raising` is the button.
local rt = require('skymod.rt')

return function(C)
	C.__vars.raising = rt.int(0)
	C.__vars.TickRate = rt.float(0.1)
	local Engaging = rt.state(C, "Engaging")

	local function button(self, n) return rt.cast(self["Button0" .. n], "MG06ButtonScript") end

	function C:OnActivate(TriggerRef)
		if self.MG06:GetStage() ~= 40 or TriggerRef ~= rt.static("Game", "GetPlayer") then return end
		local arm = rt.cast(self.ArmillaryRef, "MG06ArmillaryScript")
		if arm.ReadyForSpells ~= 0 or self:GetState() == "Engaging" then return end
		arm:GotoState("busy")
		self.MG06:SetStage(50)
		rt.static("Game", "GetPlayer"):RemoveItem(self.MG06Crystal:GetReference(), 1)
		self.ArmillaryRef:PlayAnimation("Engage")
		self.raising = 0
		self:GotoState("Engaging")
	end

	function Engaging:OnTick()
		local n = self.raising
		if n == 0 then
			if self.ArmillaryRef:IsAnimRunning("Engage") then return end
			local arm = rt.cast(self.ArmillaryRef, "MG06ArmillaryScript")
			arm.ReadyForSpells = 1
			arm:GotoState("Position01")
			arm.Positionvar = 1
			self.raising = 1
			button(self, 1):Open()
		elseif button(self, n):GetState() ~= "Busy" then
			if n == 3 then
				self.raising = 0
				self:GotoState("")
			else
				self.raising = n + 1
				button(self, n + 1):Open()
			end
		end
	end
end
