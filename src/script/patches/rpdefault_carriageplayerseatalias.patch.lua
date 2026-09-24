-- pex: onactivate cb479ae9
-- OnActivate stayed in "ActivationInProgress" for the whole ride (HandlePlayerSat waited there).
-- HandlePlayerSat now returns as soon as it accepts or rejects the ride, so this state polls the
-- quest's own "ride" field and leaves only once the ride is Idle again.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.2)
	local Busy = rt.state(C, "ActivationInProgress")

	local function quest(self) return rt.cast(self:GetOwningQuest(), "rpdefault_carriagesystem") end

	function C:OnActivate(akActionRef)
		self:GotoState("ActivationInProgress")
		if akActionRef ~= rt.static("Game", "GetPlayer") then
			self:GotoState("")
			return
		end
		local carriageQuest = quest(self)
		self:Clear()
		if not carriageQuest:HandlePlayerSat() then
			self:GotoState("") -- rejected synchronously, as in Papyrus
		end
		-- accepted: Busy:OnTick below leaves once the quest's ride finishes
	end

	function Busy:OnActivate(akActionRef) end -- as converted: ignore activation while busy

	function Busy:OnTick()
		if quest(self).ride.name ~= "Idle" then return end
		self:GotoState("")
	end
end
