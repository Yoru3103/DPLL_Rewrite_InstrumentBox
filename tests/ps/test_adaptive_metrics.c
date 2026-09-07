#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "AdaptiveMetrics.h"

static u32 regs[0x200];
static int tear, extensionReads;

u32 Xil_In32(u32 address)
{
	u32 word = address / 4U;
	assert(word < 0x200U);
	if (word >= 0x137 && word <= 0x141) ++extensionReads;
	if (word == 0x13AU && tear != 0) {
		++regs[0x120];
		/* The source publishes a new complete window halfway through the read. */
		regs[0x137] = 8; regs[0x138] = 0; regs[0x139] = 16;
		regs[0x13B] = 80; regs[0x13C] = 0;
		regs[0x13D] = 20; regs[0x13E] = 20;
		if (tear == 1) tear = 0;
	}
	return regs[word];
}

void Xil_Out32(u32 address, u32 value)
{
	assert(address / 4U < 0x200U);
	regs[address / 4U] = value;
}

static void set64(u32 word, u64 value)
{
	regs[word] = (u32)value;
	regs[word + 1] = (u32)(value >> 32);
}

static void fixture(void)
{
	memset(regs, 0, sizeof(regs));
	regs[0x60] = ADAPTIVE_PL_IF_INFO_VALUE;
	regs[0x136] = ADAPTIVE_PL_METRICS_INFO_VALUE;
	regs[0x120] = 1; regs[0x121] = 4; regs[0x12D] = 4;
	/* Frequency [-1,2,-3,4], phase [-5,6,-7,8]. */
	set64(0x137, 2); set64(0x139, 30); set64(0x13B, 2);
	regs[0x13D] = (u32)-5; regs[0x13E] = 8;
	regs[0x130] = 2; regs[0x131] = 2; regs[0x13F] = 3;
	regs[0x12E] = 2; regs[0x12F] = 2; regs[0x140] = 3;
	regs[0x141] = 0;
	tear = 0; extensionReads = 0;
}

static void near(double actual, double expected)
{
	assert(fabs(actual - expected) <= 1e-9 * fmax(1.0, fabs(expected)));
}

