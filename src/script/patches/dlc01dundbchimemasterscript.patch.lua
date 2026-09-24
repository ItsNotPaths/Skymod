-- pex: chimehit a4fb874f
-- pex: oncellattach 8c73fb33
-- pex: setupchimes d649568b
-- OnCellAttach set up the five chimes one after another: open, wait for "done", a random pause,
-- close. A wrong ChimeHit ran its fail response (spawns after 2 s, or the ballista volley of 11
-- waits) before resetting the puzzle. Now SettingUp and Failing are states whose OnTick walks the
-- steps; `setup` is the chime being set up, `fail` the fail step. Chimes read the Failing state.
local rt = require('skymod.rt')

local Fail = rt.sequence("Idle", "Spiders", "Spheres", "Centurion",
	"Light1", "Light2", "Aim1", "Fire1a", "Fire1b", "Fire2a", "Fire2b", "Fire3a", "Fire3b", "Dark1", "Dark2")

local function link(self, n) return self:GetLinkedRef(self["LinkCustom0" .. n]) end
local function reset_chimes(self)
	for n = 1, 5 do
		local chime = rt.cast(link(self, n), "dlc01dundbchimescript")
		chime:StopGlow()
		chime.AlreadyHit = false
	end
end
local function aim(self, n)
	self.Ballista01:TranslateToRef(self.Ballista01:GetLinkedRef(self["LinkCustom0" .. n]), 1.0, 10.0)
	self.Ballista02:TranslateToRef(self.Ballista02:GetLinkedRef(self["LinkCustom0" .. n]), 1.0, 10.0)
end
local function light(self, b, on)
	local l = b:GetLinkedRef(self.LinkCustom04)
	if on then l:EnableNoWait() else l:DisableNoWait() end
end

-- each fail step: the wait before it, what it does, and whether the fail ends after it
local steps = {
	Spiders = { 2.0, function(self) for i = 1, 4 do local s = self["Spider0" .. i]; s:Activate(s) end end, true },
	Spheres = { 2.0, function(self) self.Sphere01:Activate(self.Sphere01); self.Sphere02:Activate(self.Sphere02) end, true },
	Centurion = { 2.0, function(self)
		local centurion = self:GetLinkedRef()
		rt.cast(centurion, "Actor"):SetGhost(false)
		local gate = link(self, 6)
		gate:BlockActivation(false)
		gate:Lock(false)
		gate:Activate(gate)
		centurion:Activate(centurion)
	end, true },
	Light1 = { 1.0, function(self) light(self, self.Ballista01, true) end },
	Light2 = { 0.25, function(self) light(self, self.Ballista02, true) end },
	Aim1 = { 1.0, function(self) aim(self, 1) end },
	Fire1a = { 2.0, function(self) self.Ballista01:Activate(self) end },
	Fire1b = { 0.25, function(self) self.Ballista02:Activate(self); aim(self, 2) end },
	Fire2a = { 2.0, function(self) self.Ballista01:Activate(self) end },
	Fire2b = { 0.25, function(self) self.Ballista02:Activate(self); aim(self, 3) end },
	Fire3a = { 2.0, function(self) self.Ballista01:Activate(self) end },
	Fire3b = { 0.5, function(self) self.Ballista02:Activate(self) end },
	Dark1 = { 1.0, function(self) light(self, self.Ballista01, false) end },
	Dark2 = { 0.25, function(self) light(self, self.Ballista02, false) end, true },
}

