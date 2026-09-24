-- pex: firetrap e455085e
-- fireTrap waited firingSpinup, then looped: fire, mark finishedFiring, wait firingRate, and (only
-- if `loop`) clear finishedFiring to go again. It stops once not loaded, or after one pass when
-- `loop` is false. Now a sequence of two clocked stages, re-armed by a fresh call once idle.
local rt = require('skymod.rt')

local FireTrap = rt.sequence("Idle", "Spinup", "Check", "Waiting")

local function run(self, stage, wait, steps)
    while steps[self[stage]] and (not wait or self[wait] <= 0) do
        local nxt = steps[self[stage]](self)
        if not nxt then return end
        self[stage] = nxt
    end
end

local function do_fire_pass(self)
    local aa = self.aaSpellToCast
    if aa == 2 or aa == 5 or aa == 7 then
        if not self.concentrationCastLoop then
            self:FireByCastingType()
            self.concentrationCastLoop = true
        end
    else
        self:FireByCastingType()
    end
end

local function finish_fire(self)
    self.concentrationCastLoop = false
    local aa = self.aaSpellToCast
    if aa == 2 or aa == 5 or aa == 7 then self:InterruptCast() end
    if self.isLoaded then
        self.isFiring = false
        self:GotoState("Reset")
    end
end

local fire_steps = {
    [FireTrap.Spinup] = function(self) return FireTrap.Check end,
    [FireTrap.Check] = function(self)
        if self.finishedFiring or not self.isLoaded then
            finish_fire(self)
            return FireTrap.Idle
        end
        do_fire_pass(self)
        self.finishedFiring = true
        self.fireWait = self.firingRate
        return FireTrap.Waiting
    end,
    [FireTrap.Waiting] = function(self)
        if self.loop then self.finishedFiring = false end -- resetLimiter()
        return FireTrap.Check
    end,
}

return function(C)
    local V = C.__vars
    V.fireStage, V.fireWait = FireTrap.Idle, rt.timer(0.0)

    function C:FireTrap()
        if self.fireStage ~= FireTrap.Idle then return end -- a run happens once
        self.isFiring = true
        if not self.weaponResolved then
            self:ResolveLeveledWeapon()
            self.weaponResolved = true
        end
        if self.trapDisarmed then return end
        self.fireWait, self.fireStage = self.firingSpinup, FireTrap.Spinup
    end

    function C:OnTick()
        run(self, "fireStage", "fireWait", fire_steps)
    end
end
