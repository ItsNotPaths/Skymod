-- pex: onupdate f328c8dc
-- OnUpdate. Stage 20 (a single update): summon FX and the item trigger every 3 s until the player
-- enters it, then run the stage-40 count once, as the original falls through. Stage 40 (an update
-- every 1 s): count, raise three ghosts, and at 30 swap them for the Augur and start his scene once
-- his 3D is loaded (checked every 2 s).
local rt = require('skymod.rt')

local function trace(msg) rt.static("Debug", "Trace", "MGRitual04: " .. msg) end

return function(C)
    C.__vars.summonClock = rt.stopwatch(0.0)
    C.__vars.augurClock = rt.timer(0.0)
    C.__vars.TickRate = rt.float(0.5)

    local function summon(self)
        self.FXMarker:PlaceAtMe(self.SummonFXActivator)
        self.Alias_ItemTrigger:GetReference():Enable()
        trace("summon FX, item trigger enabled")
    end

    local function ghost(self, n) return self["Ghost0" .. n]:GetReference() end

    local function count(self)
        local t = self.TimerVar
        if t == 2 then ghost(self, 1):Enable(true) end
        if t >= 10 then ghost(self, 2):Enable(true) end
        if t >= 20 then ghost(self, 3):Enable(true) end
        if t == 30 then
            -- the original spins on Ghost03.IsEnabled(); Disable is immediate here
            for n = 1, 3 do ghost(self, n):Disable(true) end
            self.Alias_Augur:GetReference():Enable()
            self:GotoState("AwaitAugur")
            self.augurClock = 0.0 -- a timer keeps running below 0 while unused
            trace("count 30: ghosts off, Augur enabled, waiting for his 3D")
            return self:OnTick()
        end
        self.TimerVar = t + 1
        trace("count " .. self.TimerVar)
    end

    function C:OnUpdate()
        if self:GetStage() == 20 and self.InTrigger == 0 then
            self:GotoState("Summoning")
            self.summonClock = 0.0
            summon(self)
            return
        end
        if self:GetStage() == 40 then count(self) end
    end

    local Summoning = rt.state(C, "Summoning")
    function Summoning:OnTick()
        if self.InTrigger ~= 0 then
            self:GotoState("")
            trace("player in trigger, summoning ends")
            if self:GetStage() == 40 then count(self) end
            return
        end
        if self.summonClock < 3.0 then return end
        self.summonClock = self.summonClock - 3.0
        summon(self)
    end

    local AwaitAugur = rt.state(C, "AwaitAugur")
    function AwaitAugur:OnTick()
        if self.augurClock > 0 then return end
        if not self.Alias_Augur:GetReference():Is3DLoaded() then
            self.augurClock = self.augurClock + 2.0
            return
        end
        self:GotoState("")
        self.TimerVar = self.TimerVar + 1
        self.MGRitual04AugurEndScene:Start()
        self:UnregisterForUpdate()
        trace("Augur loaded, end scene started, updates off")
    end
    -- Papyrus ran each update meanwhile in parallel with TimerVar still 30
    function AwaitAugur:OnUpdate() trace("update while waiting for the Augur, dropped") end
end
