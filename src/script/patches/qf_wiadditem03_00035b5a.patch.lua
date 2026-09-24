-- pex: fragment_4 f6853334
-- Fragment_4 polled Wait(5) until all three thugs were unloaded, then deleted them and stopped
-- the quest. DeleteWhenAble is now an engine fact (script-api.md section 5), so it is set at once;
-- only the "wait until unloaded, then Stop" part still polls, at the same 5 s rate.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(5.0)
	C.__vars.shutdownPending = rt.bool(false)

	function C:Fragment_4()
		if self.shutdownPending then return end -- a run happens once
		self.shutdownPending = true
		-- WIs is WorldInteractionsScript's property, reached through the sibling script on the form
		local faction = rt.cast(self.form, "wiadditem03script").WIs.WIPlayerEnemyFaction
		self.Alias_Thug1:GetActorReference():AddToFaction(faction)
		self.Alias_Thug2:GetActorReference():AddToFaction(faction)
		self.Alias_Thug3:GetActorReference():AddToFaction(faction)
		self:OnTick() -- Papyrus checked at once
	end

	function C:OnTick()
		if not self.shutdownPending then return end
		if self.Alias_Thug1:GetActorReference():Is3DLoaded()
			or self.Alias_Thug2:GetActorReference():Is3DLoaded()
			or self.Alias_Thug3:GetActorReference():Is3DLoaded() then
			return
		end
		self.shutdownPending = false
		self.Alias_Thug1:GetActorReference():DeleteWhenAble()
		self.Alias_Thug2:GetActorReference():DeleteWhenAble()
		self.Alias_Thug3:GetActorReference():DeleteWhenAble()
		self:Stop()
	end
end
