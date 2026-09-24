-- pex: deadandwaiting.onbeginstate 0aba135a
-- LE without Dragonborn: deadAndWaiting polled the player distance each second, then
-- MQKillDragonScript.DeathSequence waited through the death here, one run per dragon: a stage and a
-- stopwatch. The quest holds the art and the rewards; the soul always goes to the player.
local rt = require('skymod.rt')

local Death = rt.sequence("Idle", "Started", "Equipped", "Skinned", "BitsLite", "Bits", "Blood",
    "Magic", "BitsOff", "Unequipped", "PowerFx", "Ghosted", "Smoking", "Rewarded")

local function player() return rt.static("Game", "GetPlayer") end
local function quest(self) return rt.cast(self.MQkillDragon, "mqkilldragonscript") end

-- true when the run sits at `stage` and `secs` have passed; moves it to `next` first
local function due(self, stage, secs, next)
    if self.death ~= stage or self.deathClock < secs then return false end
    self.death = next
    self.deathClock = self.deathClock - secs
    return true
end

return function(C)
    C.__vars.TickRate = rt.float(0.1)
    C.__vars.death = Death.Idle
    C.__vars.deathClock = rt.stopwatch(0.0)
    C.__vars.fireSound = rt.int(0)
    C.__vars.smolderSound = rt.int(0)

    local Waiting = rt.state(C, "deadandwaiting")
    local Dead = rt.state(C, "deaddisintegrated")

    function Waiting:OnBeginState()
        self:OnTick()
    end

    function Waiting:OnTick()
        if self:GetDistance(self.player) > self.deathFXrange then return end
        self:GotoState("deaddisintegrated")
        quest(self):DeathSequence(self)
    end

    function C:BeginDeathSequence(q)
        if self.death ~= Death.Idle then return end
        self.death, self.deathClock = Death.Started, 0.0
        self:AddItem(q.DragonUnderskin, 1, false)
        q.FXDragonDeathLHandBits:Play(self, 12.0, rt.None)
        q.FXDragonDeathRHandBits:Play(self, 12.0, rt.None)
    end

    function Dead:OnTick()
        if self.death == Death.Idle then return end
        local q, p = quest(self), player()

        if due(self, Death.Started, 0.2, Death.Equipped) then
            self:EquipItem(q.DragonUnderskin, false, false)
        end
        if due(self, Death.Equipped, 0.5, Death.Skinned) then
            self:PlaySubGraphAnimation("UnderSkinFadeOut")
            q.WI:PlayerIsCurrentlyAbsorbingPower(self)
            q.bIsAbsorbing = true
            q.DragonHolesFXS:Play(self, -1.0)
            self:PlaySubGraphAnimation("SkinFadeOut")
            q.DragonPowerAbsorbISM:Apply(1.0)
            self.fireSound = q.NPCDragonDeathSequenceFireLPM:Play(self)
        end
        if due(self, Death.Skinned, 1.0, Death.BitsLite) then
            q.DragonHolesBitsLiteFXS:Play(self, -1.0)
        end
        if due(self, Death.BitsLite, 1.0, Death.Bits) then
            q.DragonHolesBitsFXS:Play(self, -1.0)
        end
        if due(self, Death.Bits, 3.75, Death.Blood) then
            self:PlaySubGraphAnimation("BloodFade")
            q.FXDragonDeathRHandFire:Play(self, 12.0, rt.None)
            q.FXDragonDeathLHandFire:Play(self, 12.0, rt.None)
        end
        if due(self, Death.Blood, 1.0, Death.Magic) then
            q.DragonHolesMagicFXS:Play(self, -1.0)
            q.DragonHolesMagicFXS:Stop(self)
        end
        if due(self, Death.Magic, 0.25, Death.BitsOff) then
            q.DragonHolesBitsFXS:Stop(self)
            q.DragonHolesBitsLiteFXS:Stop(self)
            q.DragonHolesFXS:Stop(self)
        end
        if due(self, Death.BitsOff, 1.8, Death.Unequipped) then
            for _, armor in ipairs({ q.DragonBloodHeadFXArmor, q.DragonBloodTailFXArmor, q.DragonBloodWingLFXArmor, q.DragonBloodWingRFXArmor }) do
                if self:IsEquipped(armor) then self:UnequipItem(armor, false, false) end
            end
            q.DragonAbsorbEffect:Play(self, 8.0, p)
            q.DragonAbsorbManEffect:Play(p, 8.0, self)
            q.NPCDragonDeathSequenceWind:Play(self)
            q.NPCDragonDeathSequenceExplosion:Play(self)
        end
        if due(self, Death.Unequipped, 0.1, Death.PowerFx) then
            q.DragonPowerAbsorbFXS:Play(p, -1.0)
        end
        if due(self, Death.PowerFx, 2.0, Death.Ghosted) then
            self:SetGhost(true)
            self:ClearExtraArrows()
        end
        if due(self, Death.Ghosted, 4.0, Death.Smoking) then
            q.DragonPowerAbsorbFXS:Stop(p)
            rt.static("Sound", "StopInstance", self.fireSound)
            q.DragonHolesSmokeFXS:Play(self, -1.0)
            self.smolderSound = q.NPCDragonDeathSequenceSmolderLPM:Play(self)
        end
        if due(self, Death.Smoking, 4.0, Death.Rewarded) then
            q.DragonsAbsorbed:SetValue(q.DragonsAbsorbed:GetValue() + 1.0)
            p:ModActorValue("dragonsouls", q.VoicePointsReward + 0.0)
            if not q.MQ104:GetStageDone(90) and q.MQ104:IsRunning() then q.MQ104:SetStage(90) end
            q.DragonHolesSmokeFXS:Stop(self)
            q.DragonAbsorbEffect:Stop(self)
            q.DragonAbsorbManEffect:Stop(p)
        end
        if due(self, Death.Rewarded, 4.0, Death.Idle) then
            rt.static("Sound", "StopInstance", self.smolderSound)
            self:AddToFaction(q.MQKillDragonFaction)
            q.DragonHolesLightFXS:Stop(self)
            q.WI:PlayerIsDoneAbsorbingPower(self)
            self:EquipItem(q.SkinDragonHider, true, false)
            q.bIsAbsorbing = false
        end
    end
end
