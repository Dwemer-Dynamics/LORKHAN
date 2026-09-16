#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <vector>

namespace lorkhan {
struct PlaybackSettings {
    float voiceVolumePercent=100, headVoiceVolumePercent=100;
    int audioMode=1;
    float distanceScale=1, dropoffInsidePercent=70, dropoffOutsidePercent=70, legacyDistanceScale=1;
    bool cameraBasedAudio=true, invertHeading=false;
    int clipStartMs=0, clipEndMs=0;
    float lipIntensity=1;
    int lipResolutionMs=0;
    bool pauseOnGamePause=false;
};
inline bool validPlayback(const PlaybackSettings& s) {
    const auto range=[](float v,float lo,float hi){return std::isfinite(v)&&v>=lo&&v<=hi;};
    return range(s.voiceVolumePercent,0,500)&&range(s.headVoiceVolumePercent,0,200)
        &&s.audioMode>=0&&s.audioMode<=4&&range(s.distanceScale,.1f,20)
        &&range(s.dropoffInsidePercent,25,200)&&range(s.dropoffOutsidePercent,25,200)
        &&range(s.legacyDistanceScale,0,4)&&s.clipStartMs>=0&&s.clipStartMs<=100
        &&s.clipEndMs>=0&&s.clipEndMs<=2000&&range(s.lipIntensity,.1f,2)
        &&s.lipResolutionMs>=0&&s.lipResolutionMs<=1000;
}
// Compute only Lorkhan attenuation; native 3D attenuation is disabled for these managed streams.
inline float playbackGain(const PlaybackSettings& s,float distance,float minimum,float maximum,bool exterior,bool head) {
    float gain=s.voiceVolumePercent/100.f*(head?s.headVoiceVolumePercent/100.f:1.f);
    if(head||s.audioMode==0||s.audioMode==3)return gain;
    if(s.audioMode==1){
        if(s.legacyDistanceScale<1)return gain;
        distance/=s.legacyDistanceScale;
        return gain*std::clamp((maximum-distance)/std::max(maximum-minimum,1.f),0.f,1.f);
    }
    distance/=s.distanceScale;
    const float normal=std::max(0.f,(distance-minimum)/std::max(maximum-minimum,1.f));
    const float exponent=(exterior?s.dropoffOutsidePercent:s.dropoffInsidePercent)/100.f;
    return gain*std::pow(std::max(0.f,1.f-normal),exponent);
}
inline std::size_t clipFrames(int rate,int milliseconds) {
    return static_cast<std::size_t>(std::max(0,rate))*static_cast<std::size_t>(std::max(0,milliseconds))/1000;
}
// Retain a bounded tail across decoder reads so trimming is independent of chunk boundaries.
class PlaybackClipWindow {
    std::vector<char> mPending;
    std::size_t mSkip, mTail;
public:
    PlaybackClipWindow(std::size_t skip, std::size_t tail):mSkip(skip),mTail(tail){}
    void append(const char* data,std::size_t size) {
        const auto skip=std::min(mSkip,size);mSkip-=skip;
        mPending.insert(mPending.end(),data+skip,data+size);
    }
    std::size_t available() const {return mPending.size()>mTail?mPending.size()-mTail:0;}
    std::size_t read(char* data,std::size_t size) {
        const auto count=std::min(size,available());
        if(count)std::memcpy(data,mPending.data(),count);
        mPending.erase(mPending.begin(),mPending.begin()+count);return count;
    }
};
inline float lipAmplitude(float loudness,float intensity) {return std::clamp(loudness*intensity,0.f,1.f);}
inline bool validConnectionTimeout(int seconds) { return seconds>=15&&seconds<=300; }
}
