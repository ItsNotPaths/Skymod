-- pex: firetrap 92a00c18
-- fireTrap waited initialDelay, then looped: place the hazard once, or wait 0.5s on later passes,
-- then reset and go again while `loop` or minimumFiringTime is up. GetCurrentRealTime()+n becomes
-- a timer set to n. The Papyrus body calls GotoState("Reset") twice when it stops while loaded
-- (redundant: the second call lands on the same state); this keeps the one call.
local rt = require('skymod.rt')

local FireTrap = rt.sequence("Idle", "AwaitDelay", "Check", "AfterPass")

local function run(self, stage, wait, steps)
    while steps[self[stage]] and (not wait or self[wait] <= 0) do
        local nxt = steps[self[stage]](self)
        if not nxt then return end
        self[stage] = nxt
    end
end

local function finish(self)
    if self.isLoaded then
        self.isFiring = false
        self.myHazardRef:Disable(false)
        self.myHazardRef:Delete()
    end
    self:GotoState("Reset")
end

local fire_steps = {
    [FireTrap.AwaitDelay] = function(self)
        self.trapDisarmed = self.fireOnlyOnce
        return FireTrap.Check
    end,
    [FireTrap.Check] = function(self)
        if self.finishedPlaying or not self.isLoaded then
            finish(self)
            return FireTrap.Idle
        end
        if not self.HazardIsPlaced then
            self.myHazardRef = self:PlaceAtMe(self.myHazard, 1, false, false)
            self.HazardIsPlaced = true
            self.fireWait = 0.0
        else
            self.fireWait = 0.5
        end
        return FireTrap.AfterPass
    end,
    [FireTrap.AfterPass] = function(self)
        self.finishedPlaying = true
        if self.loop or self.firingTime <= 0 then
            self.finishedPlaying = false -- resetLimiter()
        end
        return FireTrap.Check
    end,
}

return function(C)
    local V = C.__vars
    V.fireStage, V.fireWait = FireTrap.Idle, rt.timer(0.0)
    V["firingtime"] = rt.timer(0.0) -- GetCurrentRealTime() + minimumFiringTime becomes a timer

    function C:FireTrap()
        if self.fireStage ~= FireTrap.Idle then return end -- a run happens once
        self.isFiring = true
        self.finishedPlaying = false
        self.firingTime = self.minimumFiringTime
        if self.WindupSound then self.WindupSound:Play(self) end
        self.fireWait, self.fireStage = self.initialDelay, FireTrap.AwaitDelay
    end

    function C:OnTick()
        run(self, "fireStage", "fireWait", fire_steps)
    end
end