return function(C)
	C.__vars.fail = Fail.Idle
	C.__vars.failClock = rt.stopwatch(0.0)
	C.__vars.setup = rt.int(0)
	C.__vars.setupClock = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(0.05) -- the volley's shortest wait is 0.25 s
	local SettingUp, Failing = rt.state(C, "SettingUp"), rt.state(C, "Failing")

	function C:OnCellAttach()
		if self.DoOnce or self.setup ~= 0 then return end
		self:GotoState("SettingUp")
		self.setup = 1
		self:SetupChimes(link(self, 1))
	end

	function C:SetupChimes(akLink)
		self.setupClock = rt.None
		self:RegisterForAnimationEvent(self, "done")
		self:PlayAnimation("open")
	end

	function SettingUp:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "done" or self.setupClock ~= rt.None then return end
		self.setupClock = rt.static("Utility", "RandomFloat", 0.0, 1.0)
	end

	function SettingUp:OnTick()
		if self.setupClock == rt.None or self.setupClock > 0 then return end
		self.setupClock = rt.None
		self:PlayAnimation("close")
		rt.cast(link(self, self.setup), "dlc01dundbchimescript").ChimeMaster = self.form
		if self.setup < 5 then
			self.setup = self.setup + 1
			return self:SetupChimes(link(self, self.setup))
		end
		self.setup = 0
		rt.cast(self:GetLinkedRef(), "Actor"):SetGhost()
		for _, n in ipairs({ 6, 8, 9 }) do link(self, n):BlockActivation() end
		self.DoOnce = true
		self:GotoState("")
	end

	local function right(self, n, chimeRef)
		chimeRef:GetLinkedRef():EnableNoWait()
		if n < 5 then
			self.NextCorrectChime = self.NextCorrectChime + 1
			local next = self.NextCorrectChime
			local sound = ({ [2] = self.QSTArkngthamzPuzzleSuccessA, [3] = self.QSTArkngthamzPuzzleSuccessB,
				[4] = self.QSTArkngthamzPuzzleSuccessC, [5] = self.QSTArkngthamzPuzzleSuccessD })[next]
			if sound then sound:Play(link(self, 6)) end
			if next == 3 then self.DLC1LD_13e_KatriaSuccess1:Start()
			elseif next == 4 or next == 5 then self.DLC1LD_13f_KatriaSuccess2:Start() end
		elseif not self.AlreadySolved then
			self.QSTArkngthamzPuzzleSuccessE:Play(link(self, 6))
			self.DLC1ArkgnthamzRumbleGlobal:SetValue(0)
			for _, n2 in ipairs({ 8, 9 }) do
				local door = link(self, n2)
				door:BlockActivation(false)
				door:Lock(false)
				door:Activate(link(self, 6))
			end
			self.DLC1LD_Arkngthamz:SetStage(90)
			self.AlreadySolved = true
		else
			self.ChimeFailCount = self.ChimeFailCount + 1
			self.NextCorrectChime = 1
			reset_chimes(self)
			self.EvilEyes:DisableNoWait()
		end
		rt.static("Game", "ShakeCamera", { afStrength = 0.1 })
	end

	local function finish(self)
		self.fail = Fail.Idle
		self:GotoState("")
		self.ChimeFailCount = self.ChimeFailCount + 1
		self.NextCorrectChime = 1
		reset_chimes(self)
		self.EvilEyes:DisableNoWait()
	end

	function C:ChimeHit(akChimeNumber, ChimeRef)
		rt.cast(self.PuzzleHintTrigger, "dlc1ld_puzzlehinttriggerscript"):DelayHint()
		-- a right chime has no wait, so it runs even during a fail, as Papyrus's parallel call did
		if akChimeNumber == self.NextCorrectChime then return right(self, akChimeNumber, ChimeRef) end
		if self.fail ~= Fail.Idle then return end -- a run happens once
		self.QSTArkngthamzPuzzleFail:Play(link(self, 6))
		self.DLC1LD_13g_KatriaFail:Start()
		local count = self.ChimeFailCount
		local first = count == 0 and Fail.Spiders or count == 1 and Fail.Spheres or count == 3 and Fail.Centurion
			or Fail.Light1
		self.EvilEyes:EnableNoWait()
		rt.static("Game", "ShakeCamera", { afStrength = 0.4 })
		self.fail, self.failClock = first, 0.0
		self:GotoState("Failing")
	end

	function Failing:OnTick()
		while self.fail ~= Fail.Idle do
			local step = steps[tostring(self.fail)]
			if self.failClock < step[0] then return end
			self.failClock = self.failClock - step[0]
			local done = step[2]
			self.fail = done and Fail.Idle or self.fail + 1 -- before the action
			step[1](self)
			if done then finish(self) end
		end
	end
end
