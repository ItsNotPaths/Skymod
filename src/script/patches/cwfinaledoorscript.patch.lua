-- pex: onactivate 8dc60d21
-- The Wait(0.5) poll on IsInInterior becomes OnTick at 2 Hz in the state that waits. PlayerRef and
-- the stage-100 gate are read once, at the start, matching Papyrus's local variable capture.
local rt = require('skymod.rt')

local function trace(msg) rt.static("Debug", "Trace", "cwdoor: " .. msg) end

return function(C)
	C.__vars.TickRate = rt.float(0.5)
	C.__vars.waitingFor = rt.stopwatch(0.0) -- only for the log line
	local Waiting = rt.state(C, "WaitingForInterior")

	local function player() return rt.static("Game", "GetPlayer") end

	function C:OnActivate(akActionRef)
		if self:GetOwningQuest():GetStageDone(100) then return end
		if akActionRef ~= player() then return end
		trace("player activated door, waiting for the interior")
		self.waitingFor = 0.0
		self:GotoState("WaitingForInterior")
		self:OnTick()
	end

	function Waiting:OnActivate(akActionRef)
		trace("dropped: already waiting")
	end

	function Waiting:OnTick()
		if not player():IsInInterior() then return end
		self:GotoState("")
		trace("player inside after " .. string.format("%.2f", self.waitingFor) .. " s, PlayerEnteredCastle")
		rt.cast(self:GetOwningQuest(), "CWFinaleScript"):PlayerEnteredCastle()
	end
end
