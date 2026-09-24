-- pex: catchfail 5d3ea27f
-- pex: catchsuccess c6ec7a08
-- pex: fish 6c125643
-- pex: onupdate f68fa257
-- pex: playhookedfishanimation d168d39f
-- pex: playhookedobjectanimation cc1a5a3a
-- pex: reelline 36d10f10
-- pex: setupcameraandposition 6f7cde59
-- pex: showfanfarescreenandaddcaughtitem 3233407b
-- The fishing system waited in seven functions: the camera set-up and cast, the hooked tug, the
-- catch result and the fanfare, and OnUpdate waited for the input lock. Each wait is now a stage
-- of its own run, stepped by OnTick. A caller waits for its callee's run to be Idle, and the lock
-- (handlingInputOrUpdate) is released when the run its holder waits for (`handling`) ends.
local rt = require('skymod.rt')

return function(C)
	C.Camera = rt.sequence("Idle", "Drawing", "FadingOut", "Sheathing", "LoadingRod", "FadingIn")
	C.Cast = rt.sequence("Idle", "Positioning", "Casting")
	C.Hook = rt.sequence("Idle", "Beat", "Rumbling")
	C.Resolve = rt.sequence("Idle", "Failing", "Catching", "Showing")
	C.Fanfare = rt.sequence("Idle", "Loading", "Showing")
	C.Handling = rt.sequence("Idle", "Hooking", "Resolving")
	local CA, CS, HK, RS, FF, HD = C.Camera, C.Cast, C.Hook, C.Resolve, C.Fanfare, C.Handling
	local v = C.__vars
	v.TickRate = rt.float(0.05) -- divides every wait
	v.camera, v.camera_t = CA.Idle, rt.timer(0.0)
	v.continueFishing = rt.bool(false) -- the player asked to fish again from the same spot
	v.hasWeaponDrawn = rt.bool(false)
	v.resetView = rt.bool(false)       -- the view fades to black and the player is moved
	v.cast, v.cast_t = CS.Idle, rt.timer(0.0)
	v.hook, v.hook_t = HK.Idle, rt.timer(0.0)
	v.resolve, v.resolve_t = RS.Idle, rt.timer(0.0)
	v.reduceOwed = rt.bool(false)      -- the spot still owes one fish for a failed catch
	v.fanfare, v.fanfare_t = FF.Idle, rt.timer(0.0)
	v.catchRef, v.fanfareLight = rt.form("ObjectReference"), rt.form("ObjectReference")
	v.handling = HD.Idle
	v.updateOwed = rt.bool(false)      -- an update arrived and is not handled yet
	v.update_t = rt.timer(0.0)
	rt.params(C, "Fish", { { "abContinueFishing", false } })
	rt.params(C, "SetupCameraAndPosition", { { "abContinueFishing", false } })
	rt.params(C, "CatchFail", { { "abFastExit" }, { "abReduceFishPopulation", false } })
	local split_tick = C.__fn.ontick

	local function game(fn, ...) return rt.static("Game", fn, ...) end
	local function marker(self) return self.currentFishingSupplies:GetFishingMarker() end
	local function catch_type(self) return self.nextCatchData:getCatchType() end
	local function is_fish(self) return self:IsFishCatchType(catch_type(self)) end

	-- SetupCameraAndPosition

	function C:SetupCameraAndPosition(abContinueFishing)
		if self.camera ~= CA.Idle then return end
		self.startedInFirstPerson = self.PlayerRef:GetAnimationVariableBool("IsFirstPerson")
		self.startedWithTorch = self.PlayerRef:GetEquippedItemType(0) == 11 -- left hand, torch
		self.continueFishing = abContinueFishing
		self.camera = CA.Drawing
		self.camera_t = 0.0
		self:OnTick()
	end

	local function player_unmoved(self)
		local p, m = self.PlayerRef, marker(self)
		local floor = function(x) return rt.static("Math", "Floor", x) end
		return p:GetAngleX() == 0.0 and p:GetAngleZ() == m:GetAngleZ()
			and floor(p:GetPositionX()) == floor(m:GetPositionX())
			and floor(p:GetPositionY()) == floor(m:GetPositionY())
			and self.startedInFirstPerson and not self.hasWeaponDrawn
	end

	local function drawn(self)
		self.hasWeaponDrawn = self.PlayerRef:IsWeaponDrawn()
		game("DisablePlayerControls", { abMovement = true, abFighting = true, abCamSwitch = true, abLooking = true,
			abSneaking = true, abMenu = true, abActivate = false, abJournalTabs = true })
		self.resetView = not (self.continueFishing and player_unmoved(self))
		if not self.resetView then
			self.camera = CA.LoadingRod
			self.camera_t = self.DURATION_RODLOADTIME
			return
		end
		self.camera = CA.FadingOut
		self.camera_t = self.DURATION_FADETOBLACKCROSSFADE - 0.1
		self.ccBGSSSE001_FadeToBlackImod:ApplyCrossFade(self.DURATION_FADETOBLACKCROSSFADE)
	end

	local function sheathed(self)
		self.camera = CA.LoadingRod
		self.camera_t = self.camera_t + self.DURATION_RODLOADTIME
		if self.startedWithTorch then self.PlayerRef:UnequipItem{ akItem = self.Torch01, abSilent = true } end
		if not self.startedInFirstPerson then game("ForceFirstPerson") end
		self:MovePlayerToFishingMarker()
	end

	local function blacked_out(self)
		self.ccBGSSSE001_FadeToBlackImod:PopTo(self.ccBGSSSE001_FadeToBlackHoldImod)
		self.ccBGSSSE001_FishingFollowerIdleQuest:Start()
		if not self.hasWeaponDrawn then return sheathed(self) end
		self.camera = CA.Sheathing
		self.camera_t = self.camera_t + self.DURATION_SHEATHEWEAPON
	end

	local function rod_loaded(self)
		local m = marker(self)
		if self.resetView then
			self.camera = CA.FadingIn
			self.camera_t = self.camera_t + self.DURATION_FADETOBLACKCROSSFADE - 0.1
		else
			self.camera = CA.Idle
		end
		self.fishingRodActivator:TranslateToRef(m, 2000.0, 2000.0)
		self.MoveDetectRef:IgnoreTriggerEvents()
		self.ccBGSSSE001_NavBlockerRef:MoveTo{ akTarget = m, abMatchRotation = true }
		self.ReelLineRef:MoveTo{ akTarget = m, abMatchRotation = true }
		self.MoveDetectRef:MoveTo{ akTarget = m, abMatchRotation = true }
		self.MoveDetectRef:IgnoreTriggerEvents(false)
		if self.resetView then self.ccBGSSSE001_FadeToBlackHoldImod:PopTo(self.ccBGSSSE001_FadeToBlackBackImod) end
	end

	local function camera_tick(self)
		if self.camera == CA.Idle or self.camera_t > 0 then return end
		if self.camera == CA.Drawing then
			if self:IsPlayerDrawingWeapon() then
				self.camera_t = 0.25
				return
			end
			return drawn(self)
		end
		if self.camera == CA.FadingOut then return blacked_out(self) end
		if self.camera == CA.Sheathing then return sheathed(self) end
		if self.camera == CA.LoadingRod then return rod_loaded(self) end
		self.camera = CA.Idle
	end

	-- Fish

	function C:Fish(abContinueFishing)
		if self.cast ~= CS.Idle then return end
		self.currentFishingSupplies:UpdateFish()
		self.DialogueQuest:StartUpdating()
		self.fishingRodActivator = self:PlaceFishingRodActivator(self.currentFishingRodType)
		self:FishingDebug("Placing fishing rod activator " .. tostring(self.fishingRodActivator))
		self.cast = CS.Positioning
		self:SetupCameraAndPosition(abContinueFishing)
		self:OnTick()
	end

	local function cast_tick(self)
		if self.cast == CS.Idle or self.cast_t > 0 then return end
		if self.cast == CS.Positioning then
			if self.camera ~= CA.Idle then return end
			self.cast = CS.Casting
			self.cast_t = self.DURATION_CAST
			self:SetVisualPopulation()
			self:ShowFishingTutorial()
			self:ShowReelLinePrompt()
			self.nextCatchData = self:GetNextCatchData()
			self:FishingDebug("Catch data for next catch: " .. tostring(self.nextCatchData))
			self:PlayCastAnimation()
			return
		end
		self.cast = CS.Idle
		self:PlayVisualPopulationAnimation()
		self:RegisterForNextUpdate(self.UPDATETYPE_START)
		self.currentSystemState = self.SYSTEMSTATE_FISHING
	end

	-- PlayHookedFishAnimation, PlayHookedObjectAnimation: the kind follows the catch type.

	local function start_hook(self, tug)
		if self.hook ~= HK.Idle then return end
		self.hook = HK.Beat
		self.hook_t = self.DURATION_HOOKED_ANIM_WAIT
		self.fishingRodActivator:SetAnimationVariableFloat(self.LINETUG_ANIMVAR, tug)
		self.fishingRodActivator:PlayAnimation(self.NIBBLE_ANIM)
	end

	function C:PlayHookedFishAnimation() start_hook(self, self.LINETUG_TYPE_TUGFISH) end
	function C:PlayHookedObjectAnimation() start_hook(self, self.LINETUG_TYPE_TUGOBJECT) end

	-- the rumble after the beat: strengths and the constant rumble that follows, or none
	local function rumble(self)
		if not is_fish(self) then
			return self.RUMBLE_STRENGTH_HOOKEDOBJECT_LEFT, self.RUMBLE_STRENGTH_HOOKEDOBJECT_RIGHT,
				self.RUMBLE_STRENGTH_HOOKED_LEFTCONSTANT, self.RUMBLE_STRENGTH_HOOKED_RIGHTCONSTANT
		end
		local ct = catch_type(self)
		if ct == self.ccBGSSSE001_CatchTypeSmallFish:GetValueInt() then
			return self.RUMBLE_STRENGTH_HOOKEDSMALLFISH_LEFT, self.RUMBLE_STRENGTH_HOOKEDSMALLFISH_RIGHT,
				self.RUMBLE_STRENGTH_HOOKED_LEFTCONSTANT, self.RUMBLE_STRENGTH_HOOKED_RIGHTCONSTANT
		elseif ct == self.ccBGSSSE001_CatchTypeLargeFish:GetValueInt() then
			return self.RUMBLE_STRENGTH_HOOKEDLARGEFISH_LEFT, self.RUMBLE_STRENGTH_HOOKEDLARGEFISH_RIGHT,
				self.RUMBLE_STRENGTH_HOOKEDLARGEFISH_LEFTCONSTANT, self.RUMBLE_STRENGTH_HOOKEDLARGEFISH_RIGHTCONSTANT
		end
	end

	local function hook_tick(self)
		if self.hook == HK.Idle or self.hook_t > 0 then return end
		local left, right, left_const, right_const = rumble(self)
		if self.hook == HK.Beat then
			self.fishingRodActivator:PlayAnimation(is_fish(self) and self.LINETUG_FISH_ANIM or self.LINETUG_OBJECT_ANIM)
			if not left then
				self.hook = HK.Idle
				return
			end
			self.hook = HK.Rumbling
			self.hook_t = self.hook_t + self.RUMBLE_DURATION_HOOKED - 0.1
			game("ShakeController", left, right, self.RUMBLE_DURATION_HOOKED)
			return
		end
		self.hook = HK.Idle
		game("ShakeController", left_const, right_const, self.RUMBLE_DURATION_HOOKEDCONSTANT)
	end

	-- CatchFail, CatchSuccess, ShowFanfareScreenAndAddCaughtItem

	function C:CatchFail(abFastExit, abReduceFishPopulation)
		if self.resolve ~= RS.Idle then return end
		self:FishingDebug("Catch failure, exit!")
		self.resolve = RS.Failing
		self.reduceOwed = abReduceFishPopulation
		if abFastExit then
			self.resolve_t = self.DURATION_FASTEXIT
			self:PlayFastExitAnimation()
		else
			self.resolve_t = self.DURATION_CATCH
			self:PlayCatchFailureAnimation()
		end
	end

	function C:CatchSuccess()
		if self.resolve ~= RS.Idle then return end
		self:FishingDebug("Catch success!")
		self.resolve = RS.Catching
		self.resolve_t = self.DURATION_CATCH
		self:UnregisterForUpdate()
		self.ccBGSSSE001_CatchSuccessSM:Play(self.PlayerRef)
		self:PlayCatchSuccessAnimation()
	end

	local function landed(self)
		local data, supplies = self.nextCatchData, self.currentFishingSupplies
		self.resolve = RS.Showing
		self.ccBGSSSE001_ITMFishUpSM:Play(self.PlayerRef)
		if self.lastCatchWasRare then self.ccBGSSSE001_RareCatchSM:Play(self.PlayerRef) end
		if data.isOneTimeCatch then self.ccBGSSSE001_OneTimeCaughtList:AddForm(data) end
		if is_fish(self) then
			self:TryToStartQuestAfterFirstCatch()
			supplies:UpdateFishCatchSuccess()
			supplies:ReduceFishPopulation(1)
		end
		self:ShowFanfareScreenAndAddCaughtItem(data:getCaughtObject())
	end

	local function shown(self)
		local supplies = self.currentFishingSupplies
		self.resolve = RS.Idle
		if self.isQuestItemCatch and supplies.myQuestStageToSet ~= -1 then
			supplies.myQuest:SetStage(supplies.myQuestStageToSet)
		end
		local listener = self.RadiantFishEventListener
		if listener and listener.FishingSpot:GetRef() == supplies then
			listener:CatchEvent(self.nextCatchData:getCaughtObject(), catch_type(self))
		end
		self:CleanUp()
	end

	local function resolve_tick(self)
		if self.resolve == RS.Idle or self.resolve_t > 0 then return end
		if self.resolve == RS.Catching then return landed(self) end
		if self.resolve == RS.Showing then
			if self.fanfare == FF.Idle then shown(self) end
			return
		end
		self.resolve = RS.Idle
		if self.reduceOwed then
			self.reduceOwed = false
			self.currentFishingSupplies:ReduceFishPopulation(1)
		end
		self:CleanUp()
	end

	function C:ShowFanfareScreenAndAddCaughtItem(akCaughtObject)
		if self.fanfare ~= FF.Idle then return end
		self.fanfare = FF.Loading
		self.fanfare_t = 0.0
		-- we don't want the player taking the fanfare object
		game("DisablePlayerControls", { abMovement = true, abFighting = true, abCamSwitch = true, abLooking = true,
			abSneaking = true, abMenu = true, abActivate = true, abJournalTabs = true })
		self.ccBGSSSE001_CatchSuccessDOF:Apply()
		self.catchRef = self.currentFishingSupplies:PlaceAtMe(akCaughtObject)
		self:OnTick()
	end

	local function fanfare_loaded(self)
		local catch, supplies, m = self.catchRef, self.currentFishingSupplies, marker(self)
		self.fanfare = FF.Showing
		self.fanfare_t = self.fanfare_t + self.DURATION_SUCCESSVIEW
		catch:SetMotionType(catch.Motion_Keyframed)
		catch:Disable()
		self.fanfareLight = supplies:PlaceAtMe{ akFormToPlace = self.ccBGSSSE001_CatchSuccessLight, abInitiallyDisabled = true }
		self.fanfareLight:MoveToNode(m, "LightNode")
		catch:MoveToNode(m, self.nextCatchData.successNodeName)
		self.fanfareLight:EnableNoWait(false)
		catch:EnableNoWait(true)
		self.PlayerRef:AddItem(catch:GetBaseObject())
	end

	local function fanfare_tick(self)
		if self.fanfare == FF.Idle or self.fanfare_t > 0 then return end
		if self.fanfare == FF.Loading then
			if not self.catchRef:Is3DLoaded() then
				self.fanfare_t = 0.2
				return
			end
			return fanfare_loaded(self)
		end
		self.fanfare = FF.Idle
		self.fanfareLight:DisableNoWait()
		self.catchRef:DisableNoWait()
		self.fanfareLight:Delete()
		self.catchRef:Delete()
		self.fanfareLight, self.catchRef = rt.None, rt.None
		self.ccBGSSSE001_CatchSuccessDOF:Remove()
		if self.currentSystemState ~= self.SYSTEMSTATE_CATCH_RESOLVE then
			game("EnablePlayerControls") -- failsafe: we shouldn't have been able to get here
		end
	end

	-- OnUpdate and ReelLine hold the input lock until the run they started ends.

	local function release(self)
		self.handling = HD.Idle
		self.handlingInputOrUpdate = false
	end

	local function fail_holding(self, fast, reduce)
		self.handling = HD.Resolving
		self:CatchFail(fast, reduce)
	end

	local function sequence_update(self)
		self:FishingDebug("    ...sequence")
		if not self.nextCatchData then
			self:FishingDebug("    ...did not have catch data. Abort.")
			return fail_holding(self, true, false)
		end
		if not is_fish(self) then
			self.currentSystemState = self.SYSTEMSTATE_HOOKED
			self:ShowCatchPrompt()
			self.handling = HD.Hooking
			return self:PlayHookedObjectAnimation()
		end
		local seq = self.nextCatchData:getCatchSequence()
		if not seq then
			self:FishingDebug("    ...failed to obtain a valid catch sequence. Abort.")
			return fail_holding(self, true, false)
		end
		local i = self.currentCatchSequenceIndex
		if i > rt.alen(seq) - 1 or rt.aget(seq, i) == 0.0 then
			self.currentSystemState = self.SYSTEMSTATE_HOOKED
			self.handling = HD.Hooking
			return self:PlayHookedFishAnimation()
		end
		self.currentSystemState = self.SYSTEMSTATE_NIBBLE
		self:PlayNibbleAnimation()
		self:RegisterForNextUpdate(self.UPDATETYPE_SEQUENCE)
		self.currentCatchSequenceIndex = i + 1
	end

	local function handle_update(self)
		self.updateOwed = false
		self.handlingInputOrUpdate = true
		self:FishingDebug("Got update...")
		if not self:IsValidUpdateSystemState() then return release(self) end
		local kind = self.nextUpdateType
		if kind == self.UPDATETYPE_START then
			self:RegisterForNextUpdate(self.UPDATETYPE_SEQUENCE)
		elseif kind == self.UPDATETYPE_SEQUENCE then
			sequence_update(self)
		elseif kind == self.UPDATETYPE_CATCHTIMEOUT and self:IsInExitableSystemState() then
			self.currentSystemState = self.SYSTEMSTATE_CATCH_RESOLVE
			self.ccBGSSSE001_fishingLostCatch:Show()
			fail_holding(self, false, is_fish(self))
		end
		if self.handling == HD.Idle then release(self) end
	end

	function C:OnUpdate()
		if self.updateOwed then return end
		self.updateOwed = true
		self.update_t = 0.0
		self:OnTick()
	end

	function C:ReelLine()
		if self.handlingInputOrUpdate then return end -- input during a run is thrown away
		self.handlingInputOrUpdate = true
		local state = self.currentSystemState
		if state == self.SYSTEMSTATE_CATCH_RESOLVE then return release(self) end
		self.currentSystemState = self.SYSTEMSTATE_CATCH_RESOLVE
		if state == self.SYSTEMSTATE_NIBBLE then
			self.ccBGSSSE001_fishingEarlyReelNibble:Show()
			fail_holding(self, true, true)
		elseif state == self.SYSTEMSTATE_HOOKED then
			if self:IsCatchSuccessful() then
				self.handling = HD.Resolving
				self:CatchSuccess()
			else
				self.ccBGSSSE001_fishingLostCatch:Show()
				fail_holding(self, false, is_fish(self))
			end
		else
			self.ccBGSSSE001_fishingEarlyReel:Show()
			fail_holding(self, true, false)
		end
	end

	local function handling_tick(self)
		if self.handling == HD.Hooking and self.hook == HK.Idle then
			if is_fish(self) then self:ShowCatchPrompt() end
			self:RegisterForNextUpdate(self.UPDATETYPE_CATCHTIMEOUT)
			release(self)
		elseif self.handling == HD.Resolving and self.resolve == RS.Idle then
			release(self)
		end
		if not self.updateOwed or self.update_t > 0 then return end
		if self.handlingInputOrUpdate then
			self.update_t = 0.25
			return
		end
		handle_update(self)
	end

	-- callees first, so a caller sees a callee that finished this tick
	function C:OnTick()
		split_tick(self)
		camera_tick(self)
		cast_tick(self)
		hook_tick(self)
		fanfare_tick(self)
		resolve_tick(self)
		handling_tick(self)
	end
end
