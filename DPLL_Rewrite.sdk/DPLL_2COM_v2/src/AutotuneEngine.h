#ifndef AUTOTUNE_ENGINE_H
#define AUTOTUNE_ENGINE_H
#include "AdaptiveMetrics.h"

#define AT_REPEATS_MAX 5
#define AT_PROFILES 5
#define AT_REPORT_PAGES 9
#define AT_DIAG_BYTES 44
enum { AT_IDLE=0, AT_PRECHECK=1, AT_BASELINE=2, AT_APPLY=3, AT_SETTLE=4,
       AT_EVALUATE=5, AT_NEXT=6, AT_SELECT=7, AT_APPLY_BEST=8, AT_VERIFY=9,
       AT_ROLLBACK=10, AT_DONE=11, AT_FAILED=12, AT_CANCELED=13 };
enum { AT_NONE=0, AT_SUCCESS=1, AT_ACCEPTED=2, AT_BUSY=3, AT_REJECTED=4,
       AT_INVALID_ACTION=5, AT_INVALID_POLICY=6, AT_NOT_LOCKED=7,
       AT_READBACK_ERROR=8, AT_CANCEL=9, AT_UNSUPPORTED=10, AT_DATA_ERROR=11,
       AT_NO_IMPROVEMENT=12, AT_INPUT_CHANGED=13, AT_VERIFY_FAILED=14,
       AT_TIMEOUT=15, AT_ROLLBACK_FAILED=16, AT_BAD_CONFIG=17 };
enum { AT_R_DATA=1, AT_R_COVERAGE=2, AT_R_SIGNAL=4, AT_R_LOCK=8,
       AT_R_RAIL=16, AT_R_RESIDUAL=32, AT_R_PHASE_SAT=64, AT_R_OUTPUT=128,
       AT_R_EVENTS=256, AT_R_DRIFT=512, AT_R_VERIFY=1024, AT_R_IO=2048,
       AT_R_TIMEOUT=4096, AT_R_UNSUPPORTED=8192, AT_R_CANCEL=16384 };
enum { AT_MODE_BASE=0, AT_MODE_CANDIDATE=1, AT_MODE_CONTROL=2,
       AT_MODE_VERIFY=3, AT_MODE_RESTORE=4, AT_MODE_CALIBRATE=5 };
typedef struct { u32 kp, ki, kii, kd, dCoeff; } AT_Profile;
typedef struct {
    u32 windowMs, repeats, coveragePermille, amplitudeFloor, improvementPermille;
} AT_Config;
typedef struct {
    u32 clockHz, windowSamples, settleMs;
    s32 phaseOffset, outputLow, outputHigh;
} AT_Hardware;
typedef struct {
    int (*readProfile)(void *, AT_Profile *);
    int (*apply)(void *, const AT_Profile *, u8);
    int (*snapshot)(void *, AdaptivePlSnapshot *);
    u32 (*status)(void *);
    void *user;
} AT_IO;

typedef struct {
    u32 reasons, reportId, elapsedMs, windows, missing, pairs, flips, readErrors;
    u32 firstSeq, lastSeq, lossEvents, posEvents, negEvents, commitErrors;
    u64 samples;
    double frequencyMean, frequencyRms, frequencyStd, frequencyMae, frequencyPeak;
    double phaseMean, phaseMae, phasePeak, slope, slopeFraction;
    double flipRate, windowAbsMean, amplitudeMean, coverage;
    double lockFraction, residualFraction, railFraction, phaseSatFraction;
    double score, outputHeadroom;
    double frequencyBadFraction, phaseBadFraction;
    u32 amplitudeMin, amplitudeMax;
    s32 outputMin, outputMax;
    u8 mode, profile, repeat, valid, runId;
    AT_Profile parameters;
    double scaleF, scaleP, scaleD, deadband;
    AT_Config config;
    AT_Hardware hardware;
    double groupMean, groupSpread, baselineMean, baselineSpread, bestMean, bestSpread;
    u32 groupSize, bestProfile;
} AT_Report;
typedef struct {
    u64 samples, freqSq, freqAbs, phaseAbs, amplitude;
    s64 freqSum, phaseSum;
    u64 locked, bad, rail, sat, frequencyBad, phaseBad, slopeSamples;
    double absSlopeSum, windowAbsSum;
    u32 windows, missing, pairs, flips, readErrors, firstSeq, lastSeq;
    u32 ampMin, ampMax, freqPeak, phasePeak, startMs, lastFreshMs;
    s32 outputMin, outputMax;
    u32 lossStart, posStart, negStart, commitStart, commitLast, lossLast, posLast, negLast;
    u32 reasons;
    int previousSign;
    u8 discard, anchored;
} AT_Accumulator;
typedef struct {
    AT_Config config;
    AT_Hardware hardware;
    AT_IO io;
    AT_Profile profiles[AT_PROFILES];
    AT_Report report, frozen, rounds[AT_REPEATS_MAX];
    AT_Accumulator acc;
    double baselineMean, baselineSpread, bestMean, bestSpread, bestMin;
    double scaleF, scaleP, scaleD, deadband, baselineAmplitude;
    u32 stateStartMs, runStartMs, lastTickMs, stableSinceMs, endMs, reportCounter;
    u32 completed, rejectionReasons;
    u8 state, mode, current, best, candidate, repeat, runId;
    u8 busy, done, failed, paramsValid, lockValid, result, progress;
    u8 saved, changed, cancel, stable, lastResult, frozenValid, baselineReady;
} AT_Engine;

void AT_DefaultConfig(AT_Config *);
int AT_ConfigValid(const AT_Config *);
void AT_Init(AT_Engine *, const AT_Hardware *, const AT_IO *);
int AT_Start(AT_Engine *, u32 now);
void AT_Tick(AT_Engine *, u32 now);
void AT_Cancel(AT_Engine *);
void AT_Invalidate(AT_Engine *);
void AT_Clear(AT_Engine *);
void AT_BeginWindow(AT_Engine *, u32 now);
int AT_AddSnapshot(AT_Engine *, const AdaptivePlSnapshot *, u32 now);
void AT_FinishWindow(AT_Engine *, u32 now, AT_Report *);
double AT_Score(const AT_Engine *, const AT_Report *);
int AT_DiagnosticPage(AT_Engine *, u8 page, u8 *payload);
#endif
