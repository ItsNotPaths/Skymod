-- pex: fire 5d5af4fd
-- pex: onload c7a28c74
-- pex: reload 024bcf1f
-- pex: setfiringstate 8535db7a
-- pex: setreloadingstate 4ff9c76d
-- pex: waitforcatapultloaded 0f071716
-- Four waits: OnLoad polled until the catapult's 3D loaded, SetReloadingState and SetFiringState
-- waited on its "reloaded" and "launch" events, and Fire stayed Busy through the volley's flight
-- (CatapultMonitor.RegisterCatapultHit). They are now facts that OnTick and OnAnimationEvent read.
local rt = require('skymod.rt')

return function(C)
	local split_tick = C.__fn.ontick -- this class's S6 split waits; an OnTick here must run them
	C.__vars.TickRate = rt.float(0.5)
	C.__vars.setupOwed = rt.bool(false) -- OnLoad ran before the catapult was loaded
	C.__vars.hitOwed = rt.bool(false)   -- a volley is in the air
	C.__vars.hitT = rt.timer(0.0)

	-- The rest of OnLoad, once the catapult is loaded.
	local function setup(self)
		self:RegisterForAnimationEvents()
		if self.currentCatapultState == self.STATE_FIRED then
			self:GetLinkedRef():PlayAnimation(self.ANIM_START_FIRED)
			self:DisableFireTriggers()
			self:EnableReloadTriggers()
		elseif self.currentCatapultState == self.STATE_LOADED then
			self:GetLinkedRef():PlayAnimation(self.ANIM_RELOAD)
			self:DisableReloadTriggers()
			self:EnableFireTriggers()
		end
	end

	function C:OnLoad()
		self.setupOwed = true
		self:OnTick()
	end

	function C:SetReloadingState()
		self.currentCatapultState = self.STATE_RELOADING
		self:DisableReloadTriggers()
		self:GetLinkedRef():PlayAnimation(self.ANIM_RELOAD)
	end

	function C:SetFiringState()
		self.currentCatapultState = self.STATE_FIRING
		self:DisableFireTriggers()
		self:GetLinkedRef():PlayAnimation(self.ANIM_FIRE)
	end

	function C:Reload(akActivator)
		if akActivator ~= self.PlayerRef then return end
		if self.CatapultMonitor:GetStage() ~= self.ALLOW_INTERACT_STAGE then return end
		if self.currentCatapultState ~= self.STATE_FIRED then return end
		if self.PlayerRef:GetItemCount(self.FlamingPot) > 0 then
			self.PlayerRef:RemoveItem(self.FlamingPot, 1)
			self:GotoState("Busy") -- until SetLoadedState runs on the "reloaded" event
			self:SetReloadingState()
		else
			self.noPotErrorMessage:Show()
			if not self.CatapultMonitor:IsObjectiveDisplayed(self.noPotObjective) or self.CatapultMonitor:IsObjectiveCompleted(self.noPotObjective) then
				self.CatapultMonitor:SetObjectiveCompleted(self.noPotObjective, false)
				self.CatapultMonitor:SetObjectiveDisplayed(self.noPotObjective, true)
			end
		end
	end

	function C:Fire(akActivator)
		if akActivator ~= self.PlayerRef then return end
		if self.CatapultMonitor:GetStage() ~= self.ALLOW_INTERACT_STAGE then return end
		if self.currentCatapultState ~= self.STATE_LOADED then return end
		self:GotoState("Busy") -- until the volley's hit is counted
		self:SetFiringState()
	end

	function C:OnAnimationEvent(akSource, asEventName)
		local catapult = self:GetLinkedRef()
		if akSource ~= catapult then return end
		if asEventName == self.ANIM_EVENT_RELOADED and self.currentCatapultState == self.STATE_RELOADING then
			self:SetLoadedState()
			self:GotoState("")
		elseif asEventName == self.ANIM_EVENT_LAUNCH and self:GetState() == "Busy" and not self.hitOwed then
			if self.currentCatapultState ~= self.STATE_FIRING then return self:GotoState("") end -- disabled mid-fire
			self.CatapultVolley:Cast(catapult, catapult:GetLinkedRef())
			self:SetFiredState()
			self.hitOwed = true
			self.hitT = self.CatapultMonitor.TIME_TO_HIT
		end
	end

	function C:OnTick()
		if split_tick then split_tick(self) end
		if self.setupOwed and self:GetLinkedRef():Is3DLoaded() then
			self.setupOwed = false
			setup(self)
		end
		if self.hitOwed and self.hitT <= 0 then
			self.hitOwed = false
			self.CatapultMonitor:RegisterCatapultHit()
			self:GotoState("")
		end
	end
end
