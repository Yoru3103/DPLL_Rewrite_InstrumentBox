#include "AdaptivePlIf.h"
#include "xil_io.h"

#define ADAPTIVE_REG(base, word) ((base) + ((word) << 2))

#define REG_IF_INFO              0x0060U
#define REG_SHADOW_PROFILE       0x0061U
#define REG_SHADOW_KP            0x0062U
#define REG_SHADOW_KI            0x0063U
#define REG_SHADOW_KII           0x0064U
#define REG_SHADOW_KD            0x0065U
#define REG_SHADOW_DCOEF         0x0066U
#define REG_COMMIT_SEQ           0x0067U
#define REG_APPLIED_SEQ          0x0068U
#define REG_APPLY_STATUS         0x0069U
#define REG_ACTIVE_PROFILE       0x006AU
#define REG_ACTIVE_KP            0x006BU
#define REG_ACTIVE_KI            0x006CU
#define REG_ACTIVE_KII           0x006DU
#define REG_ACTIVE_KD            0x006EU
#define REG_ACTIVE_DCOEF         0x006FU

#define REG_SNAPSHOT_SEQ         0x0120U
#define REG_SAMPLE_COUNT         0x0121U
#define REG_AMP_SUM_LOW          0x0122U
#define REG_AMP_SUM_HIGH         0x0123U
#define REG_AMP_MIN_MAX          0x0124U
#define REG_FREQ_SUM_LOW         0x0125U
#define REG_FREQ_SUM_HIGH        0x0126U
#define REG_FREQ_MAX             0x0127U
#define REG_PHASE_SUM_LOW        0x0128U
#define REG_PHASE_SUM_HIGH       0x0129U
#define REG_PHASE_MAX            0x012AU
#define REG_OUTPUT_MIN           0x012BU
#define REG_OUTPUT_MAX           0x012CU
#define REG_LOCKED_SAMPLES       0x012DU
#define REG_POS_RAIL_SAMPLES     0x012EU
#define REG_NEG_RAIL_SAMPLES     0x012FU
#define REG_FREQ_BAD_SAMPLES     0x0130U
#define REG_PHASE_BAD_SAMPLES    0x0131U
#define REG_LOSS_LOCK_EVENTS     0x0132U
#define REG_POS_RAIL_EVENTS      0x0133U
#define REG_NEG_RAIL_EVENTS      0x0134U
#define REG_COMMIT_ERRORS        0x0135U
#define REG_METRICS_INFO         0x0136U
#define REG_FREQ_SIGNED_LOW      0x0137U
#define REG_FREQ_SQUARE_LOW      0x0139U
#define REG_PHASE_SIGNED_LOW     0x013BU
#define REG_PHASE_FIRST          0x013DU
#define REG_PHASE_LAST           0x013EU
#define REG_RESIDUAL_BAD_UNION    0x013FU
#define REG_RAIL_UNION            0x0140U
#define REG_PHASE_SAT_SAMPLES    0x0141U

static u32 AdaptivePl_Read(u32 baseAddress, u32 wordAddress)
{
	return Xil_In32(ADAPTIVE_REG(baseAddress, wordAddress));
}

static void AdaptivePl_Write(u32 baseAddress, u32 wordAddress, u32 value)
{
	Xil_Out32(ADAPTIVE_REG(baseAddress, wordAddress), value);
}

static u64 AdaptivePl_Read64(u32 baseAddress, u32 lowWordAddress)
{
	u64 low = AdaptivePl_Read(baseAddress, lowWordAddress);
	u64 high = AdaptivePl_Read(baseAddress, lowWordAddress + 1U);
	return low | (high << 32);
}

int AdaptivePl_Probe(u32 baseAddress)
{
	return (AdaptivePl_Read(baseAddress, REG_IF_INFO) == ADAPTIVE_PL_IF_INFO_VALUE) ?
		ADAPTIVE_PL_OK : ADAPTIVE_PL_NOT_PRESENT;
}

int AdaptivePl_ReadActive(u32 baseAddress, AdaptivePlParameters *parameters,
		u32 *appliedSequence, u32 *applyStatus, u32 maximumAttempts)
{
	u32 attempt;
	u32 sequenceBefore;
	u32 sequenceAfter;

	if ((parameters == 0) || (appliedSequence == 0) || (applyStatus == 0) ||
		(maximumAttempts == 0U))
		return ADAPTIVE_PL_INVALID_ARGUMENT;
	if (AdaptivePl_Probe(baseAddress) != ADAPTIVE_PL_OK)
		return ADAPTIVE_PL_NOT_PRESENT;

	/* APPLIED_SEQ brackets the active-register reads so one result is coherent. */
	for (attempt = 0U; attempt < maximumAttempts; ++attempt) {
		sequenceBefore = AdaptivePl_Read(baseAddress, REG_APPLIED_SEQ);
		*applyStatus = AdaptivePl_Read(baseAddress, REG_APPLY_STATUS);
		parameters->profileId = (u8)AdaptivePl_Read(baseAddress, REG_ACTIVE_PROFILE);
		parameters->kp = AdaptivePl_Read(baseAddress, REG_ACTIVE_KP);
		parameters->ki = AdaptivePl_Read(baseAddress, REG_ACTIVE_KI);
		parameters->kii = AdaptivePl_Read(baseAddress, REG_ACTIVE_KII);
		parameters->kd = AdaptivePl_Read(baseAddress, REG_ACTIVE_KD);
		parameters->dCoefficient = AdaptivePl_Read(baseAddress, REG_ACTIVE_DCOEF) & 0x3FFFFU;
		sequenceAfter = AdaptivePl_Read(baseAddress, REG_APPLIED_SEQ);
		if (sequenceBefore == sequenceAfter) {
			*appliedSequence = sequenceAfter;
			return ADAPTIVE_PL_OK;
		}
	}

	return ADAPTIVE_PL_VERIFY_ERROR;
}

