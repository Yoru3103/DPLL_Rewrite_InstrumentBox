#ifndef ADAPTIVE_PL_IF_H
#define ADAPTIVE_PL_IF_H

#include "xil_types.h"

#define ADAPTIVE_PL_IF_INFO_VALUE       0xAD030001U
#define ADAPTIVE_PL_STATUS_BUSY         (1U << 0)
#define ADAPTIVE_PL_STATUS_ACTIVE       (1U << 1)
#define ADAPTIVE_PL_STATUS_ERROR        (1U << 2)

typedef struct {
	u8 profileId;
	u32 kp;
	u32 ki;
	u32 kii;
	u32 kd;
	u32 dCoefficient;
} AdaptivePlParameters;

typedef struct {
	u32 sequence;
	u32 sampleCount;
	u64 amplitudeSum;
	u16 amplitudeMin;
	u16 amplitudeMax;
	u64 frequencyAbsSum;
	u32 frequencyAbsMax;
	u64 phaseAbsSum;
	u32 phaseAbsMax;
	s32 outputMin;
	s32 outputMax;
	u32 lockedSampleCount;
	u32 positiveRailSampleCount;
	u32 negativeRailSampleCount;
	u32 frequencyBadSampleCount;
	u32 phaseBadSampleCount;
	u32 lossOfLockEventCount;
	u32 positiveRailEventCount;
	u32 negativeRailEventCount;
	u32 commitErrorCount;
} AdaptivePlSnapshot;

typedef enum {
	ADAPTIVE_PL_OK = 0,
	ADAPTIVE_PL_NOT_PRESENT = -1,
	ADAPTIVE_PL_BUSY = -2,
	ADAPTIVE_PL_TIMEOUT = -3,
	ADAPTIVE_PL_VERIFY_ERROR = -4,
	ADAPTIVE_PL_INCONSISTENT_SNAPSHOT = -5,
	ADAPTIVE_PL_INVALID_ARGUMENT = -6
} AdaptivePlResult;

int AdaptivePl_Probe(u32 baseAddress);
int AdaptivePl_ReadActive(u32 baseAddress, AdaptivePlParameters *parameters,
		u32 *appliedSequence, u32 *applyStatus, u32 maximumAttempts);
int AdaptivePl_Commit(u32 baseAddress, const AdaptivePlParameters *parameters,
		u32 commitSequence, u32 maximumPolls);
int AdaptivePl_ReadSnapshot(u32 baseAddress, AdaptivePlSnapshot *snapshot,
		u32 maximumAttempts);

#endif
