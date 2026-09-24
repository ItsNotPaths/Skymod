-- pex: default.onactivate b195ba06
-- pex: fight1.onactivate 27d36da3
-- pex: fight2.onactivate e28cda60
-- pex: fight3.onactivate 73d7cd88
-- default.OnActivate picked a fight by the gem pattern, went to that state, then ran a wait-laden
-- startup (3 s, 2 s, and for fight1 two more). Each fightN.OnActivate counted kills and, at 6/7/5,
-- waited 2 s and reset to default. Now a step list plus a timer runs the startup in the fight
-- state's OnTick, and the kill-done wait is one more timer on the same field.
local rt = require('skymod.rt')

-- hasGem is a Bool property; Papyrus compared it to 0/1, so normalize here.
local function gem(self, n) return self["gem0" .. n .. "Script"].hasGem and 1 or 0 end

local function which_fight(self)
	if not self.fight1Done and gem(self, 1) == 0 and gem(self, 2) == 0 and gem(self, 3) == 0
		and gem(self, 4) == 1 and gem(self, 5) == 0 and gem(self, 6) == 0 and gem(self, 7) == 0
		and gem(self, 8) == 0 and gem(self, 9) == 1 then
		return 1
	end
	if self.fight1Done and not self.fight2Done and gem(self, 1) == 0 and gem(self, 2) == 1
		and gem(self, 3) == 0 and gem(self, 4) == 0 and gem(self, 5) == 0 and gem(self, 6) == 0
		and gem(self, 7) == 0 and gem(self, 8) == 1 and gem(self, 9) == 1 then
		return 2
	end
	if self.fight1Done and self.fight2Done and not self.fight3Done and gem(self, 1) == 1
		and gem(self, 2) == 0 and gem(self, 3) == 0 and gem(self, 4) == 0 and gem(self, 5) == 1
		and gem(self, 6) == 0 and gem(self, 7) == 1 and gem(self, 8) == 0 and gem(self, 9) == 1 then
		return 3
	end
	return nil
end

-- Explicit [N] keys throughout: this Lua fork is 0-based for positional { a, b } literals, and
-- these lists are walked by a 1-based step field (script-api.md's own examples use named/explicit
-- keys the same way for this reason).
local START = {
	fight1 = {
		[1] = { wait = 3.0, fn = function(self) self:gemsGoToFightState(); self.Console:PlayAnimation("stage2") end },
		[2] = { wait = 2.0, fn = function(self)
			self.Console:PlayAnimation("stage3")
			self.Console:RampRumble(1, 3, 1500)
			self.LightEnablerFight01:Enable()
			self.StoneWallFast:Play(self)
			self.Fight1PlatformL:SetAnimationVariablefloat("fToggleBlend", 1)
			self.Fight1PlatformR:SetAnimationVariablefloat("fToggleBlend", 1)
			self.EncounterEnableMarkerFight01:Enable()
		end },
		[3] = { wait = 1.0, fn = function(self)
			self.Gate01:Activate(self.Gate01)
			self.Gate02:Activate(self.Gate02)
			self.Gate03:Activate(self.Gate03)
			self.AmbushTriggerFight01:Activate(self.AmbushTriggerFight01)
		end },
		[4] = { wait = 4.0, fn = function(self)
			self.wallSoundLoop = self.StoneWallSlowLoop:Play(self)
			self.Fight1PlatformL:SetAnimationVariablefloat("fDampRate", 0.0008)
			self.Fight1PlatformR:SetAnimationVariablefloat("fDampRate", 0.0008)
			self.Fight1PlatformL:SetAnimationVariablefloat("fToggleBlend", 0)
			self.Fight1PlatformR:SetAnimationVariablefloat("fToggleBlend", 0)
		end },
	},
	fight2 = {
		[1] = { wait = 3.0, fn = function(self) self:gemsGoToFightState(); self.Console:PlayAnimation("stage2") end },
		[2] = { wait = 2.0, fn = function(self)
			self.Console:PlayAnimation("stage3")
			self.Console:RampRumble(1, 3, 1500)
			self.EncounterEnableMarkerFight02:Enable()
			self.LightEnablerFight02:Enable()
			self.Fight2WallActivator:Activate(self.Fight2WallActivator)
			self.CollisionEnablerFight02:Enable()
			self.AmbushTriggerFight02:Activate(self.AmbushTriggerFight02)
			self.Gate01:Activate(self.Gate01)
			self.Gate02:Activate(self.Gate02)
			self.Gate03:Activate(self.Gate03)
		end },
	},
	fight3 = {
		[1] = { wait = 3.0, fn = function(self) self:gemsGoToFightState(); self.Console:PlayAnimation("stage2") end },
		[2] = { wait = 2.0, fn = function(self)
			self.Console:PlayAnimation("stage3")
			self.Console:RampRumble(1, 4, 1500)
			self.LightEnablerFight03:Enable()
			self.Fight3platforms:PlayAnimation("stage1")
			self.CollisionEnablerFight03:Enable()
			self.waterSoundLoop = self.WaterRiseDrainLoop:Play(self)
			self.Fight3water:TranslateTo(4823.4160, 250.8519, -518.4196, 0, 0, 0, 50.0)
			self.WaterSoundMarker01:Enable()
			self.WaterSoundMarker02:Enable()
			rt.static("Sound", "StopInstance", self.waterSoundLoop)
			self.EncounterEnableMarkerFight03:Enable()
			self.Fight3SparksTrigger:Activate(self.Fight3SparksTrigger)
			self.AmbushTriggerFight03:Activate(self.AmbushTriggerFight03)
			self.Gate01:Activate(self.Gate01)
			self.Gate02:Activate(self.Gate02)
			self.Gate03:Activate(self.Gate03)
		end },
	},
}

