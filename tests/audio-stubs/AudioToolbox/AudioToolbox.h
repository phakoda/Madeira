/* Test-only Apple boundary declarations. Values are deliberately local to the
 * mock: this validates driver logic, NOT Apple API ABI or device rendering. */
#ifndef MADEIRA_TEST_AUDIO_TOOLBOX_H
#define MADEIRA_TEST_AUDIO_TOOLBOX_H
#include <stdint.h>
typedef uint32_t UInt32;
typedef int32_t OSStatus;
typedef uint32_t AudioUnitRenderActionFlags;
typedef struct { double mSampleTime; } AudioTimeStamp;
typedef struct { UInt32 mNumberChannels, mDataByteSize; void *mData; } AudioBuffer;
typedef struct { UInt32 mNumberBuffers; AudioBuffer mBuffers[1]; } AudioBufferList;
typedef struct {
    UInt32 componentType, componentSubType, componentManufacturer, componentFlags, componentFlagsMask;
} AudioComponentDescription;
typedef struct {
    double mSampleRate;
    UInt32 mFormatID, mFormatFlags, mBytesPerPacket, mFramesPerPacket;
    UInt32 mBytesPerFrame, mChannelsPerFrame, mBitsPerChannel, mReserved;
} AudioStreamBasicDescription;
typedef OSStatus (*AURenderCallback)(void *, AudioUnitRenderActionFlags *,
    const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
typedef struct { AURenderCallback inputProc; void *inputProcRefCon; } AURenderCallbackStruct;
typedef struct FakeAU *AudioUnit;
typedef void *AudioComponent;
enum {
    noErr = 0, kAudio_ParamError = -50,
    kAudioUnitType_Output = 1, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple,
    kAudioFormatLinearPCM, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
    kAudioUnitProperty_SetRenderCallback,
    kAudioFormatFlagIsPacked = 1 << 8, kAudioFormatFlagIsFloat = 1 << 9,
    kAudioFormatFlagIsSignedInteger = 1 << 10,
    kAudioUnitRenderAction_OutputIsSilence = 1 << 11
};
AudioComponent AudioComponentFindNext(AudioComponent, const AudioComponentDescription *);
OSStatus AudioComponentInstanceNew(AudioComponent, AudioUnit *);
OSStatus AudioComponentInstanceDispose(AudioUnit);
OSStatus AudioUnitSetProperty(AudioUnit, UInt32, UInt32, UInt32, const void *, UInt32);
OSStatus AudioUnitInitialize(AudioUnit);
OSStatus AudioUnitUninitialize(AudioUnit);
OSStatus AudioOutputUnitStart(AudioUnit);
OSStatus AudioOutputUnitStop(AudioUnit);
#endif
