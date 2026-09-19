#include "AutotuneEngine.h"
#include <math.h>
#include <string.h>
#include <limits.h>

static double maximum(double a, double b) { return a > b ? a : b; }
static double minimum(double a, double b) { return a < b ? a : b; }
static int same_profile(const AT_Profile *a, const AT_Profile *b)
{
    return a->kp==b->kp && a->ki==b->ki && a->kii==b->kii &&
        a->kd==b->kd && a->dCoeff==b->dCoeff;
}
static void state(AT_Engine *e, u8 value, u32 now)
{ e->state=value; e->stateStartMs=now; e->stable=0; }
static void report_context(AT_Engine *e, AT_Report *r)
{
    r->mode=e->mode; r->profile=e->current; r->repeat=e->repeat; r->runId=e->runId;
    r->parameters=e->profiles[e->current<AT_PROFILES ? e->current : 0];
    r->config=e->config; r->hardware=e->hardware;
    r->scaleF=e->scaleF; r->scaleP=e->scaleP; r->scaleD=e->scaleD; r->deadband=e->deadband;
    r->baselineMean=e->baselineMean; r->baselineSpread=e->baselineSpread;
    r->bestMean=e->bestMean; r->bestSpread=e->bestSpread;
    r->bestProfile=e->baselineReady ? e->best : 255;
}
static void report_summary(AT_Engine *e)
{
    e->report.baselineMean=e->baselineMean; e->report.baselineSpread=e->baselineSpread;
    e->report.bestMean=e->bestMean; e->report.bestSpread=e->bestSpread;
    e->report.bestProfile=e->baselineReady ? e->best : 255;
}
static void finish(AT_Engine *e, u8 result, u32 now)
{
    e->result=result; e->busy=0; e->endMs=now;
    e->done=(result==AT_SUCCESS || result==AT_NO_IMPROVEMENT);
    e->failed=(!e->done && result!=AT_CANCEL);
    e->paramsValid=e->done;
    e->lockValid=((e->io.status(e->io.user)&0x3FU)==0x30U);
    e->progress=e->done ? 100 : e->progress;
    state(e, e->done ? AT_DONE : (result==AT_CANCEL ? AT_CANCELED : AT_FAILED), now);
}
static void abort_run(AT_Engine *e, u8 result, u32 reason, u32 now)
{
    e->lastResult=result; e->rejectionReasons|=reason;
    if((e->state!=AT_BASELINE && e->state!=AT_EVALUATE && e->state!=AT_VERIFY) ||
       e->report.mode!=e->mode || e->report.profile!=e->current ||
       e->report.repeat!=(e->repeat<e->config.repeats ? e->repeat : e->config.repeats-1)) {
        memset(&e->report,0,sizeof(e->report)); report_context(e,&e->report);
    }
    e->report.reasons|=reason; e->report.valid=0;
    e->report.reportId=++e->reportCounter;
    if(e->saved && e->changed) state(e, AT_ROLLBACK, now);
    else finish(e,result,now);
}
void AT_DefaultConfig(AT_Config *c)
{ c->windowMs=1000; c->repeats=3; c->coveragePermille=800; c->amplitudeFloor=16; c->improvementPermille=30; }
int AT_ConfigValid(const AT_Config *c)
{
    /* Bound the worst normal scan to fit within the 120s transaction deadline. */
    return c && c->windowMs>=1000 && c->windowMs<=2000 && c->repeats>=2 &&
        c->repeats<=AT_REPEATS_MAX && c->windowMs*c->repeats<=6000 &&
        c->coveragePermille>=800 && c->coveragePermille<=1000 &&
        c->amplitudeFloor>=1 && c->amplitudeFloor<=65535 &&
        c->improvementPermille>=1 && c->improvementPermille<=500;
}
void AT_Init(AT_Engine *e, const AT_Hardware *h, const AT_IO *io)
{
    memset(e,0,sizeof(*e)); e->hardware=*h; e->io=*io;
    AT_DefaultConfig(&e->config); e->best=255; e->current=255;
    e->scaleF=1; e->scaleP=1024; e->scaleD=1; e->deadband=1;
}
int AT_Start(AT_Engine *e, u32 now)
{
    AT_Config c=e->config; AT_Hardware h=e->hardware; AT_IO io=e->io;
    u8 run=e->runId+1U; u32 report=e->reportCounter;
    if(e->busy) return AT_BUSY;
    if(!AT_ConfigValid(&c) || !io.readProfile || !io.apply || !io.snapshot || !io.status ||
       !h.clockHz || h.clockHz>1000000000U || h.windowSamples<2 ||
       h.windowSamples>0x80000000U || h.settleMs>2500 || h.outputLow>=h.outputHigh ||
       (u64)h.windowSamples*400000U>(u64)h.clockHz*c.windowMs)
        return AT_BAD_CONFIG;
    AT_Init(e,&h,&io); e->config=c; e->runId=run ? run : 1U; e->reportCounter=report;
    e->runStartMs=now; e->lastTickMs=now-1U; e->busy=1; e->result=AT_ACCEPTED;
    e->current=0; e->candidate=1; e->best=0; e->progress=1;
    report_context(e,&e->report); state(e,AT_PRECHECK,now); return AT_ACCEPTED;
}
void AT_Cancel(AT_Engine *e) { if(e->busy) e->cancel=1; }
void AT_Invalidate(AT_Engine *e)
{ if(!e->busy) { e->paramsValid=0; e->lockValid=0; e->current=255; } }
void AT_Clear(AT_Engine *e)
{
    if(!e->busy) {
        AT_Config c=e->config; AT_Hardware h=e->hardware; AT_IO io=e->io;
        u8 run=e->runId; u32 count=e->reportCounter;
        AT_Init(e,&h,&io); e->config=c; e->runId=run; e->reportCounter=count;
    }
}
void AT_BeginWindow(AT_Engine *e, u32 now)
{
    memset(&e->acc,0,sizeof(e->acc));
    e->acc.ampMin=65535; e->acc.outputMin=INT32_MAX; e->acc.outputMax=INT32_MIN;
    e->acc.startMs=now; e->acc.lastFreshMs=now; e->acc.discard=2;
}
static int invalid_snapshot(const AT_Engine *e, const AdaptivePlSnapshot *s)
{
    u32 n=s->sampleCount;
    if(s->metricsInfo!=ADAPTIVE_PL_METRICS_INFO_VALUE || n!=e->hardware.windowSamples ||
       s->lossOfLockEventCount==UINT32_MAX || s->positiveRailEventCount==UINT32_MAX ||
       s->negativeRailEventCount==UINT32_MAX || s->commitErrorCount==UINT32_MAX)
        return 1;
    if(s->amplitudeMin>s->amplitudeMax || s->amplitudeSum>(u64)n*s->amplitudeMax ||
       s->amplitudeSum<(u64)n*s->amplitudeMin || s->outputMin>s->outputMax ||
       s->frequencyAbsMax>8192 || s->frequencyAbsSum>(u64)n*s->frequencyAbsMax ||
       s->phaseAbsMax>0x7fffffffU || s->phaseAbsSum>(u64)n*s->phaseAbsMax)
        return 1;
    if(s->positiveRailSampleCount>n || s->negativeRailSampleCount>n ||
       s->frequencyBadSampleCount>n || s->phaseBadSampleCount>n ||
       s->residualBadSampleCount<maximum(s->frequencyBadSampleCount,s->phaseBadSampleCount) ||
       (u64)s->residualBadSampleCount>(u64)s->frequencyBadSampleCount+s->phaseBadSampleCount ||
       s->railSampleCount<maximum(s->positiveRailSampleCount,s->negativeRailSampleCount) ||
       (u64)s->railSampleCount>(u64)s->positiveRailSampleCount+s->negativeRailSampleCount)
        return 1;
    /* Legacy absolute values clip -8192 to 8191 and INT32_MIN to INT32_MAX.
     * There is no frequency clipping counter, so allow up to N missing units
     * only when the reported peak reaches 8191. Exact signed/squared moments
     * remain checked independently by AdaptiveMetrics_Calculate. */
    if(fabs((double)s->frequencySignedSum)>(double)s->frequencyAbsSum+
            (s->frequencyAbsMax==8191U ? n : 0U) ||
       (double)s->phaseAbsSum+s->phaseSaturatedSampleCount<fabs((double)s->phaseSignedSum) ||
       s->frequencySquareSum>(s->frequencyAbsMax==8191U ?
            (s->frequencyAbsSum+n)*8192ULL : s->frequencyAbsSum*s->frequencyAbsMax) ||
       (double)s->frequencyAbsSum*(double)s->frequencyAbsSum>(double)n*s->frequencySquareSum+.5 ||
       (s->phaseSaturatedSampleCount==0 &&
        (fabs((double)s->phaseFirst)>s->phaseAbsMax || fabs((double)s->phaseLast)>s->phaseAbsMax)))
        return 1;
    return 0;
}
int AT_AddSnapshot(AT_Engine *e, const AdaptivePlSnapshot *s, u32 now)
{
    AT_Accumulator *a=&e->acc; AdaptiveWindowMetrics m; u32 delta; int sign;
    if(!s) { a->reasons|=AT_R_DATA; return -1; }
    if(invalid_snapshot(e,s) || AdaptiveMetrics_Calculate(s,e->hardware.clockHz,&m)!=ADAPTIVE_PL_OK)
        { a->reasons|=AT_R_DATA; return -1; }
    if(a->anchored) {
        delta=s->sequence-a->lastSeq;
        if(delta==0) return 0;
        if(delta>=0x80000000U) { a->reasons|=AT_R_DATA; return -1; }
    } else delta=1;
    a->lastFreshMs=now;
    if(a->discard) {
        a->anchored=1; a->lastSeq=s->sequence; --a->discard;
        a->lossStart=a->lossLast=s->lossOfLockEventCount;
        a->posStart=a->posLast=s->positiveRailEventCount;
        a->negStart=a->negLast=s->negativeRailEventCount;
        if(a->discard==0 && a->commitStart!=s->commitErrorCount) {
            a->reasons|=AT_R_DATA|AT_R_EVENTS; a->commitLast=s->commitErrorCount; return -1;
        }
        a->commitStart=a->commitLast=s->commitErrorCount;
        a->startMs=now;
        return 0;
    }
    a->commitLast=s->commitErrorCount;
    if(s->lossOfLockEventCount<a->lossLast || s->positiveRailEventCount<a->posLast ||
       s->negativeRailEventCount<a->negLast || s->lossOfLockEventCount==UINT32_MAX ||
       s->positiveRailEventCount==UINT32_MAX || s->negativeRailEventCount==UINT32_MAX ||
       s->commitErrorCount!=a->commitStart)
        { a->reasons|=AT_R_DATA|AT_R_EVENTS; return -1; }
    a->lossLast=s->lossOfLockEventCount; a->posLast=s->positiveRailEventCount;
    a->negLast=s->negativeRailEventCount;
    /* A corrupt source must not overflow moment accumulators before the final
     * coverage check. A valid run has at most 2.1e9 observed samples here. */
    if(a->samples+s->sampleCount>(u64)e->hardware.clockHz*(e->config.windowMs+100U)/1000U ||
       delta-1>UINT32_MAX-a->missing) {
        a->reasons|=AT_R_DATA; return -1;
    }
    if(!a->windows) a->firstSeq=s->sequence;
    a->lastSeq=s->sequence; a->missing+=delta-1; a->windows++;
    a->samples+=s->sampleCount; a->freqSq+=s->frequencySquareSum;
    a->freqSum+=s->frequencySignedSum; a->phaseSum+=s->phaseSignedSum;
    a->freqAbs+=s->frequencyAbsSum; a->phaseAbs+=s->phaseAbsSum; a->amplitude+=s->amplitudeSum;
    a->locked+=s->lockedSampleCount; a->bad+=s->residualBadSampleCount;
    a->rail+=s->railSampleCount; a->sat+=s->phaseSaturatedSampleCount;
    a->frequencyBad+=s->frequencyBadSampleCount; a->phaseBad+=s->phaseBadSampleCount;
    a->ampMin=(u32)minimum(a->ampMin,s->amplitudeMin);
    a->ampMax=(u32)maximum(a->ampMax,s->amplitudeMax);
    a->freqPeak=(u32)maximum(a->freqPeak,s->frequencyAbsMax);
    a->phasePeak=(u32)maximum(a->phasePeak,s->phaseAbsMax);
    if(s->outputMin<a->outputMin) a->outputMin=s->outputMin;
    if(s->outputMax>a->outputMax) a->outputMax=s->outputMax;
    a->windowAbsSum+=fabs(m.frequencyMean);
    if(m.phaseSlopeValid) {
        a->slopeSamples+=s->sampleCount;
        a->absSlopeSum+=fabs(m.phaseSlopePerSecond)*s->sampleCount;
    }
    sign=m.frequencyMean>e->deadband ? 1 : (m.frequencyMean<-e->deadband ? -1 : 0);
    if(!m.phaseSlopeValid) sign=0;
    if(delta==1 && sign && a->previousSign) {
        ++a->pairs; if(sign!=a->previousSign) ++a->flips;
    }
    a->previousSign=sign;
    if(s->railSampleCount || a->posLast!=a->posStart || a->negLast!=a->negStart)
        a->reasons|=AT_R_RAIL;
    if(s->phaseSaturatedSampleCount) a->reasons|=AT_R_PHASE_SAT;
    if(s->outputMin<e->hardware.outputLow || s->outputMax>e->hardware.outputHigh)
        a->reasons|=AT_R_OUTPUT;
    /* Immediate safety rejection; partial samples remain available in the report. */
    return a->reasons ? -2 : 1;
}
double AT_Score(const AT_Engine *e, const AT_Report *r)
{
    double span=(double)e->hardware.outputHigh-e->hardware.outputLow;
    return r->frequencyRms/e->scaleF + .05*r->frequencyMae/e->scaleF +
        .05*r->frequencyPeak/e->scaleF +
        .20*fabs(r->phaseMean+e->hardware.phaseOffset)/e->scaleP +
        .10*r->phaseMae/e->scaleP + .05*r->phasePeak/e->scaleP +
        .10*r->slope/(e->hardware.clockHz*e->scaleD) +
        .05*r->flipRate*r->windowAbsMean/e->scaleF +
        .05*((double)r->outputMax-r->outputMin)/span +
        .05*(1-r->outputHeadroom) + 2*(1-r->lockFraction)+r->residualFraction;
}
void AT_FinishWindow(AT_Engine *e, u32 now, AT_Report *r)
{
    AT_Accumulator *a=&e->acc; double n=(double)a->samples, variance, head, span;
    memset(r,0,sizeof(*r)); r->reasons=a->reasons;
    r->reportId=++e->reportCounter; r->mode=e->mode; r->profile=e->current;
    r->repeat=e->repeat; r->elapsedMs=now-a->startMs;
    r->windows=a->windows; r->missing=a->missing; r->pairs=a->pairs; r->flips=a->flips;
    r->readErrors=a->readErrors; r->samples=a->samples; r->firstSeq=a->firstSeq; r->lastSeq=a->lastSeq;
    r->lossEvents=a->lossLast-a->lossStart; r->posEvents=a->posLast-a->posStart;
    r->negEvents=a->negLast-a->negStart; r->commitErrors=a->commitLast-a->commitStart;
    r->amplitudeMin=a->ampMin; r->amplitudeMax=a->ampMax;
    r->outputMin=a->outputMin; r->outputMax=a->outputMax;
    report_context(e,r);
    if(!n || !r->elapsedMs) {
        r->amplitudeMin=0; r->outputMin=r->outputMax=0;
        r->reasons|=AT_R_DATA; return;
    }
    r->frequencyMean=(double)a->freqSum/n;
    r->frequencyRms=sqrt((double)a->freqSq/n);
    variance=(double)a->freqSq/n-r->frequencyMean*r->frequencyMean;
    r->frequencyStd=sqrt(maximum(0,variance));
    r->frequencyMae=(double)a->freqAbs/n; r->frequencyPeak=a->freqPeak;
    r->phaseMean=(double)a->phaseSum/n; r->phaseMae=(double)a->phaseAbs/n; r->phasePeak=a->phasePeak;
    r->slope=a->slopeSamples ? a->absSlopeSum/(double)a->slopeSamples : 0;
    r->slopeFraction=(double)a->slopeSamples/n;
    r->flipRate=a->pairs ? (double)a->flips/a->pairs : 0;
    r->windowAbsMean=a->windowAbsSum/a->windows;
    r->amplitudeMean=(double)a->amplitude/n;
    r->coverage=n*1000.0/(e->hardware.clockHz*(double)r->elapsedMs);
    r->lockFraction=(double)a->locked/n; r->residualFraction=(double)a->bad/n;
    r->railFraction=(double)a->rail/n; r->phaseSatFraction=(double)a->sat/n;
    r->frequencyBadFraction=(double)a->frequencyBad/n; r->phaseBadFraction=(double)a->phaseBad/n;
    span=(double)e->hardware.outputHigh-e->hardware.outputLow;
    head=2*minimum((double)a->outputMin-e->hardware.outputLow,(double)e->hardware.outputHigh-a->outputMax)/span;
    r->outputHeadroom=maximum(0,minimum(1,head));
    if(a->windows<400 || r->coverage*1000+1e-6<e->config.coveragePermille || r->coverage>1.05)
        r->reasons|=AT_R_COVERAGE;
    /* The sequence includes missed windows. More source time than elapsed
     * time indicates a source reset/jump or an incorrect sample clock. */
    if(((double)a->windows+a->missing)*e->hardware.windowSamples*1000.0>
       e->hardware.clockHz*(double)r->elapsedMs*1.05+2.0*e->hardware.windowSamples*1000.0)
        r->reasons|=AT_R_DATA;
    if(r->amplitudeMean<e->config.amplitudeFloor ||
       (e->baselineAmplitude>0 && (r->amplitudeMean<.5*e->baselineAmplitude || r->amplitudeMean>2*e->baselineAmplitude)))
        r->reasons|=AT_R_SIGNAL;
    if(r->lockFraction<.95 || r->slopeFraction<.95) r->reasons|=AT_R_LOCK;
    if(r->residualFraction>.05) r->reasons|=AT_R_RESIDUAL;
    if(r->lossEvents>2) r->reasons|=AT_R_EVENTS;
    if(r->posEvents || r->negEvents || a->rail) r->reasons|=AT_R_RAIL;
    if(a->sat) r->reasons|=AT_R_PHASE_SAT;
    r->score=AT_Score(e,r);
    r->valid=(r->reasons==0 ? 1U : 0U) | (a->pairs ? 2U : 0U) |
             (r->slopeFraction>=.95 ? 4U : 0U);
}
static void schedule(AT_Engine *e, u8 mode, u8 profile, u32 now)
{
    e->mode=mode; e->current=profile; e->repeat=0;
    memset(e->rounds,0,sizeof(e->rounds));
    state(e,mode==AT_MODE_VERIFY ? AT_APPLY_BEST : AT_APPLY,now);
}
static void candidate_rejected(AT_Engine *e, u32 now)
{
    e->rejectionReasons|=e->report.reasons;
    /* Every rejected candidate is recovered through ORIGINAL before continuing. */
    schedule(e,AT_MODE_CONTROL,0,now);
}
static double threshold(const AT_Engine *e, double spread)
{
    return maximum(.02, maximum(e->config.improvementPermille*.001*e->bestMean,
           maximum(2*e->baselineSpread,maximum(spread,e->bestSpread))));
}
static void rounds_done(AT_Engine *e, u32 now)
{
    u32 i; double mean=0, low=1e100, high=0, spread, margin;
    if(e->mode==AT_MODE_CALIBRATE) {
        double f=0,p=0,phaseMean=0,d=0,amp=0;
        for(i=0;i<e->config.repeats;++i) {
            f+=e->rounds[i].frequencyRms;
            p+=e->rounds[i].phaseMae; phaseMean+=e->rounds[i].phaseMean;
            d+=e->rounds[i].slope/e->hardware.clockHz;
            amp+=e->rounds[i].amplitudeMean;
        }
        e->scaleF=maximum(1,f/e->config.repeats);
        e->scaleP=maximum(1024,maximum(p/e->config.repeats,
            fabs(phaseMean/e->config.repeats+e->hardware.phaseOffset)));
        e->scaleD=maximum(1,d/e->config.repeats);
        e->deadband=maximum(1,.1*f/e->config.repeats);
        e->baselineAmplitude=amp/e->config.repeats;
        /* Baseline is acquired again using these frozen scales and deadband;
         * recalculating the calibration score cannot recreate sign pairs. */
        schedule(e,AT_MODE_BASE,0,now); return;
    }
    for(i=0;i<e->config.repeats;++i) {
        double score=e->rounds[i].score;
        mean+=score; low=minimum(low,score); high=maximum(high,score);
    }
    mean/=e->config.repeats; spread=high-low;
    /* Keep the score and metrics from the same last window. Group statistics
     * are separate, so every diagnostic score remains independently reproducible. */
    e->report.groupMean=mean; e->report.groupSpread=spread;
    e->report.groupSize=e->config.repeats;
    e->report.reportId=++e->reportCounter;
    switch(e->mode) {
    case AT_MODE_BASE:
        e->baselineMean=e->bestMean=mean; e->baselineSpread=e->bestSpread=spread;
        e->bestMin=low; e->best=0; e->baselineReady=1;
        report_summary(e);
        schedule(e,AT_MODE_CANDIDATE,e->candidate,now); break;
    case AT_MODE_CANDIDATE:
        margin=threshold(e,spread);
        /* Identical parameters still complete their measurement/control rounds,
         * but time variation cannot certify a change or lower the best threshold. */
        if(!same_profile(&e->profiles[e->candidate],&e->profiles[0]) &&
           e->bestMean-mean>margin && high<e->bestMin) {
            e->best=e->candidate; e->bestMean=mean; e->bestSpread=spread; e->bestMin=low;
        }
        report_summary(e);
        schedule(e,AT_MODE_CONTROL,0,now); break;
    case AT_MODE_CONTROL:
        if(fabs(mean-e->baselineMean)>maximum(.1,maximum(.25*e->baselineMean,3*e->baselineSpread))) {
            abort_run(e,AT_INPUT_CHANGED,AT_R_DRIFT,now); break;
        }
        if(++e->candidate<AT_PROFILES) schedule(e,AT_MODE_CANDIDATE,e->candidate,now);
        else schedule(e,AT_MODE_VERIFY,e->best,now);
        break;
    case AT_MODE_VERIFY:
        if(!e->lockValid) {
            abort_run(e,AT_VERIFY_FAILED,AT_R_VERIFY|AT_R_LOCK,now); break;
        }
        margin=maximum(.02,maximum(.2*e->bestMean,maximum(2*e->bestSpread,2*e->baselineSpread)));
        if(mean>e->bestMean+margin ||
           (e->best!=0 && e->baselineMean-mean<=maximum(.02,e->config.improvementPermille*.001*e->baselineMean))) {
            abort_run(e,AT_VERIFY_FAILED,AT_R_VERIFY,now); break;
        }
        finish(e,e->best==0 ? AT_NO_IMPROVEMENT : AT_SUCCESS,now); break;
    default: abort_run(e,AT_DATA_ERROR,AT_R_DATA,now); break;
    }
}
void AT_Tick(AT_Engine *e, u32 now)
{
    AdaptivePlSnapshot s; u32 status,elapsed,i; int rc;
    if(!e->busy) {
        if(e->paramsValid) e->lockValid=((e->io.status(e->io.user)&0x3FU)==0x30U);
        return;
    }
    if(now==e->lastTickMs) return;
    e->lastTickMs=now;
    if(e->cancel && e->mode!=AT_MODE_RESTORE && e->state!=AT_ROLLBACK) {
        abort_run(e,AT_CANCEL,AT_R_CANCEL,now); return;
    }
    if(now-e->runStartMs>120000 && e->mode!=AT_MODE_RESTORE && e->state!=AT_ROLLBACK) {
        abort_run(e,AT_TIMEOUT,AT_R_TIMEOUT,now); return;
    }
    status=e->io.status(e->io.user);
    e->lockValid=((status&0x3FU)==0x30U);
    switch(e->state) {
    case AT_PRECHECK:
        rc=e->io.snapshot(e->io.user,&s);
        if(rc==ADAPTIVE_PL_OK && s.metricsInfo!=ADAPTIVE_PL_METRICS_INFO_VALUE) {
            abort_run(e,AT_UNSUPPORTED,AT_R_UNSUPPORTED,now); break;
        }
        if(rc==ADAPTIVE_PL_NOT_PRESENT) { abort_run(e,AT_UNSUPPORTED,AT_R_UNSUPPORTED,now); break; }
        if(rc!=ADAPTIVE_PL_OK) {
            if(now-e->stateStartMs>250) abort_run(e,AT_DATA_ERROR,AT_R_DATA,now);
            break;
        }
        if(!e->lockValid) { abort_run(e,AT_NOT_LOCKED,AT_R_LOCK,now); break; }
        {
            AdaptiveWindowMetrics metrics;
            if(invalid_snapshot(e,&s) || AdaptiveMetrics_Calculate(&s,e->hardware.clockHz,&metrics)!=ADAPTIVE_PL_OK) {
                abort_run(e,AT_DATA_ERROR,AT_R_DATA,now); break;
            }
        }
        if(!e->io.readProfile(e->io.user,&e->profiles[0])) {
            abort_run(e,AT_READBACK_ERROR,AT_R_IO,now); break;
        }
        e->saved=1;
        for(i=1;i<AT_PROFILES;++i) {
            static const u32 fkp[4]={0x200000,0x200000,0x300000,0x400000};
            static const u32 fki[4]={0x40000,0x80000,0xc0000,0x100000};
            static const u32 dkp[4]={550000,550000,825000,1100000};
            static const u32 dki[4]={250000,500000,750000,1000000};
            e->profiles[i]=e->profiles[0];
            e->profiles[i].kp=(e->hardware.clockHz==125000000U ? fkp[i-1] : dkp[i-1]);
            e->profiles[i].ki=(e->hardware.clockHz==125000000U ? fki[i-1] : dki[i-1]);
        }
        schedule(e,AT_MODE_CALIBRATE,0,now); break;
    case AT_APPLY:
    case AT_APPLY_BEST:
        e->changed=1;
        if(!e->io.apply(e->io.user,&e->profiles[e->current],e->current)) {
            abort_run(e,AT_READBACK_ERROR,AT_R_IO,now); break;
        }
        state(e,AT_SETTLE,now); break;
    case AT_ROLLBACK:
        e->paramsValid=0;
        if(!e->io.apply(e->io.user,&e->profiles[0],0)) {
            e->report.reasons|=AT_R_IO; e->report.valid=0;
            e->report.reportId=++e->reportCounter;
            finish(e,AT_ROLLBACK_FAILED,now); break;
        }
        e->current=0; e->mode=AT_MODE_RESTORE;
        state(e,AT_SETTLE,now); break;
    case AT_SETTLE:
        elapsed=now-e->stateStartMs;
        if(e->lockValid) { if(!e->stable) { e->stable=1; e->stableSinceMs=now; } }
        else e->stable=0;
        if(elapsed>=e->hardware.settleMs && e->stable && now-e->stableSinceMs>=50) {
            if(e->mode==AT_MODE_RESTORE) { finish(e,e->lastResult,now); break; }
            AT_BeginWindow(e,now);
            state(e,(e->mode==AT_MODE_BASE || e->mode==AT_MODE_CALIBRATE) ? AT_BASELINE :
                (e->mode==AT_MODE_VERIFY ? AT_VERIFY : AT_EVALUATE),now);
        } else if(elapsed>=3000) {
            if(e->mode==AT_MODE_RESTORE) {
                e->report.reasons|=AT_R_LOCK; e->report.valid=0;
                e->report.reportId=++e->reportCounter;
                finish(e,AT_ROLLBACK_FAILED,now);
            }
            else if(e->mode==AT_MODE_CANDIDATE) {
                memset(&e->report,0,sizeof(e->report));
                report_context(e,&e->report); e->report.reportId=++e->reportCounter;
                e->report.reasons=AT_R_LOCK; candidate_rejected(e,now);
            } else abort_run(e,AT_NOT_LOCKED,AT_R_LOCK,now);
        }
        break;
    case AT_BASELINE:
    case AT_EVALUATE:
    case AT_VERIFY:
        rc=e->io.snapshot(e->io.user,&s);
        if(rc==ADAPTIVE_PL_NOT_PRESENT) {
            AT_FinishWindow(e,now,&e->report);
            abort_run(e,AT_UNSUPPORTED,AT_R_UNSUPPORTED,now); break;
        }
        if(rc!=ADAPTIVE_PL_OK) ++e->acc.readErrors;
        else {
            rc=AT_AddSnapshot(e,&s,now);
            if(rc<0) {
                AT_FinishWindow(e,now,&e->report);
                if(rc==-2 && e->mode==AT_MODE_CANDIDATE) candidate_rejected(e,now);
                else abort_run(e,rc==-1 ? AT_DATA_ERROR : AT_NOT_LOCKED,e->report.reasons,now);
                break;
            }
        }
        if(now-e->acc.lastFreshMs>100) {
            AT_FinishWindow(e,now,&e->report);
            abort_run(e,AT_DATA_ERROR,AT_R_DATA,now); break;
        }
        if(!e->acc.discard && now-e->acc.startMs>=e->config.windowMs) {
            AT_FinishWindow(e,now,&e->report);
            if(e->report.reasons) {
                if(e->report.reasons&(AT_R_DATA|AT_R_COVERAGE)) abort_run(e,AT_DATA_ERROR,e->report.reasons,now);
                else if(e->report.reasons&AT_R_SIGNAL) abort_run(e,AT_INPUT_CHANGED,e->report.reasons,now);
                else if(e->mode==AT_MODE_CANDIDATE) candidate_rejected(e,now);
                else abort_run(e,AT_NOT_LOCKED,e->report.reasons,now);
                break;
            }
            e->rounds[e->repeat]=e->report; ++e->repeat; ++e->completed;
            e->progress=(u8)minimum(98,3+94.0*e->completed/(11*e->config.repeats));
            if(e->repeat<e->config.repeats) AT_BeginWindow(e,now);
            else rounds_done(e,now);
        }
        break;
    default: abort_run(e,AT_DATA_ERROR,AT_R_DATA,now); break;
    }
}