local FINISH = {
	fight1 = function(self)
		self.Gate01:Activate(self.Gate01)
		self.Gate02:Activate(self.Gate02)
		self.Gate03:Activate(self.Gate03)
		self.LightEnablerFight01:Disable()
		rt.static("Sound", "StopInstance", self.wallSoundLoop)
		self.StoneWallFast:Play(self)
		self.Fight1PlatformL:SetAnimationVariablefloat("fDampRate", 0.03)
		self.Fight1PlatformR:SetAnimationVariablefloat("fDampRate", 0.03)
		self.CollisionEnablerExitGates:Disable()
		self.ExitGate01:Activate(self.ExitGate01)
		self.ExitGate02:Activate(self.ExitGate02)
		self.CollisionEnablerExitGates:Disable()
		self.PrizeGate01:Activate(self.PrizeGate01)
		self.Console:PlayAnimation("Stage4")
		self:gemsReset()
	end,
	fight2 = function(self)
		self.Gate01:Activate(self.Gate01)
		self.Gate02:Activate(self.Gate02)
		self.Gate03:Activate(self.Gate03)
		self.LightEnablerFight02:Disable()
		self.Fight2WallActivator:Activate(self.Fight2WallActivator)
		self.Fight2TrapDisabler:Activate(self.Fight2TrapDisabler)
		self.CollisionEnablerFight02:Disable()
		self.ExitGate01:Activate(self.ExitGate01)
		self.ExitGate02:Activate(self.ExitGate02)
		self.CollisionEnablerExitGates:Disable()
		self.PrizeGate02:Activate(self.PrizeGate02)
		self.Console:PlayAnimation("Stage4")
		self:gemsReset()
	end,
	fight3 = function(self)
		self.Gate01:Activate(self.Gate01)
		self.Gate02:Activate(self.Gate02)
		self.Gate03:Activate(self.Gate03)
		self.LightEnablerFight03:Disable()
		self.waterSoundLoop = self.WaterRiseDrainLoop:Play(self)
		self.Fight3water:TranslateTo(4823.4160, 250.8519, -640, 0, 0, 0, 50.0)
		self.WaterSoundMarker01:Disable()
		self.WaterSoundMarker02:Disable()
		rt.static("Sound", "StopInstance", self.waterSoundLoop)
		self.Fight3SparksTrigger:Activate(self.Fight3SparksTrigger)
		self.Fight3platforms:PlayAnimation("stage2")
		self.CollisionEnablerFight03:Disable()
		self.ExitGate01:Activate(self.ExitGate01)
		self.ExitGate02:Activate(self.ExitGate02)
		self.CollisionEnablerExitGates:Disable()
		self.PrizeGate03:Activate(self.PrizeGate03)
		self.Console:PlayAnimation("Stage4")
		self.dlc2KagrumezQST:SetStage(250)
		self.KagrumezLocation:SetCleared()
		self:gemsReset()
		self.KagrumezGem01:tryToClear()
		self.KagrumezGem02:tryToClear()
		self.KagrumezGem03:tryToClear()
		self.KagrumezGem04:tryToClear()
		self.KagrumezGem05:tryToClear()
	end,
}

