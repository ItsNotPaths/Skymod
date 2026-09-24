-- pex: updatecaravan 01bbd6de
-- UpdateCaravan polled LeaderRef.Is3DLoaded() once a second before toggling a camp, once for
-- disabling and once for enabling. The three caravans (1, 2, 3) can run this independently, so the
-- wait is kept per caravan, in three slots, each an OnTick guard.
local rt = require('skymod.rt')

local S = rt.sequence("Idle", "WaitDisable", "WaitEnable")

return function(C)
    C.__vars.TickRate = rt.float(0.5)
    for n = 1, 3 do
        C.__vars["ucStage" .. n] = S.Idle
        C.__vars["ucLeader" .. n] = rt.form("Actor")
        C.__vars["ucEnable" .. n] = rt.bool(false)
    end

    local function setup(self, which)
        if which == 1 then
            self:SetGlobals(self.CaravanIsCampedA, self.CaravanLocationA)
            self.LeaderA:RegisterForSingleUpdateGameTime(self.CampTime)
        elseif which == 2 then
            self:SetGlobals(self.CaravanIsCampedB, self.CaravanLocationB)
            self.LeaderB:RegisterForSingleUpdateGameTime(self.CampTime)
        elseif which == 3 then
            self:SetGlobals(self.CaravanIsCampedC, self.CaravanLocationC)
            self.LeaderC:RegisterForSingleUpdateGameTime(self.CampTime)
        end
    end

    local function leader_alias(self, which)
        if which == 1 then return self.LeaderA end
        if which == 2 then return self.LeaderB end
        return self.LeaderC
    end

    local function reregister(self, which)
        leader_alias(self, which):GetReference():RegisterForSingleUpdateGameTime(self.CampTime)
    end

    function C:UpdateCaravan(WhichCaravan, CallingForm, LeaderRef, WeAreEnablingCamp, WeAreDisablingCamp)
        if self["ucStage" .. WhichCaravan] ~= S.Idle then return end -- a run happens once per caravan
        if WeAreDisablingCamp and LeaderRef:Is3DLoaded() then
            self["ucLeader" .. WhichCaravan] = LeaderRef
            self["ucEnable" .. WhichCaravan] = WeAreEnablingCamp
            self["ucStage" .. WhichCaravan] = S.WaitDisable
            return
        end
        if WeAreDisablingCamp then self:ToggleCamp(WhichCaravan, false) end
        setup(self, WhichCaravan)
        if WeAreEnablingCamp and LeaderRef:Is3DLoaded() then
            self["ucLeader" .. WhichCaravan] = LeaderRef
            self["ucStage" .. WhichCaravan] = S.WaitEnable
            return
        end
        if WeAreEnablingCamp then self:ToggleCamp(WhichCaravan, true) end
        reregister(self, WhichCaravan)
    end
    rt.params(C, "UpdateCaravan", { {"WhichCaravan"}, {"CallingForm"}, {"LeaderRef"}, {"WeAreEnablingCamp", false}, {"WeAreDisablingCamp", false} })

    local function tick_slot(self, n)
        local stage = self["ucStage" .. n]
        if stage == S.Idle then return end
        local leader = self["ucLeader" .. n]
        if leader:Is3DLoaded() then return end
        if stage == S.WaitDisable then
            self:ToggleCamp(n, false)
            setup(self, n)
            if self["ucEnable" .. n] then self:ToggleCamp(n, true) end
            reregister(self, n)
            self["ucStage" .. n] = S.Idle
        elseif stage == S.WaitEnable then
            self:ToggleCamp(n, true)
            reregister(self, n)
            self["ucStage" .. n] = S.Idle
        end
    end

    function C:OnTick()
        for n = 1, 3 do tick_slot(self, n) end
    end
end
