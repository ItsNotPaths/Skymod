-- pex: endsequenceactive.onbeginstate cbb8d9c6
-- OnBeginState polled every 1 s until all draugr were dead or the cell unloaded; each pass could
-- run up to four phases in turn (each phase a fixed activate/wait list, with an extra pause first
-- if the player or the companion was badly hurt at the moment the phase started). Now a step index
-- per phase plus an outer scan index (dcNext: which phase to check next in the current pass) walk
-- the same shape in OnTick. lastDraugrKilled was trace-only in Papyrus and is dropped.
local rt = require('skymod.rt')

local function hurt(a) return a and a:GetActorValuePercentage("health") < 0.25 end

local function phase_wait(self, amount)
	local companion = rt.cast(self.C01Script.Observer:GetReference(), "Actor")
	if hurt(rt.static("Game", "GetPlayer")) or hurt(companion) then return amount end
	return 0.0
end

local function act(name) return function(self) self[name]:activate(self) end end

-- Explicit [N] keys throughout: this Lua fork is 0-based for positional { a, b } literals, and
-- these lists are walked by 1-based fields (dcStep, and i in 1..4 below).
local PHASE = {
	[1] = {
		[1] = { wait = function(self) return phase_wait(self, 7.0) end, fn = act("draugr05") },
		[2] = { wait = 2.0, fn = act("draugr12") },
		[3] = { wait = 1.0, fn = act("draugr16") },
	},
	[2] = {
		[1] = { wait = function(self) return phase_wait(self, 5.0) end, fn = act("draugr03") },
		[2] = { wait = 2.0, fn = act("draugr07") },
		[3] = { wait = 1.0, fn = act("draugr10") },
		[4] = { wait = 3.0, fn = act("draugr13") },
		[5] = { wait = 5.0, fn = act("draugr15") },
	},
	[3] = {
		[1] = { wait = function(self) return phase_wait(self, 7.0) end, fn = act("draugr01") },
		[2] = { wait = 1.0, fn = act("draugr06") },
		[3] = { wait = 2.0, fn = act("draugr09") },
		[4] = { wait = 3.0, fn = act("draugr02") },
		[5] = { wait = 3.0, fn = act("draugr14") },
	},
	[4] = {
		[1] = { wait = function(self) return phase_wait(self, 7.0) end, fn = act("draugr04") },
		[2] = { wait = 1.0, fn = act("draugr08") },
		[3] = { wait = 5.0, fn = act("draugr11") },
		[4] = { wait = 1.0, fn = act("draugr17") },
		[5] = { wait = 1.0, fn = act("bossDraugr") },
	},
}
local PHASE_BOOL = { [1] = "phaseOne", [2] = "phaseTwo", [3] = "phaseThree", [4] = "phaseFour" }
local PHASE_READY = { [2] = "phaseTwoReady", [3] = "phaseThreeReady", [4] = "phaseFourReady" }

return function(C)
	C.__vars.dcPhase = rt.int(0) -- 0 idle/scanning, 1-4 stepping that phase
	C.__vars.dcStep = rt.int(0)
	C.__vars.dcNext = rt.int(0) -- 0: re-check the while-condition; 1-5: resume the phase scan here
	C.__vars.dcT = rt.timer(0.0)
	local EndSeq = rt.state(C, "endSequenceActive")

	function EndSeq:OnBeginState()
		self.C01Script = rt.cast(self.C01, "c01questscript")
		self.OpenDoor:SetOpen(false)
		self.OpenDoor:Lock()
		self.OpenDoor:SetLockLevel(5)
		self.LockedDoor:Enable()
		self.OpenDoor:Disable()
		self.dcPhase, self.dcNext = 0, 0
		self.dcT = 0.0 -- fresh run: dcT idled since the ref's instance was created
		self:OnTick()
	end

	function EndSeq:OnTick()
		if self.dcT > 0 then return end
		if self.dcPhase > 0 then
			local steps = PHASE[self.dcPhase]
			local s = steps[self.dcStep]
			s.fn(self)
			self.dcStep = self.dcStep + 1
			local nxt = steps[self.dcStep]
			if nxt then
				self.dcT = self.dcT + (type(nxt.wait) == "function" and nxt.wait(self) or nxt.wait)
			else
				self.dcPhase = 0 -- steps done; resume the scan from dcNext at once
			end
			return
		end
		if self.dcNext == 0 then
			if self.draugrKilled >= self.totalDraugr or not self.isLoaded then
				self.lastDraugr:activate(self)
				self:GotoState("endSequenceComplete")
				self.OpenDoor:Enable()
				self.LockedDoor:Disable()
				return
			end
			self.dcNext = 1
			self.dcT = self.dcT + 1.0
			return
		end
		for i = self.dcNext, 4 do
			local flag, ready = PHASE_BOOL[i], PHASE_READY[i]
			if self[flag] and (not ready or self.draugrKilled >= self[ready]) then
				self[flag] = false
				self.dcPhase = i
				self.dcStep = 1
				self.dcNext = i + 1
				local w = PHASE[i][1].wait
				self.dcT = self.dcT + (type(w) == "function" and w(self) or w)
				return
			end
		end
		self.dcNext = 0 -- scanned to the end; the next tick re-checks the while-condition
	end
end
