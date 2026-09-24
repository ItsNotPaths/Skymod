-- pex: ready.onactivate b4455c41
-- pex: scanforrecipes 562664b6
-- ScanForRecipes finds its recipe with a spin loop (no wait, kept as a plain call), then waited
-- 0.33 s before spawning the result. Ready.OnActivate waited 0.1 s between the sigil scan and the
-- normal one. Both waits are now stages of one busy-state OnTick.
local rt = require('skymod.rt')

local S = rt.sequence("SigilFind", "SigilSpawnWait", "PostSigil", "NormalFind", "NormalSpawnWait", "Finish")

return function(C)
    C.__vars.stage = S.SigilFind
    C.__vars.t = rt.timer(0.0)
    C.__vars.foundIdx = rt.int(0)
    C.__vars.daedricCrafted = rt.bool(false)
    C.__vars.TickRate = rt.float(0.05)

    -- the loop over Recipes has no wait in it: it runs to completion in one call. -1 is "not found"
    -- (foundIdx is an int field; it cannot hold Lua nil).
    local function find_recipe(self, recipes)
        local t = recipes:GetSize()
        for i = 0, t - 1 do
            local cur = recipes:GetAt(i)
            if cur and self:ScanSubList(cur) then
                self:RemoveIngredients(cur)
                return i
            end
        end
        return -1
    end

    local function spawn_start(self)
        rt.static("Debug", "Trace", "atronach forge: combine found, 0.33s spawn wait")
        self.SummonFXPoint:PlaceAtMe(self.SummonFX, 1, false, false) -- the pex drops the animation call
    end

    local function spawn_finish(self, results, i)
        rt.static("Debug", "Trace", "atronach forge: spawning result")
        local newRef = self.CreatePoint:PlaceAtMe(results:GetAt(i), 1, false, false)
        if self.LastSummonedObject then
            local last = rt.cast(self.LastSummonedObject, "actor")
            if last:IsDead() then
                self.LastSummonedObject:RemoveAllItems(self.DropBox, false, true)
                self.LastSummonedObject:Disable(false)
                self.LastSummonedObject:Delete()
            end
        end
        self.LastSummonedObject = newRef
        local newActor = rt.cast(newRef, "actor")
        if newActor ~= rt.cast(rt.None, "actor") then newActor:StartCombat(rt.static("Game", "GetPlayer")) end
    end

    local Ready = rt.state(C, "ready")
    function Ready:OnActivate(actronaut)
        self:GotoState("busy")
        self.stage = S.SigilFind
        self.t = 0.0 -- t free-runs negative while idle in "ready"; a fresh run must reset it
        self:OnTick()
    end

    local Busy = rt.state(C, "busy")
    function Busy:OnTick()
        if self.t > 0 then return end
        if self.stage == S.SigilFind then
            if self.SigilStoneInstalled then
                self.foundIdx = find_recipe(self, self.SigilRecipeList)
                if self.foundIdx >= 0 then
                    spawn_start(self)
                    self.t = self.t + 0.33
                    self.stage = S.SigilSpawnWait
                else
                    self.daedricCrafted = false
                    self.t = self.t + 0.1
                    self.stage = S.PostSigil
                end
            else
                self.stage = S.NormalFind
            end
            return
        end
        if self.stage == S.SigilSpawnWait then
            spawn_finish(self, self.SigilResultList, self.foundIdx)
            self.daedricCrafted = true
            self.t = self.t + 0.1
            self.stage = S.PostSigil
            return
        end
        if self.stage == S.PostSigil then
            if not self.SigilStoneInstalled or not self.daedricCrafted then
                self.stage = S.NormalFind
            else
                self.stage = S.Finish
            end
        end
        if self.stage == S.NormalFind then
            self.foundIdx = find_recipe(self, self.RecipeList)
            if self.foundIdx >= 0 then
                spawn_start(self)
                self.t = self.t + 0.33
                self.stage = S.NormalSpawnWait
                return
            end
            self.stage = S.Finish
        end
        if self.stage == S.NormalSpawnWait then
            spawn_finish(self, self.ResultList, self.foundIdx)
            self.stage = S.Finish
        end
        if self.stage == S.Finish then
            self:GotoState("ready")
        end
    end
end