/* Explicit little-endian serialization, never transmit compiler struct layout. */
static void put32(u8 *p,u32 v) { p[0]=(u8)v; p[1]=(u8)(v>>8); p[2]=(u8)(v>>16); p[3]=(u8)(v>>24); }
static void put_float(u8 *p,double d) { float f=(float)d; u32 v; memcpy(&v,&f,4); put32(p,v); }
int AT_DiagnosticPage(AT_Engine *e,u8 page,u8 *p)
{
    AT_Report *r; u32 v[8]={0}; double f[8]={0}; int floating=0; unsigned i;
    if(!p || page>=AT_REPORT_PAGES) return 0;
    if(page==0) { e->frozen=e->report; e->frozenValid=1; }
    if(!e->frozenValid) return 0;
    r=&e->frozen;
    memset(p,0,44); p[0]=2; p[1]=5; p[2]=page; p[3]=r->runId;
    put32(p+4,r->reportId); p[8]=r->mode; p[9]=r->profile; p[10]=r->repeat; p[11]=r->valid;
    switch(page) {
    case 0:
        v[0]=r->reasons; v[1]=r->windows; v[2]=r->missing; v[3]=r->pairs;
        v[4]=r->flips; v[5]=r->readErrors; v[6]=r->elapsedMs; v[7]=(u32)r->samples; break;
    case 1:
        v[0]=(u32)(r->samples>>32); v[1]=r->firstSeq; v[2]=r->lastSeq; v[3]=r->lossEvents;
        v[4]=r->posEvents; v[5]=r->negEvents; v[6]=r->commitErrors; v[7]=r->amplitudeMin; break;
    case 2:
        floating=1; f[0]=r->frequencyMean; f[1]=r->frequencyRms; f[2]=r->frequencyStd;
        f[3]=r->frequencyMae; f[4]=r->frequencyPeak; f[5]=r->phaseMean; f[6]=r->phaseMae; f[7]=r->phasePeak; break;
    case 3:
        floating=1; f[0]=r->slope; f[1]=r->slopeFraction; f[2]=r->flipRate; f[3]=r->windowAbsMean;
        f[4]=r->amplitudeMean; f[5]=r->coverage; f[6]=r->lockFraction; f[7]=r->residualFraction; break;
    case 4:
        floating=1; f[0]=r->railFraction; f[1]=r->phaseSatFraction; f[2]=r->outputHeadroom; f[3]=r->score;
        f[4]=r->frequencyBadFraction; f[5]=r->phaseBadFraction; f[6]=r->scaleF; f[7]=r->scaleP; break;
    case 5:
        v[0]=r->amplitudeMax; v[1]=(u32)r->outputMin; v[2]=(u32)r->outputMax;
        v[3]=r->parameters.kp; v[4]=r->parameters.ki; v[5]=r->parameters.kii;
        v[6]=r->parameters.kd; v[7]=r->parameters.dCoeff; break;
    case 6:
        floating=1; f[0]=r->scaleD; f[1]=r->deadband;
        f[2]=r->groupMean; f[3]=r->groupSpread; f[4]=r->baselineMean; f[5]=r->baselineSpread;
        f[6]=r->bestMean; f[7]=r->bestSpread; break;
    case 7:
        v[0]=r->config.windowMs; v[1]=r->config.repeats; v[2]=r->config.coveragePermille;
        v[3]=r->config.amplitudeFloor; v[4]=r->config.improvementPermille;
        v[5]=r->hardware.clockHz; v[6]=r->hardware.windowSamples; v[7]=r->hardware.settleMs; break;
    case 8:
        v[0]=(u32)r->hardware.phaseOffset; v[1]=(u32)r->hardware.outputLow;
        v[2]=(u32)r->hardware.outputHigh; v[3]=r->groupSize; v[4]=r->bestProfile; break;
    }
    for(i=0;i<8;++i) { if(floating) put_float(p+12+4*i,f[i]); else put32(p+12+4*i,v[i]); }
    return 44;
}
