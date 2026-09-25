-- pex: hermaeusmoraappear.onbeginstate cdb3db93 301ea9eb
-- pex: hermaeusmoradisappear.onbeginstate 661925ca a0e2a812
-- Appear walked myHMface[lastState..newState) disabling, waiting, re-enabling and polling
-- Is3DLoaded (capped at iMaxCount) before the blend; Disappear walked [0..lastState) with a plain
-- wait. Now a stage index plus a timer walk the same range in OnTick, one face at a time.
local rt = require('skymod.rt')

return function(C)
	C.Phase = rt.sequence("Idle", "Disabling", "Polling")
	C.__vars.mmIndex = rt.int(0)
	C.__vars.mmPhase = C.Phase.Idle
	C.__vars.mmT = rt.timer(0.0)
	C.__vars.mmCount = rt.int(0)
	local Appear = rt.state(C, "HermaeusMoraAppear")
	local Disappear = rt.state(C, "HermaeusMoraDisappear")
	local P = C.Phase

	function Appear:OnTick()
		while self.mmIndex < self.newState do
			local idx = self.mmIndex
			local face = self.myHMface[idx]
			if self.mmPhase == P.Idle then
				if not face then
					self.mmIndex = idx + 1
				else
					face:Disable()
					self.mmPhase = P.Disabling
					self.mmT = self.mmT + rt.static("Utility", "RandomFloat", 0.2, 0.5)
					return
				end
			elseif self.mmPhase == P.Disabling then
				if self.mmT > 0 then return end
				face:Enable()
				self.mmPhase = P.Polling
				self.mmCount = 0
				self.mmT = 0.0 -- Papyrus checks Is3DLoaded before the first poll wait
			else -- Polling
				if self.mmT > 0 then return end
				if face:Is3DLoaded() or self.mmCount >= self.iMaxCount then
					face:SetAnimationVariableFloat("fToggleBlend", 1.0)
					self.mmPhase = P.Idle
					self.mmIndex = idx + 1
				else
					self.mmCount = self.mmCount + 1
					self.mmT = self.mmT + rt.static("Utility", "RandomFloat", 0.2, 0.5)
					return
				end
			end
		end
		self.lastState = self.newState
	end

	function Appear:OnBeginState()
		self.mmIndex = self.lastState
		self.mmPhase = P.Idle
		self.mmT = 0.0 -- starting a wait sets its clock; mmT free-runs while idle between runs
		self:OnTick()
	end

	function Disappear:OnTick()
		while self.mmIndex < self.lastState do
			local idx = self.mmIndex
			local face = self.myHMface[idx]
			if not face then
				self.mmIndex = idx + 1
			elseif self.mmPhase == P.Idle then
				self.mmPhase = P.Disabling -- reused only as "waiting" here
				self.mmT = self.mmT + rt.static("Utility", "RandomFloat", 0.2, 0.5)
				return
			else
				if self.mmT > 0 then return end
				face:SetAnimationVariableFloat("fToggleBlend", 0.0)
				self.mmPhase = P.Idle
				self.mmIndex = idx + 1
			end
		end
		self.newState = 0
		self.lastState = 0
	end

	function Disappear:OnBeginState()
		self.mmIndex = 0
		self.mmPhase = P.Idle
		self.mmT = 0.0
		self:OnTick()
	end
end
