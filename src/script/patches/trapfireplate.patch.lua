-- pex: oncellattach b5b46a27
-- pex: removemyhazard 845caeaa
-- removeMyHazard captured the hazard ref, waited 1s, then disabled and deleted it. OnCellAttach's
-- own GotoState ran only once that wait was over, so it now waits on removeMyHazard's stage too.
-- Every other caller of removeMyHazard already calls it last (nothing follows), so they are
-- unchanged: they call the same name, which this patch now makes start-and-return.
local rt = require('skymod.rt')

local Remove = rt.sequence("Idle", "Waiting")
local Attach = rt.sequence("Idle", "AwaitRemove")

local function run(self, stage, wait, steps)
    while steps[self[stage]] and (not wait or self[wait] <= 0) do
        local nxt = steps[self[stage]](self)
        if not nxt then return end
        self[stage] = nxt
    end
end

local remove_steps = {
    [Remove.Waiting] = function(self)
        local ref = self.removeTarget
        if ref then
            ref:Disable(false)
            ref:Delete()
        end
        return Remove.Idle
    end,
}

local function finish_attach(self)
    if self.objectsInTrigger == 0 then
        self:GotoState("Inactive")
        self:PlayAnimation("Up")
    else
        self:GotoState("Active")
    end
end

local attach_steps = {
    [Attach.AwaitRemove] = function(self)
        if self.removeStage ~= Remove.Idle then return nil end
        finish_attach(self)
        return Attach.Idle
    end,
}

return function(C)
    local V = C.__vars
    V.removeStage, V.removeWait = Remove.Idle, rt.timer(0.0)
    V.removeTarget = rt.form("ObjectReference")
    V.attachStage = Attach.Idle

    function C:removeMyHazard()
        if self.removeStage ~= Remove.Idle then return end -- one already runs
        self.removeTarget = self.myHazardRef
        self.removeWait, self.removeStage = 1.0, Remove.Waiting
    end

    function C:OnCellAttach()
        if self.attachStage ~= Attach.Idle then return end -- a run happens once
        self.objectsInTrigger = self:GetTriggerObjectCount()
        if not self.weaponResolved then self:ResolveLeveledHazard() end
        if self.myHazardRef then
            self:removeMyHazard()
            self.attachStage = Attach.AwaitRemove
        else
            finish_attach(self)
        end
    end

    function C:OnTick()
        run(self, "removeStage", "removeWait", remove_steps)
        run(self, "attachStage", nil, attach_steps)
    end
end
