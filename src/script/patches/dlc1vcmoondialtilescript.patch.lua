-- pex: waiting.onactivate 9e102b22
-- pex: placetile fa1acb63
-- PlaceTile played the tile's Trigger and waited for "Done", told the moondial, and only then did
-- the activation take the tile from the player. Now the event does both; `placer` is who placed it.
local rt = require('skymod.rt')

return function(C)
	C.__vars.placer = rt.form("Actor")
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "busy")

	function Waiting:OnActivate(ActivateRef)
		local who = rt.cast(ActivateRef, "Actor")
		if not who or who:GetItemCount(self.Tile) <= 0 then return self.DLC1VCMoondialNoTileMessage:Show() end
		self.placer = who
		self:PlaceTile()
	end

	function C:PlaceTile()
		self:SetDestroyed(true)
		self:GotoState("busy")
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation("Trigger")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Done" then return end
		self.MoondialScript = rt.cast(self.DLC1VCMoondial, "DLC1VCMoondialScript")
		self.MoondialScript:SetTilePlaced(self.TileNumber)
		self:GotoState("done")
		if self.placer then self.placer:RemoveItem(self.Tile, 1) end
		self.placer = rt.None
	end
end