-- Explicit [N] keys on `steps` make direct lookups exact regardless of indexing base; walked by
-- nil, not by #steps, since a table with no [0] has an ambiguous length in this 0-based fork.
local function run_start(self, steps)
	while true do
		if self.kagT > 0 then return end
		local s = steps[self.kagStep]
		if not s then break end
		s.fn(self)
		self.kagStep = self.kagStep + 1
		local nxt = steps[self.kagStep]
		if nxt then self.kagT = self.kagT + nxt.wait end
	end
	self.kagStep = 0
end

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.kagStep = rt.int(0) -- 0 idle, else 1-based index into START[state]
	C.__vars.kagT = rt.timer(0.0)
	C.__vars.kagFinishing = rt.bool(false)
	local Default = rt.state(C, "default")
	local Fight1 = rt.state(C, "fight1")
	local Fight2 = rt.state(C, "fight2")
	local Fight3 = rt.state(C, "fight3")

	function Default:OnActivate(Actronaut)
		local n = which_fight(self)
		if not n then return end
		self:GotoState("fight" .. n)
		self.Console:PlayAnimation("stage1")
		self.fightCountGlobal:SetValueInt(0)
		self.ExitGate01:Activate(self.ExitGate01)
		self.ExitGate02:Activate(self.ExitGate02)
		self.CollisionEnablerExitGates:Enable()
		if n == 2 then self.EncounterEnableMarkerFight01:Disable() end
		if n == 3 then self.EncounterEnableMarkerFight02:Disable() end
		local steps = START["fight" .. n]
		self.kagStep = 1
		self.kagT = steps[1].wait -- fresh run: kagT may have drifted since the last one
		self:OnTick()
	end

	local function on_kill(self, name, doneCount)
		self.enemiesKilled = self.fightCountGlobal:GetValueInt()
		if self.fightCountGlobal:GetValueInt() ~= doneCount then return end
		self.fightCountGlobal:SetValueInt(0)
		self[name] = true
		self.kagFinishing = true
		self.kagT = 2.0 -- fresh wait: kagT idled since the startup steps finished
	end

	function Fight1:OnActivate(Actronaut) on_kill(self, "fight1Done", 6) end
	function Fight2:OnActivate(Actronaut) on_kill(self, "fight2Done", 7) end
	function Fight3:OnActivate(Actronaut) on_kill(self, "fight3Done", 5) end

	local function fight_tick(self, name)
		if self.kagFinishing then
			if self.kagT > 0 then return end
			self.kagFinishing = false
			self:GotoState("default")
			FINISH[name](self)
			return
		end
		if self.kagStep > 0 then run_start(self, START[name]) end
	end

	function Fight1:OnTick() fight_tick(self, "fight1") end
	function Fight2:OnTick() fight_tick(self, "fight2") end
	function Fight3:OnTick() fight_tick(self, "fight3") end
end
