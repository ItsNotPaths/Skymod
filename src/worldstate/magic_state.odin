package worldstate

// What magic knows beyond effects: the words of power an actor was taught or has unlocked, the
// player's beast form, and who is a vampire or a werewolf. Scripts write these (Game.TeachWord,
// SetBeastForm, SendVampirismStateChanged ...); the shout menu, menus and conditions read them.

WORD_TAUGHT :: 1
WORD_UNLOCKED :: 2

// teach_word / unlock_word are Game.TeachWord / Game.UnlockWord: taught is not unlocked.
teach_word :: proc(ws: ^World_State, actor, word: Form_ID) {delta_upsert(&ws.words, actor)[word] |= WORD_TAUGHT}
// (hole story-voice-power :tags (quest magic) :sev polish :needs (story-manager)) unlocking a word queues no NVPE story event (WINewVoicePower01).
unlock_word :: proc(ws: ^World_State, actor, word: Form_ID) {delta_upsert(&ws.words, actor)[word] |= WORD_UNLOCKED}

word_taught :: proc(ws: ^World_State, actor, word: Form_ID) -> bool {return word_bits(ws, actor, word) & WORD_TAUGHT != 0}
word_unlocked :: proc(ws: ^World_State, actor, word: Form_ID) -> bool {return word_bits(ws, actor, word) & WORD_UNLOCKED != 0}

@(private)
word_bits :: proc(ws: ^World_State, actor, word: Form_ID) -> i32 {
	words, _ := ws.words[actor]
	return words[word]
}

// set_in_set adds or removes a form: SendVampirismStateChanged, SendLycanthropyStateChanged.
set_in_set :: proc(m: ^Form_Set, form: Form_ID, on: bool) {
	if on {m[form] = true} else {delete_key(m, form)}
}
