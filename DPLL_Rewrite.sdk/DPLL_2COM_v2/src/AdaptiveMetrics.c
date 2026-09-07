#include "AdaptiveMetrics.h"
#include <math.h>
#include <string.h>

int AdaptiveMetrics_Calculate(const AdaptivePlSnapshot *s,
		u32 sampleClockHz, AdaptiveWindowMetrics *r)
{
	double n, meanSquare, variance;
	s64 frequencyLimit, phaseLimit;
	if (r == 0) return ADAPTIVE_PL_INVALID_ARGUMENT;
	memset(r, 0, sizeof(*r));
	if (s == 0 || sampleClockHz == 0U || s->sampleCount < 2U ||
		s->sampleCount > 0x80000000U || s->sequence == 0U)
		return ADAPTIVE_PL_INVALID_ARGUMENT;
	if (s->metricsInfo != ADAPTIVE_PL_METRICS_INFO_VALUE)
		return ADAPTIVE_PL_NOT_PRESENT;

	/* Bounds follow the signed 14-bit frequency and signed 32-bit phase inputs. */
	frequencyLimit = (s64)s->sampleCount * 8192;
	phaseLimit = (s64)s->sampleCount * 2147483648LL;
	if (s->frequencySignedSum < -frequencyLimit ||
		s->frequencySignedSum > (s64)s->sampleCount * 8191 ||
		s->frequencySquareSum > (u64)s->sampleCount * 67108864ULL ||
		s->phaseSignedSum < -phaseLimit ||
		s->phaseSignedSum > (s64)s->sampleCount * 2147483647LL ||
		s->lockedSampleCount > s->sampleCount ||
		s->residualBadSampleCount > s->sampleCount ||
		s->railSampleCount > s->sampleCount ||
		s->phaseSaturatedSampleCount > s->sampleCount)
		return ADAPTIVE_PL_INVALID_ARGUMENT;

	n = (double)s->sampleCount;
	meanSquare = (double)s->frequencySquareSum / n;
	variance = meanSquare - ((double)s->frequencySignedSum / n) *
		((double)s->frequencySignedSum / n);
	/* A tiny negative value may be rounding; a materially negative variance
	 * indicates inconsistent moments and must not masquerade as zero jitter. */
	if (variance < -1e-7) return ADAPTIVE_PL_INVALID_ARGUMENT;
	r->durationSeconds = n / (double)sampleClockHz;
	r->frequencyMean = (double)s->frequencySignedSum / n;
	r->frequencyRms = sqrt(meanSquare);
	r->frequencyStd = sqrt(variance > 0.0 ? variance : 0.0);
	r->phaseMean = (double)s->phaseSignedSum / n;
	r->lockedFraction = (double)s->lockedSampleCount / n;
	r->residualBadFraction = (double)s->residualBadSampleCount / n;
	r->railFraction = (double)s->railSampleCount / n;
	r->phaseSaturatedFraction = (double)s->phaseSaturatedSampleCount / n;
	r->phaseSlopeValid = s->phaseSaturatedSampleCount == 0U &&
		s->lockedSampleCount == s->sampleCount;
	if (r->phaseSlopeValid) {
		/* Convert before subtraction: opposite signed endpoints can overflow s32. */
		r->phaseSlopePerSecond = ((double)s->phaseLast - (double)s->phaseFirst) *
			(double)sampleClockHz / (n - 1.0);
	}
	return ADAPTIVE_PL_OK;
}
