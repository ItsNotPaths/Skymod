-- pex: risingphase1.onbeginstate 01ff1e96
-- pex: risingphase2.onbeginstate 849557e1
-- pex: waterrise2 a91971f7
-- risingPhase1 waited 4s then 0.1s before starting the translate, then polled every 0.3s until a
-- pipe broke or the water rose close to its target (one pass in practice: pipe B01's height check
-- is commented out in the source, so it always breaks on the first pass and ends the poll).
-- risingPhase2 waited 6s, then translated and handed off to WaterRise2, a second poll (also 0.3s)
-- that breaks and then submerges each pipe as the water passes its height. Both polls are now
-- OnTick; the class already has one (the S6 split of risingPhase1.OnActivate's Wait(0.1)), so
-- this one calls it first.
local rt = require('skymod.rt')

local RP1 = rt.sequence("Idle", "AwaitCrumble", "AwaitTranslate", "Polling")
local RP2 = rt.sequence("Idle", "AwaitTranslate")

-- run advances one machine: while its wait is up, run the step for its stage. A step returns the
-- next stage, or nil to stay put (it may set a new wait first).
local function run(self, stage, wait, steps)
    while steps[self[stage]] and (not wait or self[wait] <= 0) do
        local nxt = steps[self[stage]](self)
        if not nxt then return end
        self[stage] = nxt
    end
end

-- (started flag / broken-or-done flag, height, pipe) for each of the 8 pipes. Order does not
-- matter: every entry is independent within one pass.
local function trig(flag, height, pipe) return { flag, height, pipe } end
local broken_triggers = {
    trig("WaterSplashStartedB01", "WaterSplashHeightB01", "PipeControllerBig01"),
    trig("WaterSplashStartedB02", "WaterSplashHeightB02", "PipeControllerBig02"),
    trig("WaterSplashStartedB03", "WaterSplashHeightB03", "PipeControllerBig03"),
    trig("WaterSplashStartedB04", "WaterSplashHeightB04", "PipeControllerBig04"),
    trig("WaterSplashStartedS01", "WaterSplashHeightS01", "PipeControllerSmall01"),
    trig("WaterSplashStartedS02", "WaterSplashHeightS02", "PipeControllerSmall02"),
    trig("WaterSplashStartedS03", "WaterSplashHeightS03", "PipeControllerSmall03"),
    trig("WaterSplashStartedS04", "WaterSplashHeightS04", "PipeControllerSmall04"),
}
local submerged_triggers = {
    trig("PipeControllerBig01Done", "PipeControllerBig01Height", "PipeControllerBig01"),
    trig("PipeControllerBig02Done", "PipeControllerBig02Height", "PipeControllerBig02"),
    trig("PipeControllerBig03Done", "PipeControllerBig03Height", "PipeControllerBig03"),
    trig("PipeControllerBig04Done", "PipeControllerBig04Height", "PipeControllerBig04"),
    trig("PipeControllerSmall01Done", "PipeControllerSmall01Height", "PipeControllerSmall01"),
    trig("PipeControllerSmall02Done", "PipeControllerSmall02Height", "PipeControllerSmall02"),
    trig("PipeControllerSmall03Done", "PipeControllerSmall03Height", "PipeControllerSmall03"),
    trig("PipeControllerSmall04Done", "PipeControllerSmall04Height", "PipeControllerSmall04"),
}

local function fire_trigger(self, t, state, aftershock)
    local flag, height, pipe = t[1], t[2], t[3]
    if self[flag] or self.waterplaneheight < self[height] then return end
    self[flag] = true
    self:ChangePipeState(self[pipe], state)
    if aftershock then self:TriggerAftershock(2.0) end
end

local function run_triggers(self, list, state, aftershock)
    for _, t in ipairs(list) do fire_trigger(self, t, state, aftershock) end
end

-- ── risingPhase1's poll: one pass, since PipeControllerBig01's height check is dead ──

local rp1_steps = {
    [RP1.AwaitCrumble] = function(self)
        self.CrumbleBalconyRef:Activate(self, false)
        self.TG08BActorBarrier:Enable(false)
        self.afx, self.afy = self.waterplaneRef:GetPositionX(), self.waterplaneRef:GetPositionY()
        self.waterplaneHeight01 = self.waterplaneHeight01Ref:GetPositionZ()
        self.afz = self.waterplaneHeight01
        self.afxangle, self.afyangle, self.afzangle =
            self.waterplaneRef:GetAngleX(), self.waterplaneRef:GetAngleY(), self.waterplaneRef:GetAngleZ()
        self.CurrentTranslateTarget, self.currentTranslateSpeed = self.waterplaneHeight01Ref, self.afspeed1
        self.rp1Wait = 0.1
        return RP1.AwaitTranslate
    end,
    [RP1.AwaitTranslate] = function(self)
        self.waterplaneRef:TranslateTo(self.afx, self.afy, self.afz, self.afxangle, self.afyangle, self.afzangle,
            self.afspeed1, 0.0)
        return RP1.Polling
    end,
    [RP1.Polling] = function(self)
        self.waterplaneheight = self.waterplaneRef:GetPositionZ()
        -- sic: the source comments out B01's height check, so it always breaks on this first pass
        if not self.WaterSplashStartedB01 then
            self.WaterSplashStartedB01 = true
            self:ChangePipeState(self.PipeControllerBig01, "broken")
            self:TriggerAftershock(2.0)
        end
        fire_trigger(self, broken_triggers[5], "broken", true) -- S01
        fire_trigger(self, broken_triggers[6], "broken", true) -- S02
        fire_trigger(self, broken_triggers[7], "broken", true) -- S03
        if self.WaterSplashStartedB01 or self.waterplaneheight >= self.waterplaneHeight01 - 5.0 then
            self.phase1 = false
        end
        if not self.WaterIsDone and self.watersynctimer <= 0 then
            if self.WaterSplashStartedB01 and not self.PipeControllerBig01Done then
                self:TriggerWaterRiseMatch(self.PipeControllerBig01)
            end
            self.watersynctimer = 5.0
        end
        return RP1.Idle -- the loop's own tail wait(0.3) has nothing observable after it
    end,
}

-- ── risingPhase2's poll: translate, then hand off to WaterRise2 ──

local rp2_steps = {
    [RP2.AwaitTranslate] = function(self)
        self.waterplaneRef:TranslateTo(self.afx, self.afy, self.afz, self.afxangle, self.afyangle, self.afzangle,
            self.afspeed2, self.afmaxrotationspeed)
        self:StartWaterRisePhase2()
        return RP2.Idle
    end,
}

-- ── WaterRise2: breaks then submerges each pipe as the water passes it, every 0.3s ──

local function water_rise_pass(self)
    self.waterplaneheight = self.waterplaneRef:GetPositionZ()

    if not self.SidewallTorchDisabled and self.waterplaneheight > self.SidewallTorchHeight then
        self.SidewallTorchDisabled = true
        self.TG08bSmokeR:Enable(false)
        self.SidewallTorch:Disable(false)
        self.sidewallSmokePending, self.sidewallSmokeT = true, 2.0
    end
    if not self.StatueTorchDisabled and self.waterplaneheight > self.StatueTorchHeight then
        self.StatueTorchDisabled = true
        self.TG08bSmokeL:Enable(false)
        self.StatueTorch:Disable(false)
        self.statueSmokePending, self.statueSmokeT = true, 2.0
    end
    if not self.ExitRocksFinished and self.waterplaneheight >= self.ExitRocksHeight and self.TG08B:GetStage() == 50 then
        self.ExitRocksFinished = true
        self.TG08RockfallCollisionParent:Disable(false)
        self.ExitRocks:Activate(self, false)
        self.Sunlight:Enable(false)
        self.KarliahRef:EvaluatePackage()
        self.BrynjolfRef:EvaluatePackage()
    end
    if not self.WaterHeightFinished and self.waterplaneheight >= self.WaterFinishedHeight then
        self.WaterHeightFinished = true
        self.WaterIsDone = true
    end

    run_triggers(self, broken_triggers, "broken", true)
    run_triggers(self, submerged_triggers, "submerged", false)

    if not self.WaterIsDone and self.watersynctimer <= 0 then
        for i, bt in ipairs(broken_triggers) do
            if self[bt[1]] and not self[submerged_triggers[i][1]] then
                self:TriggerWaterRiseMatch(self[bt[3]])
            end
        end
        self.watersynctimer = 5.0
    end
end

local function advance_water_rise(self)
    if not self.waterRiseRunning or self.waterRiseWait > 0 then return end
    water_rise_pass(self)
    self.waterRiseWait = 0.3
    if self.WaterIsDone and self.ExitRocksFinished then
        self.waterRiseRunning = false
        self.KarliahRef:EvaluatePackage()
        self.BrynjolfRef:EvaluatePackage()
    end
end

return function(C)
    local V = C.__vars
    V.rp1Stage, V.rp1Wait = RP1.Idle, rt.timer(0.0)
    V.rp2Stage, V.rp2Wait = RP2.Idle, rt.timer(0.0)
    V.waterRiseRunning, V.waterRiseWait = rt.bool(false), rt.timer(0.0)
    V.sidewallSmokePending, V.sidewallSmokeT = rt.bool(false), rt.timer(0.0)
    V.statueSmokePending, V.statueSmokeT = rt.bool(false), rt.timer(0.0)
    -- GetCurrentRealTime() + 5.0 becomes a timer set to 5.0; shared by both polls, as the field was
    V["::watersynctimer_var"] = rt.timer(0.0)

    local RisingP1 = rt.state(C, "risingphase1")
    function RisingP1:OnBeginState()
        if self.rp1Stage ~= RP1.Idle then return end -- a run happens once
        self.phase1 = true
        self:CauseEarthquake1()
        self:setUpWaterHeights()
        self.EffectLinker1:Activate(self, false)
        self.rp1Wait, self.rp1Stage = 4.0, RP1.AwaitCrumble
    end

    local RisingP2 = rt.state(C, "risingphase2")
    function RisingP2:OnBeginState()
        if self.rp2Stage ~= RP2.Idle then return end -- a run happens once
        self:CauseEarthquake2()
        self.tg08NavcutParent:Disable(false)
        self.afz = self.waterplaneHeight02Ref:GetPositionZ()
        self.CurrentTranslateTarget, self.currentTranslateSpeed = self.waterplaneHeight02Ref, self.afspeed2
        self.TG08BActorBarrier:Disable(false)
        self.rp2Wait, self.rp2Stage = 6.0, RP2.AwaitTranslate
    end

    function C:WaterRise2()
        if self.waterRiseRunning then return end -- a run happens once
        self.waterRiseRunning, self.waterRiseWait = true, 0.0
        advance_water_rise(self) -- Papyrus checked its While condition at once
    end

    local split_tick = C.__fn.ontick
    function C:OnTick()
        split_tick(self)
        run(self, "rp1Stage", "rp1Wait", rp1_steps)
        run(self, "rp2Stage", "rp2Wait", rp2_steps)
        advance_water_rise(self)
        if self.sidewallSmokePending and self.sidewallSmokeT <= 0 then
            self.sidewallSmokePending = false
            self.TG08bSmokeR:Disable(true)
        end
        if self.statueSmokePending and self.statueSmokeT <= 0 then
            self.statueSmokePending = false
            self.TG08bSmokeL:Disable(true)
        end
    end
end
