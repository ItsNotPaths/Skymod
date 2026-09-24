-- pex: onactivate 469aabac
-- pex: waiting.onactivate f050a574
-- The base OnActivate only switches to "Waiting" and redispatches; needs no change, since it
-- reaches the rewritten Waiting handler below through the state switch already applied. Waiting's
-- OnActivate went Done, waited 1.5 s, then crumbled and deleted the column: now a timer in Done.
local rt = require('skymod.rt')

return function(C)
	C.__vars.destroyT = rt.timer(0.0)
	C.__vars.destroyed = rt.bool(false) -- Delete() does not yet drop the instance from the tick schedule
	C.__vars.TickRate = rt.float(0.05)

	function C:OnActivate(akActivator)
		self:GotoState("Waiting")
		self:OnActivate(akActivator)
	end

	local Waiting = rt.state(C, "Waiting")
	function Waiting:OnActivate(akActivator)
		self:GotoState("Done")
		self.destroyT = 1.5
	end

	local Done = rt.state(C, "Done")
	function Done:OnTick()
		if self.destroyed or self.destroyT > 0 then return end
		self.destroyed = true
		self.objnchardakcolumncrumble:Play(self.destructiblecolumn)
		self.destructiblecolumn:DamageObject(75)
		self.destructiblecolumncollision:Disable()
		self:Disable()
		self:Delete()
	end
end