int AdaptivePl_Commit(u32 baseAddress, const AdaptivePlParameters *parameters,
		u32 commitSequence, u32 maximumPolls)
{
	u32 status;
	u32 poll;

	if ((parameters == 0) || (commitSequence == 0U) || (maximumPolls == 0U))
		return ADAPTIVE_PL_INVALID_ARGUMENT;
	if (AdaptivePl_Probe(baseAddress) != ADAPTIVE_PL_OK)
		return ADAPTIVE_PL_NOT_PRESENT;

	status = AdaptivePl_Read(baseAddress, REG_APPLY_STATUS);
	if ((status & ADAPTIVE_PL_STATUS_BUSY) != 0U)
		return ADAPTIVE_PL_BUSY;
	/* Clear a previous transaction's sticky error before judging this commit. */
	if ((status & ADAPTIVE_PL_STATUS_ERROR) != 0U) {
		AdaptivePl_Write(baseAddress, REG_APPLY_STATUS, ADAPTIVE_PL_STATUS_ERROR);
		status = AdaptivePl_Read(baseAddress, REG_APPLY_STATUS);
		if ((status & ADAPTIVE_PL_STATUS_ERROR) != 0U)
			return ADAPTIVE_PL_VERIFY_ERROR;
	}
	if (AdaptivePl_Read(baseAddress, REG_APPLIED_SEQ) == commitSequence)
		return ADAPTIVE_PL_VERIFY_ERROR;

	AdaptivePl_Write(baseAddress, REG_SHADOW_PROFILE, parameters->profileId);
	AdaptivePl_Write(baseAddress, REG_SHADOW_KP, parameters->kp);
	AdaptivePl_Write(baseAddress, REG_SHADOW_KI, parameters->ki);
	AdaptivePl_Write(baseAddress, REG_SHADOW_KII, parameters->kii);
	AdaptivePl_Write(baseAddress, REG_SHADOW_KD, parameters->kd);
	AdaptivePl_Write(baseAddress, REG_SHADOW_DCOEF, parameters->dCoefficient & 0x3FFFFU);
	AdaptivePl_Write(baseAddress, REG_COMMIT_SEQ, commitSequence);

	for (poll = 0U; poll < maximumPolls; ++poll) {
		status = AdaptivePl_Read(baseAddress, REG_APPLY_STATUS);
		if (((status & ADAPTIVE_PL_STATUS_BUSY) == 0U) &&
			(AdaptivePl_Read(baseAddress, REG_APPLIED_SEQ) == commitSequence))
			break;
	}
	if (poll == maximumPolls)
		return ADAPTIVE_PL_TIMEOUT;
	if (((status & (ADAPTIVE_PL_STATUS_ACTIVE | ADAPTIVE_PL_STATUS_ERROR)) !=
		ADAPTIVE_PL_STATUS_ACTIVE) ||
		(AdaptivePl_Read(baseAddress, REG_ACTIVE_PROFILE) != parameters->profileId) ||
		(AdaptivePl_Read(baseAddress, REG_ACTIVE_KP) != parameters->kp) ||
		(AdaptivePl_Read(baseAddress, REG_ACTIVE_KI) != parameters->ki) ||
		(AdaptivePl_Read(baseAddress, REG_ACTIVE_KII) != parameters->kii) ||
		(AdaptivePl_Read(baseAddress, REG_ACTIVE_KD) != parameters->kd) ||
		(AdaptivePl_Read(baseAddress, REG_ACTIVE_DCOEF) !=
			(parameters->dCoefficient & 0x3FFFFU)))
		return ADAPTIVE_PL_VERIFY_ERROR;

	return ADAPTIVE_PL_OK;
}

