-- pex: position01.onactivate 560d53c9
-- pex: position02.onactivate a5330c56
-- pex: position03.onactivate f40353bf
-- pex: position04.onactivate 34eecc4c
-- pex: position05.onactivate 98e95e9d
-- pex: position06.onactivate da7d6f2a
-- pex: position07.onactivate 30333973
-- pex: position08.onactivate 87cfd900
-- pex: rotatedometostate d6511af1
-- RotateDomeToState turned the dome and waited for TransSeq0(N+1), then marked the dome ready (and
-- lit it if the beams were ready) or not; the caller then set the position. The event now does
-- both: TransSeq02..09 end at positions 2..8, then 1.
local rt = require('skymod.rt')

return function(C)
	local Busy = rt.state(C, "busy")

	local function set_ready(q, dome, v)
		if dome >= 1 and dome <= 3 then q["Dome0" .. dome .. "Ready"] = v end
	end

	function C:RotateDomeToState(StateNumber, AnimEventNumber)
		self:GotoState("busy")
		self:RegisterForAnimationEvent(self, "TransSeq0" .. (AnimEventNumber + 1))
		self:PlayAnimation("Ice0" .. AnimEventNumber)
	end

	for i = 1, 8 do
		rt.state(C, "Position0" .. i).OnActivate = function(self, TriggerRef)
			self:RotateDomeToState(i % 8 + 1, i)
		end
	end

	local function arrived(self, pos)
		local q = rt.cast(self.MG06, "MG06QuestScript")
		if pos == self.SolveState then
			self.DomeReady = true
			set_ready(q, self.DomeNumber, true)
			if q.BeamsReady then
				self:PlayAnimation("LightRay")
				q.CrystalLocked = 1
				local d = self.DomeNumber
				if d >= 1 and d <= 3 then rt.cast(self["Button0" .. d], "MG06ButtonScript"):Close() end
				if q.Dome01Ready and q.Dome02Ready and q.Dome03Ready then self.MG06:SetStage(55) end
			end
		elseif self.DomeReady then
			self.DomeReady = false
			set_ready(q, self.DomeNumber, false)
		end
		self:GotoState("Position0" .. pos)
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		for n = 2, 9 do
			if asEventName == "TransSeq0" .. n then return arrived(self, n == 9 and 1 or n) end
		end
	end
end
