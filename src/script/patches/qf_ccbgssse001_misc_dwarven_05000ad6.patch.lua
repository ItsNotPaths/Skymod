-- pex: fragment_0 1c73a0ca
-- Fragment_0 called Rise() then waited 3 s before finishing the scene. Rise no longer blocks, so
-- OnTick here waits for the column's riseStage to reach Done, then holds 3 s, then finishes.
local rt = require('skymod.rt')

return function(C)
	C.Frag0Stage = rt.sequence("Idle", "Rising", "Holding", "Done")
	C.__vars.frag0Stage = C.Frag0Stage.Idle
	C.__vars.frag0T = rt.timer(0.0)
	C.__vars.frag0Steam = rt.form("ObjectReference")
	local S = C.Frag0Stage

	function C:Fragment_0()
		if self.frag0Stage ~= S.Idle then return end -- a second start is dropped
		local steam = self.alias_steam:GetRef()
		steam:Enable(true)
		self.revealmusic:Add()
		self.alias_stairs:GetRef():PlayAnimation("Raise")
		rt.cast(self.alias_columnchest:GetRef(), "ccbgssse001_dwarvencolumnscript"):Rise()
		self.frag0Steam = steam
		self.frag0Stage = S.Rising
	end

	function C:OnTick()
		if self.frag0Stage == S.Idle or self.frag0Stage == S.Done then return end
		if self.frag0Stage == S.Rising then
			local column = rt.cast(self.alias_columnchest:GetRef(), "ccbgssse001_dwarvencolumnscript")
			if column.riseStage < column.riseStage.seq.Done then return end
			self.frag0Stage = S.Holding
			self.frag0T = 3.0
			return
		end
		if self.frag0Stage == S.Holding then
			if self.frag0T > 0 then return end
			self:CompleteAllObjectives()
			self.miscquests:SetQuestComplete(rt.cast(self, "Quest"), false)
			self.frag0Steam:Disable(true)
			local player = rt.static("Game", "GetPlayer")
			self.alias_spider1ambush1:GetRef():Activate(player, false)
			self.alias_spider1ambush2:GetRef():Activate(player, false)
			rt.cast(self.alias_dynamoholder1:GetRef(), "ccbgssse001_dynamotriggerscript"):AllowItemRemoval()
			rt.cast(self.alias_dynamoholder2:GetRef(), "ccbgssse001_dynamotriggerscript"):AllowItemRemoval()
			self.frag0Stage = S.Done
		end
	end
end
