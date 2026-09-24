-- pex: endwait c61bc026 3a30f4d5
-- pex: restraindragon db5fe90e e0c546c6
-- pex: validateworldspace dc3b9f49 0736b80b
-- RestrainDragon polled GetFlyingState every 1 s before restraining; EndWait waited 2 s before its
-- calm-removal tail; ValidateWorldspace called EndWait and then ReleaseDragon right after, which
-- must now wait for EndWait's tail when EndWait actually started one (its own HasSpell guard
-- already drops a re-entrant call, exactly as Papyrus's guard did).
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.rdDragon = rt.form("Actor")
	C.__vars.rdActive = rt.bool(false)
	C.__vars.rdT = rt.timer(0.0)
	C.__vars.ewDragon = rt.form("Actor")
	C.__vars.ewT = rt.timer(0.0)
	C.__vars.vwReleaseOwed = rt.bool(false)

	function C:RestrainDragon(bRestrain)
		local dragon = self.dragonAlias:GetActorRef()
		if not (bRestrain and dragon:GetActorValue("variable01") ~= 99) then
			dragon:SetRestrained(false)
			return
		end
		self.rdDragon = dragon
		self.rdActive = true
		self.rdT = 0.0
	end

	function C:EndWait()
		local dragon = self.dragonAlias:GetActorRef()
		if not dragon:HasSpell(self.DLC2TameDragonNoFlyAbility) then return end -- not waiting: drop
		self.bAllowRestrain = false
		self:RestrainDragon(false)
		dragon:SetCrimeFaction(self.DLC2TameDragonFaction)
		dragon:RemoveSpell(self.DLC2TameDragonNoFlyAbility)
		dragon:RemoveSpell(self.DLC2abCalmDragon)
		if self.dragonAlias:GetActorRef() ~= dragon then return end
		if dragon:GetActorValue("variable01") == 0 then dragon:SetActorValue("variable01", 1) end
		dragon:EvaluatePackage()
		if not self.bMQ06DragonTaming then self:RegisterForSingleUpdateGameTime(self.fTameHours) end
		dragon:AddSpell(self.DLC2abCalmDragon)
		self.ewDragon = dragon
		self.ewT = 2.0 -- fresh wait: EndWait is an external entry point
	end

	function C:ValidateWorldspace()
		if self.DLC2TameDragonAllowedWorldspaces:HasForm(rt.static("Game", "GetPlayer"):GetWorldSpace()) then return end
		local was_waiting = self.ewDragon ~= rt.None
		self:EndWait()
		if not was_waiting and self.ewDragon ~= rt.None then
			self.vwReleaseOwed = true -- EndWait just started its tail; release once it settles
		else
			self:ReleaseDragon()
		end
	end

	function C:OnTick()
		if self.rdActive then
			if self.rdT > 0 then return end
			local dragon = self.rdDragon
			if dragon:GetFlyingState() > 0 and self.bAllowRestrain then
				self.rdT = self.rdT + 1.0
				return
			end
			self.rdActive = false
			if self.bAllowRestrain then
				dragon:SetRestrained(true)
				dragon:StopCombatAlarm()
				dragon:AddSpell(self.DLC2abCalmDragon)
			end
			dragon:SetPlayerTeammate(true, false)
		end
		if self.ewDragon and self.ewT <= 0 then
			local dragon = self.ewDragon
			self.ewDragon = rt.None
			dragon:RemoveSpell(self.DLC2abCalmDragon)
			if dragon:IsBeingRidden() then
				if self.iDragonsRiddenCount == 0 then self:RegisterForSingleUpdate(8.0) end
				if not dragon:IsInFaction(self.DLC2TamedDragonTrackingFaction) then
					dragon:AddToFaction(self.DLC2TamedDragonTrackingFaction)
					self.iDragonsRiddenCount = self.iDragonsRiddenCount + 1
					if self.iDragonsRiddenCount >= self.iDragonsRiddenAchievementCount then
						rt.static("Game", "AddAchievement", 73)
					end
				end
			end
			if self.vwReleaseOwed then
				self.vwReleaseOwed = false
				self:ReleaseDragon()
			end
		end
	end
end
