-- pex: movetobehindplayer a29e618f 292781e5
-- pex: rieklingsappear 04dff256 477699f0
-- MoveToBehindPlayer polled IsWeaponDrawn every 1 s (bail at 30) before moving; RieklingsAppear
-- called it once per alias in turn, so the loop must wait for one move before starting the next.
-- A shared timer/busy pair drives both, and OnTick advances the alias loop as each move ends.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	rt.params(C, "MoveToBehindPlayer", { { "ThingToMove" }, { "unitsBehind", 1000 }, { "waitForPlayerWeaponsDrawn", true } })
	C.__vars.mtbpBusy = rt.bool(false)
	C.__vars.mtbpTarget = rt.form("ObjectReference")
	C.__vars.mtbpUnitsBehind = rt.float(1000.0)
	C.__vars.mtbpPoll = rt.bool(false)
	C.__vars.mtbpWaitFor = rt.int(0)
	C.__vars.mtbpT = rt.timer(0.0)
	C.__vars.raIndex = rt.int(-1) -- -1 idle, else the alias being processed

	local function mtbp_move(self)
		local player = rt.static("Game", "GetPlayer")
		local angle = player:GetAngleZ()
		local xoffset = -(self.mtbpUnitsBehind * rt.static("Math", "Sin", angle))
		local yoffset = -(self.mtbpUnitsBehind * rt.static("Math", "Cos", angle))
		self.mtbpTarget:MoveTo(player, xoffset, yoffset, 0.0, true)
	end

	function C:MoveToBehindPlayer(ThingToMove, unitsBehind, waitForPlayerWeaponsDrawn)
		if self.mtbpBusy then return end -- a second start while one runs is dropped
		self.mtbpBusy = true
		self.mtbpTarget = ThingToMove
		self.mtbpUnitsBehind = unitsBehind
		if not waitForPlayerWeaponsDrawn then
			mtbp_move(self)
			self.mtbpBusy = false
			return
		end
		self.mtbpPoll = true
		self.mtbpWaitFor = 0
		self.mtbpT = 0.0
	end

	function C:RieklingsAppear()
		if self.raIndex >= 0 then return end -- a run happens once
		self.raIndex = 0
		self:OnTick()
	end

	function C:OnTick()
		if self.mtbpPoll then
			if self.mtbpT > 0 then return end
			if rt.static("Game", "GetPlayer"):IsWeaponDrawn() then
				self.mtbpPoll = false
				mtbp_move(self)
				self.mtbpBusy = false
			elseif self.mtbpWaitFor >= 30 then -- Papyrus waits out the 30th second before bailing
				self.mtbpPoll = false -- bailed: ThingToMove stays put, as Papyrus's RETURN
				self.mtbpBusy = false
			else
				self.mtbpWaitFor = self.mtbpWaitFor + 1
				self.mtbpT = self.mtbpT + 1.0
				return
			end
		end
		if self.raIndex < 0 or self.mtbpBusy then return end
		if self.raIndex >= rt.alen(self.RieklingAliasArray) then
			self.raIndex = -1
			self.DLC2RieklingRescueChance:setValue(5)
			self.DLC2RieklingNextAllowedDay:setValue(self.GameDaysPassed:GetValue() + 0.5)
			return
		end
		local curActor = rt.aget(self.RieklingAliasArray, self.raIndex):getActorReference()
		self.raIndex = self.raIndex + 1
		curActor:Reset()
		self:MoveToBehindPlayer(curActor)
	end
end
