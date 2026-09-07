#ifndef ADAPTIVE_METRICS_H
#define ADAPTIVE_METRICS_H

#include "AdaptivePlIf.h"

/* Per-window diagnostics, in raw counts. Not the deployed Autotune score. */
typedef struct {
	double durationSeconds;
	double frequencyMean;
	double frequencyRms;
	double frequencyStd;
	double phaseMean;
	double phaseSlopePerSecond;
	double lockedFraction;
	double residualBadFraction;
	double railFraction;
	double phaseSaturatedFraction;
	u8 phaseSlopeValid;
} AdaptiveWindowMetrics;

/* Only call with a successful, coherent snapshot outside a switching transient.
 * NOT_PRESENT denotes an unsupported metrics version. On any failure, result is
 * cleared. Slope uses N-1 intervals, whereas the observation duration uses N.
 */
int AdaptiveMetrics_Calculate(const AdaptivePlSnapshot *snapshot,
		u32 sampleClockHz, AdaptiveWindowMetrics *result);

#endif
