-- pex: book01dungeonhmintro 529cdd94 ec385126
-- pex: checkforhmintro ff2e0c6c cfa86ff4
-- pex: moveplayerhome 0e3bb597 41ff68fe
-- pex: moveplayertodungeon 30c7a426 2335c8ca
-- pex: playerinbleedout 943c0d51 969f7b3b
-- pex: readapocryphabook bed4d17c e4a61412
-- pex: readbook 7e938c6e 3f8f6acc
-- The black books' controller. Reading waited for the book to open (1.5 s), maybe for the player
-- to sheathe (2 s), then moved them to Apocrypha (5 s warp, 2 s before the water spell) or home
-- (1.5 s fade, 3 s before the hand fix), then played Hermaeus Mora's intro once. Each wait is now
-- a stage of its own run, stepped by OnTick; a caller waits for the callee's stage to be Idle.
local rt = require('skymod.rt')

return function(C)
	C.Read = rt.sequence("Idle", "Opening", "Refused", "Sheathing", "Moving", "Intro")
	C.Home = rt.sequence("Idle", "Fading", "Settling")
	C.Warp = rt.sequence("Idle", "Warping", "Arriving")
	C.Intro = rt.sequence("Idle", "Appearing", "Playing")
	C.Bleed = rt.sequence("Idle", "Collapsing", "Fading", "Home")
	local R, H, W, I, B = C.Read, C.Home, C.Warp, C.Intro, C.Bleed
	local v = C.__vars
	v.read, v.read_t = R.Idle, rt.timer(0.0)
	v.read_book, v.read_real = rt.form("DLC2BlackBookScript"), rt.form("DLC2BlackBookScript")
	v.read_unequip, v.read_to_apocrypha = rt.bool(false), rt.bool(false)
	v.rewards_book = rt.form("DLC2ApocryphaBookScript") -- its rewards show once the read is over
	v.home, v.home_t, v.home_heal = H.Idle, rt.timer(0.0), rt.bool(false)
	v.warp, v.warp_t = W.Idle, rt.timer(0.0)
	v.intro, v.intro_t, v.intro_index = I.Idle, rt.timer(0.0), rt.int(0)
	v.bleed, v.bleed_t = B.Idle, rt.timer(0.0)
	v.TickRate = rt.float(0.1)

	local function player() return rt.static("Game", "GetPlayer") end
	local function game(fn, ...) return rt.static("Game", fn, ...) end
	-- movement, fighting, camswitch, looking, sneaking, menu, activate, journal tabs, POV
	local function controls(on, looking)
		game(on and "EnablePlayerControls" or "DisablePlayerControls", true, true, true, looking, true, true, true, true, 0)
	end
	local function menu_only(on)
		game(on and "EnablePlayerControls" or "DisablePlayerControls", false, false, false, false, false, true, false, false, 0)
	end
	local function in_apocrypha(self, p)
		return p:IsInLocation(self.DLC2ApocryphaLocation) or p:GetWorldSpace() == self.DLC2ApocryphaWorld
	end

	function C:ReadApocryphaBook(book, bRequireQuestStageToMove, bRequireRewardsShownToMove, bRewardsShown, bShowRewardsOnActivation)
		local moving = (not bRequireQuestStageToMove or book.myQuest:GetStageDone(book.myQuestStage))
			and (not bRequireRewardsShownToMove or bRewardsShown)
		if book.myQuest then book.myQuest:SetStage(book.myQuestStage) end
		local myBook = rt.cast(book:GetLinkedRef(self.DLC2ApocryphaBookLink), "DLC2BlackBookScript")
		if myBook and moving then self:ReadBook(myBook, rt.None) end
		if bShowRewardsOnActivation and not bRewardsShown then
			self.rewards_book = book
			self:OnTick()
		end
	end

	-- Starts the read. It returns true for "started"; the refusal is known 1.5 s later.
	function C:ReadBook(pDataBook, pRealBook)
		if self.read ~= R.Idle then return false end
		local p = player()
		self.read_book, self.read_real = pDataBook, pRealBook or rt.None
		self.read_unequip = (p:GetEquippedItemType(0) > 0 or p:GetEquippedItemType(1) > 0) and p:IsWeaponDrawn()
		self.read = R.Opening
		self.read_t = 1.5 -- the book's opening animation (WaitMenuMode)
		return true
	end

	local function read_opened(self)
		local book, p = self.read_book, player()
		if book.bPlayerHasRead and not self:IsReadingAllowed(true) then
			menu_only(false)
			self.read = R.Refused
			self.read_t = self.read_t + 0.5
			return
		end
		book.bPlayerHasRead = true
		local base = book:GetBaseObject()
		if rt.cast(base, "Book") and p:GetItemCount(base) == 0 and self.read_real then
			self:TakeBook(book)
			book:GetLinkedRef(self.DLC2LinkBlackBookSound):Disable()
			p:AddItem(self.read_real)
		end
		controls(false, book.DisableLooking)
		self.read = R.Sheathing
		self.read_t = self.read_unequip and 2.0 or 0.0
	end

	local function read_move(self)
		local book, p = self.read_book, player()
		self.read_to_apocrypha = false
		self.read = R.Moving
		if self.PlayerAlias:GetActorRef() and in_apocrypha(self, p) then
			self:MovePlayerHome(false)
		elseif p:IsInLocation(self.DLC2SolstheimLocation) then
			self.read_to_apocrypha = true
			self:MovePlayerToDungeon(book.DungeonMarker, book.DungeonLocation)
		end
	end

	local function read_tick(self)
		if self.read == R.Idle or self.read_t > 0 then return end
		local book = self.read_book
		if self.read == R.Opening then return read_opened(self) end
		if self.read == R.Refused then
			game("ShakeCamera", rt.None, 0.5, 1.5)
			self.AMBBlackBookShakeMarker:Play(player())
			menu_only(true)
			self.read = R.Idle
		elseif self.read == R.Sheathing then
			read_move(self)
		elseif self.read == R.Moving then
			if self.home ~= H.Idle or self.warp ~= W.Idle then return end
			if book.ReenableControls then
				controls(true, book.DisableLooking)
				game("RequestAutoSave")
			end
			if self.read_to_apocrypha then self:CheckForHMIntro() end
			self.read = R.Intro
		elseif self.read == R.Intro and self.intro == I.Idle then
			self.read = R.Idle
			if book.myQuest then book.myQuest:SetStage(book.myQuestStage) end
		end
	end

	function C:MovePlayerHome(bHealPlayer)
		local p = player()
		p:GetActorBase():SetInvulnerable(true)
		p:RemoveSpell(self.DLC2abApoWaterDamage)
		self.home = H.Fading
		self.home_heal = bHealPlayer
		self.home_t = 0.0
		if bHealPlayer then
			p:RestoreActorValue("Health", 9999)
		else
			self.DLC2ApocryphaRewardBookEnter:Apply()
			self.home_t = 1.5
		end
	end

	local function home_tick(self)
		if self.home == H.Idle or self.home_t > 0 then return end
		local p = player()
		if self.home == H.Fading then
			if not self.home_heal then self.DLC2ApocryphaRewardBookEnter:PopTo(self.FadeToBlackHoldImod) end
			p:MoveTo(self.TamrielMarker)
			self.FadeToBlackHoldImod:PopTo(self.DLC2ApocryphaRewardBookExit)
			self.FadeToBlackHoldImod:Remove()
			if p:GetActorValue("Health") < 0 then p:RestoreActorValue("Health", 9999) end
			self.PlayerAlias:Clear()
			p:GetActorBase():SetInvulnerable(false)
			self.home = H.Settling
			self.home_t = 3.0
			return
		end
		self.home = H.Idle
		-- hands left empty or on a staff after the move: clear the animation state (bug 93097)
		for hand, var in ipairs({ "iLeftHandType", "iRightHandType" }) do
			local kind = p:GetEquippedItemType(hand)
			if kind == 8 then
				p:UnequipItem(p:GetEquippedWeapon(hand == 0), false, true)
			elseif kind == 0 then
				p:SetAnimationVariableInt(var, 0)
			end
		end
	end

	function C:MovePlayerToDungeon(newDungeonMarker, newDungeonLocation)
		local p = player()
		if p:IsDead() then return end
		self.TamrielMarker:MoveTo(p)
		self.DungeonMarker, self.DungeonLocation = newDungeonMarker, newDungeonLocation
		self.PlayerAlias:ForceRefTo(p)
		local follower = self.Follower:GetRef()
		if follower then
			self.BookFollowerAlias:ForceRefTo(follower)
			self.DLC2BookReadScene:Start()
		end
		game("ForceThirdPerson")
		p:EquipItem(self.DLC2ApocryphaBookWarpArmor, false, true)
		p:PlayIdle(self.IdleDLC2TentacleWarpBook)
		self.DLC2ApocryphaBookEnter:Apply()
		self.OBJApocryphaBookTentaclesTamriel:Play(p)
		self.warp = W.Warping
		self.warp_t = 5.0
	end

	local function warp_tick(self)
		if self.warp == W.Idle or self.warp_t > 0 then return end
		local p, hold = player(), self.FadeToBlackHoldImod
		if self.warp == W.Warping then
			self.DLC2ApocryphaBookEnter:PopTo(hold)
			p:RemoveItem(self.DLC2ApocryphaBookWarpArmor, 1, true)
			p:MoveTo(self.DungeonMarker)
			if self.DungeonLocation == self.DLC2Book01DungeonLocation and not self.bMQ02SceneStarted then
				self.bMQ02SceneStarted = true
				hold:PopTo(self.DLC2ApocryphaBookExitMQ02)
			else
				hold:PopTo(self.DLC2ApocryphaBookExit)
			end
			hold:Remove()
			self.warp = W.Arriving
			self.warp_t = self.warp_t + 2.0
			return
		end
		self.warp = W.Idle
		p:AddSpell(self.DLC2abApoWaterDamage, false)
	end

	local function intro(self, index)
		self.bHMIntroScenePlayed = true
		self.intro_index = index
		self.HermaeusMoraTA:MoveTo(player())
		rt.aget(self.HermaeusMoraIntroFX, index):ChangeState(true)
		self.intro = I.Appearing
		self.intro_t = 1.0
	end

	function C:Book01DungeonHMIntro()
		if self.bHMIntroScenePlayed then return end
		intro(self, 0)
	end

	function C:CheckForHMIntro()
		if self.bHMIntroScenePlayed or self.DungeonLocation == self.DLC2Book01DungeonLocation then return end
		intro(self, rt.afind(self.BookDungeonLocations, self.DungeonLocation))
	end

	local function intro_tick(self)
		if self.intro == I.Idle or self.intro_t > 0 then return end
		local scene = self.DLC2BookDungeonHMIntroScene
		if self.intro == I.Appearing then
			self.HermaeusMoraTA:Enable()
			scene:Start()
			self.intro = I.Playing
			self.intro_t = 1.0
			return
		end
		if scene:IsPlaying() then
			if not player():IsInLocation(self.DLC2ApocryphaLocation) then scene:Stop() end
			self.intro_t = self.intro_t + 1.0
			if scene:IsPlaying() then return end
		end
		self.intro = I.Idle
		rt.aget(self.HermaeusMoraIntroFX, self.intro_index):ChangeState(false)
		self.HermaeusMoraTA:Disable()
	end

	function C:PlayerInBleedout()
		if self.bleed ~= B.Idle then return end
		self.bPlayerBleedingOut = true
		local p = player()
		if p:IsInLocation(self.DungeonLocation) or p:GetWorldSpace() == self.DLC2ApocryphaWorld then
			controls(false, false)
			self.bleed = B.Collapsing
			self.bleed_t = 2.0
			return
		end
		self.PlayerAlias:Clear()
		controls(true, false)
		self.bPlayerBleedingOut = false
	end

	local function bleed_tick(self)
		if self.bleed == B.Idle or self.bleed_t > 0 then return end
		if self.bleed == B.Collapsing then
			self.DLC2ApocryphaRewardBookEnter:Apply()
			self.bleed = B.Fading
			self.bleed_t = self.bleed_t + 1.5
		elseif self.bleed == B.Fading then
			self.DLC2ApocryphaRewardBookEnter:PopTo(self.FadeToBlackHoldImod)
			self.bleed = B.Home
			self:MovePlayerHome(true)
		elseif self.home == H.Idle then
			self.bleed = B.Idle
			controls(true, false)
			self.bPlayerBleedingOut = false
		end
	end

	local function rewards_tick(self)
		if not self.rewards_book or self.read ~= R.Idle then return end
		local book = self.rewards_book
		self.rewards_book = rt.None
		local reward = rt.cast(book, "DLC2ApocryphaBookRewardScript")
		if reward then reward:ShowRewards() else rt.cast(book, "DLC2MiraakAltarScript"):ShowRewards() end
	end

	-- callees first, so a caller sees a callee that finished this tick
	function C:OnTick()
		home_tick(self)
		warp_tick(self)
		intro_tick(self)
		bleed_tick(self)
		read_tick(self)
		rewards_tick(self)
	end
end
