-- pex: fragment_0 e6e6ce2b
-- pex: fragment_1 ff4dd98b
-- pex: fragment_2 6b6b95e2
-- pex: fragment_3 5d8c4baf
-- pex: fragment_4 0fbb5520
-- pex: fragment_5 79c2833e
-- Mission quick starts. Each started the war, put the enemy forts back in it (blocking in setOwner
-- and its "Done" box), then set hold owners and moved the player to a camp. Each is now a bool
-- owed until CWScript's resets and its "Done" box are over.
local rt = require('skymod.rt')

-- stage: CW stage (1 Imperial, 2 Sons); holds: given to that side; mission: its done flag.
local STARTS = {
	f0 = { stage = 2, holds = { "FalkreathHoldLocation", "WhiterunHoldLocation" }, mission = "CWMission07Done", done = 0, camp = "MilitaryCampReachSonsMapMarker" },
	f1 = { stage = 2, holds = { "WhiterunHoldLocation" }, mission = "CWMission04Done", done = 0, camp = "MilitaryCampFalkreathSonsMapMarker", enable = "CWGarrisonEnableMarkerSonsCampFalkreath" },
	f2 = { stage = 2, holds = { "WhiterunHoldLocation", "FalkreathHoldLocation" }, mission = "CWMission07Done", done = 1, camp = "MilitaryCampReachSonsMapMarker" },
	f3 = { stage = 2, holds = { "ReachHoldLocation", "FalkreathHoldLocation", "WhiterunHoldLocation" }, mission = "CWMission03Done", done = 0, camp = "MilitaryCampHjaalmarchSonsMapMarker" },
	f4 = { stage = 1, holds = { "PaleHoldLocation", "WhiterunHoldLocation" }, mission = "CWMission07Done", done = 0, camp = "MilitaryCampRiftImperialMapMarker" },
	f5 = { stage = 1, holds = { "WhiterunHoldLocation" }, mission = "CWMission03Done", done = 1, camp = "MilitaryCampPaleImperialMapMarker" },
}

return function(C)
	for f in pairs(STARTS) do C.__vars[f] = rt.bool(false) end
	C.__vars.TickRate = rt.float(0.1)
	local Waiting = rt.state(C, "Waiting")

	local function kmy(self) return rt.cast(self, "CWMissionQuickstartScript") end

	local function forts_ready(cw) return not cw.resettingGarrisons and not cw.fortsReadyMsgOwed end

	local function finish(q, spec)
		local cw, sons = q.CW, spec.stage == 2
		cw.WhiterunSiegeFinished = true
		for i = 0, #spec.holds - 1 do cw[spec.holds[i]]:SetKeywordData(cw.CWOwner, spec.stage) end
		cw[spec.mission] = spec.done
		cw[sons and "CW00B" or "CW00A"]:Stop()
		cw[sons and "CW01B" or "CW01A"]:Stop()
		if spec.enable then q[spec.enable]:Enable() end -- Falkreath's camp starts off, near Helgen
		local camp = q[spec.camp]
		q[sons and "GalmarRef" or "RikkeRef"]:MoveTo(camp)
		rt.static("Game", "GetPlayer"):MoveTo(camp)
	end

	function Waiting:OnTick()
		local q = kmy(self)
		if not forts_ready(q.CW) then return end
		for f, spec in pairs(STARTS) do
			if self[f] then
				self[f] = false
				finish(q, spec)
			end
		end
		self:GotoState("")
	end

	local function quick_start(self, f)
		if self[f] then return end
		local q = kmy(self)
		q.CW:SetStage(STARTS[f].stage)
		self[f] = true
		self:GotoState("Waiting")
		q.CW:AddEnemyFortsToBackToWar(true)
		self:OnTick()
	end

	function C:Fragment_0() quick_start(self, "f0") end
	function C:Fragment_1() quick_start(self, "f1") end
	function C:Fragment_2() quick_start(self, "f2") end
	function C:Fragment_3() quick_start(self, "f3") end
	function C:Fragment_4() quick_start(self, "f4") end
	function C:Fragment_5() quick_start(self, "f5") end
end
