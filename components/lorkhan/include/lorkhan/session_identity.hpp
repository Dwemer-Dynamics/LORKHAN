#pragma once

#include "lorkhan/validation.hpp"
#include <functional>
#include <stdexcept>
#include <string>

namespace lorkhan {
// A save owns these IDs. Loading never infers character identity from a name or installation config.
struct CharacterSessionIdentity {
    std::string character, playthrough, binding, legacyPlaythrough;
    bool prepared=false;
    bool selected() const {return prepared&&!character.empty()&&!playthrough.empty()&&!binding.empty();}
    void clear() {*this={};}
    void prepare(bool newGame,const std::string& savedCharacter,const std::string& savedPlaythrough,
        const std::string& savedBinding,const std::string& configuredLegacy,const std::function<std::string()>& uuid)
    {
        if(prepared)throw std::invalid_argument("character_identity_already_prepared");
        if((!savedCharacter.empty()&&!isCanonicalUuid(savedCharacter))
            ||(!savedPlaythrough.empty()&&!isCanonicalUuid(savedPlaythrough))
            ||(!savedBinding.empty()&&savedBinding!="new"&&savedBinding!="existing")
            ||(!savedBinding.empty()&&(savedCharacter.empty()||savedPlaythrough.empty())))
            throw std::invalid_argument("invalid_saved_character_identity");
        legacyPlaythrough=savedPlaythrough.empty()?configuredLegacy:savedPlaythrough;
        character=newGame||savedCharacter.empty()?uuid():savedCharacter;
        if(newGame){playthrough=uuid();binding="new";}
        else if(!savedCharacter.empty()&&!savedPlaythrough.empty()&&!savedBinding.empty()){
            playthrough=savedPlaythrough;binding=savedBinding;
        }
        prepared=true;
    }
    // Replayed clicks are idempotent; switching an already selected identity needs another load fence.
    void choose(const std::string& expectedCharacter,const std::string& choice,const std::function<std::string()>& uuid)
    {
        if(!prepared||expectedCharacter!=character||(choice!="existing"&&choice!="new"))
            throw std::invalid_argument("stale_character_selection");
        if(selected()){
            if(binding!=choice)throw std::invalid_argument("character_selection_already_applied");
            return;
        }
        if(choice=="existing"&&!isCanonicalUuid(legacyPlaythrough))throw std::invalid_argument("legacy_playthrough_unavailable");
        playthrough=choice=="existing"?legacyPlaythrough:uuid();binding=choice;
    }
};
}
