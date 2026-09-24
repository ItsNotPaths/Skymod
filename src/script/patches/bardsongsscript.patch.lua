-- pex: playsong 0dbcdf36
-- PlaySong polled Bard.IsInDialogueWithPlayer() once a second before starting, then waited 1 s
-- after the song began before clearing StopSong. Both are now stages of one run; a second call
-- while one is under way is dropped (this bard's earlier call keeps its settings).
local rt = require('skymod.rt')

local S = rt.sequence("Idle", "Dialogue", "Final")

return function(C)
    C.__vars.psStage = S.Idle
    C.__vars.psClock = rt.stopwatch(0.0)
    C.__vars.psBard = rt.form("ObjectReference")
    C.__vars.psInstrument = rt.string("Any")
    C.__vars.psContinuous = rt.bool(true)
    C.__vars.psSong = rt.int(0)
    C.__vars.psChangeSettings = rt.bool(true)
    C.__vars.TickRate = rt.float(0.1)

    local function abort(self) self.psStage = S.Idle end

    local function song_for(self, last, a, b) return last == a and b or a end

    -- everything after the dialogue wait: no further wait until the trailing one
    local function run_body(self)
        local Bard = self.psBard
        local Instrument, PlayContinuous, SongToPlay, ChangeSettings =
            self.psInstrument, self.psContinuous, self.psSong, self.psChangeSettings

        if ChangeSettings == false and (self.StopSong == true or self.SavedPlayContinuous == false) then
            self.Playing = 0
            return abort(self)
        end
        if Bard == self.Lurbuk and self.Lurbuk:GetCurrentPackage() == self.MorthalLurbukSleep1x5 then
            self.Playing = 0
            return abort(self)
        end

        if ChangeSettings == true then self:StopAllSongs() end
        self.Playing = 1

        if rt.cast(Bard, "actor"):IsInFaction(self.CurrentFollowerFaction) then
            self.Playing = 0
            return abort(self)
        end
        self.BardSongs_Bard:ForceRefTo(Bard)
        self.BardSongsInstrumental_Bard:ForceRefTo(Bard)

        self:RegisterLocationOwner(Bard)

        if ChangeSettings == false then
            Instrument = self.SavedInstrument
            PlayContinuous = self.SavedPlayContinuous
            SongToPlay = 0
        else
            self.SavedInstrument = Instrument
            self.SavedPlayContinuous = PlayContinuous
        end

        if rt.cast(Bard, "actor"):GetActorBase() == self.TalsgarTheWanderer then
            self.SavedPlayContinuous = false
        end

        if Bard == self.Sven and self.MQ106:GetStage() > 20 and self.MQ106:GetStage() < 50 then
            SongToPlay = song_for(self, self.LastSongPlayed, 6, 7)
        end
        if Bard == self.Sven and self.MQ203:IsRunning() then
            SongToPlay = song_for(self, self.LastSongPlayed, 6, 7)
        end

        if Instrument == "Instrumental" then SongToPlay = rt.static("Utility", "RandomInt", 4, 9) end
        if Instrument == "Flute" then SongToPlay = song_for(self, self.LastSongPlayed, 11, 12) end
        if Instrument == "Lute" then SongToPlay = song_for(self, self.LastSongPlayed, 6, 7) end
        if Instrument == "Drum" then SongToPlay = song_for(self, self.LastSongPlayed, 8, 9) end

        if SongToPlay == 0 then SongToPlay = self:GetRandomSong(Bard) end

        if rt.cast(Bard, "actor"):IsInFaction(self.CurrentFollowerFaction) then
            self.Playing = 0
            return abort(self)
        end
        if not Bard:Is3DLoaded() then
            self.Playing = 0
            return abort(self)
        end

        self:PlayChosenSong(SongToPlay)
        self.psStage = S.Final
        self.psClock = 0.0
    end

    function C:PlaySong(Bard, Instrument, PlayContinuous, SongToPlay, ChangeSettings)
        if self.psStage ~= S.Idle then return end -- a run happens once
        self.psBard, self.psInstrument = Bard, Instrument
        self.psContinuous, self.psSong, self.psChangeSettings = PlayContinuous, SongToPlay, ChangeSettings
        if not Bard:IsInDialogueWithPlayer() then return run_body(self) end
        if ChangeSettings == false and (self.StopSong == true or self.SavedPlayContinuous == false) then
            return -- the in-loop check: returns without touching Playing
        end
        self.psStage = S.Dialogue
        self.psClock = 0.0
    end
    rt.params(C, "PlaySong", { {"Bard"}, {"Instrument", "Any"}, {"PlayContinuous", true}, {"SongToPlay", 0}, {"ChangeSettings", true} })

    function C:OnTick()
        if self.psStage == S.Dialogue then
            if self.psClock < 1.0 then return end
            self.psClock = self.psClock - 1.0
            local Bard = self.psBard
            if not Bard:IsInDialogueWithPlayer() then return run_body(self) end
            if self.psChangeSettings == false and (self.StopSong == true or self.SavedPlayContinuous == false) then
                return abort(self)
            end
            return
        end
        if self.psStage == S.Final then
            if self.psClock < 1.0 then return end
            self.StopSong = false
            abort(self)
        end
    end
end