int main(void)
{
	AdaptivePlSnapshot s;
	AdaptiveWindowMetrics m;
	fixture();
	assert(AdaptivePl_ReadSnapshot(0, &s, 3) == ADAPTIVE_PL_OK);
	assert(s.metricsInfo == ADAPTIVE_PL_METRICS_INFO_VALUE);
	assert(s.frequencySignedSum == 2 && s.frequencySquareSum == 30);
	assert(s.phaseFirst == -5 && s.phaseLast == 8 && s.phaseSignedSum == 2);
	assert(s.residualBadSampleCount == 3 && s.railSampleCount == 3);
	assert(AdaptiveMetrics_Calculate(&s, 1000, &m) == ADAPTIVE_PL_OK);
	near(m.frequencyMean, 0.5); near(m.frequencyRms, sqrt(7.5));
	near(m.frequencyStd, sqrt(7.25)); near(m.phaseMean, 0.5);
	near(m.durationSeconds, .004); near(m.phaseSlopePerSecond, 13000.0/3.0);
	near(m.residualBadFraction, .75); near(m.railFraction, .75);
	assert(m.phaseSlopeValid);

	/* Large signed values, upper square-sum word, and exact constant-bias RMS. */
	regs[0x121] = 131072; regs[0x12D] = 131072;
	set64(0x137, (u64)(-(s64)8192 * 131072));
	set64(0x139, (u64)67108864 * 131072);
	set64(0x13B, (u64)(-(s64)2147483648LL * 131072));
	regs[0x141] = 131072;
	assert(AdaptivePl_ReadSnapshot(0, &s, 3) == ADAPTIVE_PL_OK);
	assert(s.frequencySignedSum == -(s64)8192 * 131072);
	assert(s.phaseSignedSum == -(s64)2147483648LL * 131072);
	assert(AdaptiveMetrics_Calculate(&s, 125000000, &m) == ADAPTIVE_PL_OK);
	near(m.frequencyMean, -8192); near(m.frequencyRms, 8192); near(m.frequencyStd, 0);
	assert(!m.phaseSlopeValid); near(m.phaseSaturatedFraction, 1);

	/* A torn extension read must retry the entire legacy + extended snapshot. */
	fixture(); tear = 1;
	assert(AdaptivePl_ReadSnapshot(0, &s, 3) == ADAPTIVE_PL_OK);
	assert(s.sequence == 2 && s.frequencySignedSum == 8 && s.phaseFirst == 20);
	assert(AdaptiveMetrics_Calculate(&s, 1000, &m) == ADAPTIVE_PL_OK);
	near(m.frequencyRms, 2); near(m.frequencyStd, 0);
	tear = 2;
	assert(AdaptivePl_ReadSnapshot(0, &s, 2) == ADAPTIVE_PL_INCONSISTENT_SNAPSHOT);
	assert(s.metricsInfo == 0);

	/* Missing/unknown capability clears prior optional fields and never reads them. */
	fixture(); regs[0x136] = 0;
	assert(AdaptivePl_ReadSnapshot(0, &s, 3) == ADAPTIVE_PL_OK);
	assert(s.metricsInfo == 0 && s.frequencySquareSum == 0 && extensionReads == 0);
	assert(AdaptiveMetrics_Calculate(&s, 1000, &m) == ADAPTIVE_PL_NOT_PRESENT);
	assert(m.frequencyRms == 0 && !m.phaseSlopeValid);
	regs[0x136] = 0xAD050002;
	assert(AdaptivePl_ReadSnapshot(0, &s, 3) == ADAPTIVE_PL_OK && !s.metricsInfo);
	assert(extensionReads == 0);

	fixture(); regs[0x120] = 0;
	assert(AdaptivePl_ReadSnapshot(0, &s, 2) == ADAPTIVE_PL_INCONSISTENT_SNAPSHOT);
	assert(AdaptivePl_ReadSnapshot(0, 0, 2) == ADAPTIVE_PL_INVALID_ARGUMENT);
	assert(AdaptivePl_ReadSnapshot(0, &s, 0) == ADAPTIVE_PL_INVALID_ARGUMENT);
	regs[0x60] = 0;
	assert(AdaptivePl_ReadSnapshot(0, &s, 2) == ADAPTIVE_PL_NOT_PRESENT);
	fixture(); assert(AdaptivePl_ReadSnapshot(0, &s, 3) == ADAPTIVE_PL_OK);
	s.lockedSampleCount = 3;
	assert(AdaptiveMetrics_Calculate(&s, 1000, &m) == ADAPTIVE_PL_OK && !m.phaseSlopeValid);
	s.sampleCount = 0;
	assert(AdaptiveMetrics_Calculate(&s, 1000, &m) == ADAPTIVE_PL_INVALID_ARGUMENT);
	s.sampleCount = 4; s.frequencySquareSum = 0;
	assert(AdaptiveMetrics_Calculate(&s, 1000, &m) == ADAPTIVE_PL_INVALID_ARGUMENT);
	s.frequencySquareSum = 30; s.residualBadSampleCount = 5;
	assert(AdaptiveMetrics_Calculate(&s, 1000, &m) == ADAPTIVE_PL_INVALID_ARGUMENT);
	assert(AdaptiveMetrics_Calculate(0, 1000, &m) == ADAPTIVE_PL_INVALID_ARGUMENT);
	assert(AdaptiveMetrics_Calculate(&s, 0, &m) == ADAPTIVE_PL_INVALID_ARGUMENT);
	assert(AdaptiveMetrics_Calculate(&s, 1000, 0) == ADAPTIVE_PL_INVALID_ARGUMENT);
	puts("PASS: adaptive metrics HAL and calculation self-check");
	return 0;
}