int AdaptivePl_ReadSnapshot(u32 baseAddress, AdaptivePlSnapshot *snapshot,
		u32 maximumAttempts)
{
	u32 attempt;
	u32 sequenceBefore;
	u32 packedAmplitude;
	u32 metricsInfo;

	if ((snapshot == 0) || (maximumAttempts == 0U))
		return ADAPTIVE_PL_INVALID_ARGUMENT;
	snapshot->metricsInfo = 0U;
	if (AdaptivePl_Probe(baseAddress) != ADAPTIVE_PL_OK)
		return ADAPTIVE_PL_NOT_PRESENT;

	metricsInfo = AdaptivePl_Read(baseAddress, REG_METRICS_INFO);
	/* Reset optional fields even when the caller reuses a previous v1 snapshot. */
	snapshot->frequencySignedSum = 0;
	snapshot->frequencySquareSum = 0U;
	snapshot->phaseSignedSum = 0;
	snapshot->phaseFirst = 0;
	snapshot->phaseLast = 0;
	snapshot->residualBadSampleCount = 0U;
	snapshot->railSampleCount = 0U;
	snapshot->phaseSaturatedSampleCount = 0U;
	for (attempt = 0U; attempt < maximumAttempts; ++attempt) {
		sequenceBefore = AdaptivePl_Read(baseAddress, REG_SNAPSHOT_SEQ);
		snapshot->sampleCount = AdaptivePl_Read(baseAddress, REG_SAMPLE_COUNT);
		snapshot->amplitudeSum = AdaptivePl_Read64(baseAddress, REG_AMP_SUM_LOW);
		packedAmplitude = AdaptivePl_Read(baseAddress, REG_AMP_MIN_MAX);
		snapshot->amplitudeMin = (u16)(packedAmplitude & 0xFFFFU);
		snapshot->amplitudeMax = (u16)(packedAmplitude >> 16);
		snapshot->frequencyAbsSum = AdaptivePl_Read64(baseAddress, REG_FREQ_SUM_LOW);
		snapshot->frequencyAbsMax = AdaptivePl_Read(baseAddress, REG_FREQ_MAX);
		snapshot->phaseAbsSum = AdaptivePl_Read64(baseAddress, REG_PHASE_SUM_LOW);
		snapshot->phaseAbsMax = AdaptivePl_Read(baseAddress, REG_PHASE_MAX);
		snapshot->outputMin = (s32)AdaptivePl_Read(baseAddress, REG_OUTPUT_MIN);
		snapshot->outputMax = (s32)AdaptivePl_Read(baseAddress, REG_OUTPUT_MAX);
		snapshot->lockedSampleCount = AdaptivePl_Read(baseAddress, REG_LOCKED_SAMPLES);
		snapshot->positiveRailSampleCount = AdaptivePl_Read(baseAddress, REG_POS_RAIL_SAMPLES);
		snapshot->negativeRailSampleCount = AdaptivePl_Read(baseAddress, REG_NEG_RAIL_SAMPLES);
		snapshot->frequencyBadSampleCount = AdaptivePl_Read(baseAddress, REG_FREQ_BAD_SAMPLES);
		snapshot->phaseBadSampleCount = AdaptivePl_Read(baseAddress, REG_PHASE_BAD_SAMPLES);
		snapshot->lossOfLockEventCount = AdaptivePl_Read(baseAddress, REG_LOSS_LOCK_EVENTS);
		snapshot->positiveRailEventCount = AdaptivePl_Read(baseAddress, REG_POS_RAIL_EVENTS);
		snapshot->negativeRailEventCount = AdaptivePl_Read(baseAddress, REG_NEG_RAIL_EVENTS);
		snapshot->commitErrorCount = AdaptivePl_Read(baseAddress, REG_COMMIT_ERRORS);
		if (metricsInfo == ADAPTIVE_PL_METRICS_INFO_VALUE) {
			snapshot->frequencySignedSum = (s64)AdaptivePl_Read64(baseAddress, REG_FREQ_SIGNED_LOW);
			snapshot->frequencySquareSum = AdaptivePl_Read64(baseAddress, REG_FREQ_SQUARE_LOW);
			snapshot->phaseSignedSum = (s64)AdaptivePl_Read64(baseAddress, REG_PHASE_SIGNED_LOW);
			snapshot->phaseFirst = (s32)AdaptivePl_Read(baseAddress, REG_PHASE_FIRST);
			snapshot->phaseLast = (s32)AdaptivePl_Read(baseAddress, REG_PHASE_LAST);
			snapshot->residualBadSampleCount = AdaptivePl_Read(baseAddress, REG_RESIDUAL_BAD_UNION);
			snapshot->railSampleCount = AdaptivePl_Read(baseAddress, REG_RAIL_UNION);
			snapshot->phaseSaturatedSampleCount = AdaptivePl_Read(baseAddress, REG_PHASE_SAT_SAMPLES);
		}
		snapshot->sequence = AdaptivePl_Read(baseAddress, REG_SNAPSHOT_SEQ);
		if ((snapshot->sequence == sequenceBefore) && (snapshot->sequence != 0U)) {
			snapshot->metricsInfo = (metricsInfo == ADAPTIVE_PL_METRICS_INFO_VALUE) ? metricsInfo : 0U;
			return ADAPTIVE_PL_OK;
		}
	}

	return ADAPTIVE_PL_INCONSISTENT_SNAPSHOT;
}
