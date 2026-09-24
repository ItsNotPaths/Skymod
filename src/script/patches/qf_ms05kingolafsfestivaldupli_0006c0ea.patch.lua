-- pex: fragment_4 b138eb44
-- Fragment_4 has no wait of its own; it only calls PlaySong, which now returns at once. Nothing
-- else changes. Bard2PlaySong is outside this batch and still the old, latent version.
local rt = require('skymod.rt')

return function(C)
    function C:Fragment_4()
        self.MS05KingOlafsFestival_scene:Start()
        rt.cast(self.BardSongs, "bardsongsscript"):PlaySong(self.alias_Atafalan:GetActorRef(), "Flute")
        rt.cast(self.BardSongs, "bardsongsscript"):Bard2PlaySong(self.alias_Jorn:GetActorRef(), "Drum")
    end
end
