-- pex: fragment_1 a152a9d7
-- pex: fragment_2 03f5862b
-- The static-skull twin of dlc2_qf_dlc2dunkarstaagqst_020247f8: fragment_1 walks the same bone-FX
-- chain but ends by placing and enabling Karstaag (no battle trigger here); fragment_2 has no
-- throne furniture or battle trigger to touch. No existing OnTick on this class.
local rt = require('skymod.rt')

local Frag1 = rt.sequence("Idle", "Chain", "Settle")
local Frag2 = rt.sequence("Idle", "Waiting")

return function(C)
	C.__vars.frag1 = Frag1.Idle
	C.__vars.frag1T = rt.timer(0.0)
	C.__vars.frag1cur = rt.form("ObjectReference")
	C.__vars.frag2 = Frag2.Idle
	C.__vars.frag2T = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)

	function C:fragment_1()
		if self.frag1 ~= Frag1.Idle then return end -- a run happens once
		local player = rt.static("Game", "GetPlayer")
		player:RemoveItem(self.alias_karstaagskullitem:GetReference())
		self.alias_karstaagskullstatic:GetReference():Enable()
		self.ambrumbleshake:Play(player)
		self.frag1cur = self.alias_karstaagskullstatic:GetReference()
		self.frag1, self.frag1T = Frag1.Chain, 0.0
	end

	function C:fragment_2()
		if self.frag2 ~= Frag2.Idle then return end -- a run happens once
		local player = rt.static("Game", "GetPlayer")
		local karstaag = self.alias_karstaag:GetActorRef()
		self.targetvfx:Play(karstaag, 4, player)
		self.castervfx:Play(player, 4, karstaag)
		self.targetfxs:Play(karstaag, 4)
		self.casterfxs:Play(player, 4)
		self.frag2, self.frag2T = Frag2.Waiting, 3.0
	end

	function C:OnTick()
		if self.frag1 == Frag1.Chain then
			if self.frag1cur == rt.None then
				self.frag1, self.frag1T = Frag1.Settle, 2.0
			elseif self.frag1T <= 0 then
				rt.cast(self.frag1cur, "dlc2dunkarstaagbonefxscript"):TriggerBones()
				self.frag1cur = self.frag1cur:GetLinkedRef()
				self.frag1T = self.frag1T + 0.1
			end
		elseif self.frag1 == Frag1.Settle and self.frag1T <= 0 then
			rt.static("Game", "ShakeController", 0.75, 0.75, 3)
			rt.static("Game", "ShakeCamera", rt.None, 0.5, 3)
			self.ambrumbleshake:Play(rt.static("Game", "GetPlayer"))
			local karstaagRef = self.alias_karstaag:GetReference()
			karstaagRef:PlaceAtMe(self.summontargetfxactivator)
			karstaagRef:Enable(true)
			self.frag1 = Frag1.Idle
		end

		if self.frag2 == Frag2.Waiting and self.frag2T <= 0 then
			local player = rt.static("Game", "GetPlayer")
			player:AddSpell(self.dlc2conjurekarstaag, true)
			rt.cast(self.alias_karstaag:GetActorRef(), "dlc2dunkarstaagghostscript"):DissolveKarstaag()
			self.frag2 = Frag2.Idle
		end
	end
end
