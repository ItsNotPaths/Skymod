-- pex: fragment_25 4d0dceb3
-- Fragment_25 called kmyQuest.CleanUpTimeTravelEffects(), which blocked for 4s, then ran the rest
-- (enable/disable aliases, release the weather override again, move the player, start the present
-- day scene). CleanUpTimeTravelEffects is now start-and-return, so the rest waits for it to
-- settle (its "effects" field back to Idle) before running, in the same order as Papyrus.
local rt = require('skymod.rt')

return function(C)
	C.__vars.f25Pending = rt.bool(false)
	C.__vars.TickRate = rt.float(0.2)

	local function kmyQuest(self) return rt.cast(self.form, "mq206script") end

	local function finish(self)
		local q = kmyQuest(self)
		local player = rt.static("Game", "GetPlayer")
		player:SetGhost(false)
		rt.static("Game", "EnablePlayerControls")
		self.Alias_StatePresent:GetRef():Enable(false)
		self.Alias_Paarthurnax:GetRef():Enable(false)
		self.Alias_StatePast:GetRef():Disable(false)
		rt.static("Game", "ClearTempEffects")
		self.Alias_Dragon1:TryToDisable()
		self.Alias_Felldir:GetRef():Disable(false)
		self.Alias_Hakon:GetRef():Disable(false)
		self.Alias_Gormlaith:GetRef():Disable(false)
		self.Alias_SceneAttackDragon1:GetRef():Disable(false)
		self.Alias_SceneAttackDragon2:GetRef():Disable(false)
		self.Alias_SceneAttackDragon3:GetRef():Disable(false)
		rt.static("Weather", "ReleaseOverride")
		self.DisableObjectTrigger:DisableObjects(false)
		self.DisableObjectTrigger:ClearList()
		player:MoveTo(self.Alias_TimeWound:GetRef(), 0.0, 0.0, 0.0, true)
		rt.static("Game", "SetInChargen", false, false, false)
		self:SetObjectiveCompleted(20, true)
		self:SetObjectiveDisplayed(30, true, false)
		local alduin = self.Alias_Alduin:GetActorRef()
		alduin:SetActorValue("Aggression", 0)
		alduin:Enable(false)
		alduin:SetForcedLandingMarker(self.Alias_AlduinLandingMarker:GetRef())
		self.Alias_Paarthurnax:GetActorRef():SetForcedLandingMarker(self.PaarthurnaxLandingMarker)
		self.AlduinFaction:SetEnemy(self.PlayerFaction, false, false)
		self.PresentDayScene:Start()
		rt.static("Game", "RequestAutoSave")
		self.dunDragonMoundQST:SetStage(100)
	end

	function C:Fragment_25()
		kmyQuest(self):CleanUpTimeTravelEffects()
		self.f25Pending = true
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if not self.f25Pending then return end
		if kmyQuest(self).effects.name ~= "Idle" then return end
		self.f25Pending = false
		finish(self)
	end
end
