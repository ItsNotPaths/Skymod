-- pex: fragment_19 f5540f6d
-- pex: fragment_4 88b2f490
-- Stage 4 opened the book, waited for it, then raised Hermaeus Mora and started his scene. Now
-- `f4_book` is the book being opened and OnTick waits for its `opening` to end.
-- Fragment_19 needs no change: its EnableHM(false) never waited and ShowRewards starts a run.
local rt = require('skymod.rt')

return function(C)
	C.__vars.f4_book = rt.form("DLC2ApocryphaBookRewardScript")
	C.__vars.TickRate = rt.float(0.1)

	function C:Fragment_4()
		if self.f4_book then return end
		self.f4_book = self.Alias_Book2Apocrypha:GetRef()
		self.f4_book:OpenBook()
		self:OnTick()
	end

	function C:OnTick()
		if not self.f4_book or self.f4_book.opening then return end
		self.f4_book = rt.None
		rt.cast(self, "DLC2MQ05Script"):EnableHM(true)
		self.DLC2MQ05HermaeusMoraScene:Start()
	end
end
