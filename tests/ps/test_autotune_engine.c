#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "AutotuneEngine.h"

enum { IMPROVE, SAME, DRIFT, VERIFY_BAD, RAIL_CANDIDATE, BAD_DATA,
       NO_DATA, UNSUPPORTED, BAD_APPLY, BAD_ROLLBACK, BAD_READ, NO_LOCK,
       LOCK_RESTORE_FAIL, NOISY, SIGNAL_CHANGE, MID_UNSUPPORTED, DROP_WINDOWS,
       LOSS_EVENTS, COMMIT_ERROR, COUNTER_RESET, LOCK_CANDIDATE, SLOW_READER, VERIFY_LAST_UNLOCK, CAL_PHASE, IDENTICAL_PROFILE };
typedef struct {
    AT_Engine *engine;
    AT_Profile active, original;
    u32 sequence, applies, snapshots, counts[6], now, epoch;
    int scenario, realCadence;
} Fixture;

static void near(double a, double b)
{ assert(fabs(a-b)<1e-8*fmax(1,fabs(b))); }
static AdaptivePlSnapshot sample(u32 seq, int frequency)
{
    AdaptivePlSnapshot s; u32 f=(u32)(frequency<0 ? -frequency : frequency);
    memset(&s,0,sizeof(s)); s.sequence=seq; s.sampleCount=1000;
    s.metricsInfo=ADAPTIVE_PL_METRICS_INFO_VALUE;
    s.amplitudeMin=90; s.amplitudeMax=110; s.amplitudeSum=100000;
    s.frequencyAbsMax=f; s.frequencyAbsSum=1000ULL*f;
    s.frequencySignedSum=1000LL*frequency; s.frequencySquareSum=1000ULL*f*f;
    s.phaseAbsMax=80; s.phaseAbsSum=80000; s.phaseSignedSum=80000;
    s.phaseFirst=s.phaseLast=80; s.lockedSampleCount=1000;
    s.outputMin=-100; s.outputMax=100; return s;
}
static int read_profile(void *arg, AT_Profile *p)
{
    Fixture *f=arg; if(f->scenario==BAD_READ) return 0;
    *p=f->active; return 1;
}
static int apply(void *arg, const AT_Profile *p, u8 profile)
{
    Fixture *f=arg; AT_Engine *e=f->engine; ++f->applies;
    assert(p->kii==f->original.kii && p->kd==f->original.kd && p->dCoeff==f->original.dCoeff);
    assert(profile<AT_PROFILES);
    if(f->scenario==BAD_ROLLBACK && e->state==AT_ROLLBACK) return 0;
    if(f->scenario==BAD_APPLY && e->mode==AT_MODE_CANDIDATE && e->state!=AT_ROLLBACK) return 0;
    f->active=*p; return 1;
}
static u32 status(void *arg)
{
    Fixture *f=arg; AT_Engine *e=f->engine;
    if((f->scenario==VERIFY_LAST_UNLOCK && e->mode==AT_MODE_VERIFY &&
        e->repeat==e->config.repeats-1 && e->acc.windows>=999) ||
       f->scenario==NO_LOCK || (f->scenario==LOCK_RESTORE_FAIL && e->mode==AT_MODE_RESTORE) ||
       (f->scenario==LOCK_CANDIDATE && e->mode==AT_MODE_CANDIDATE && e->current==1)) return 0;
    return 0x30;
}
static int snapshot(void *arg, AdaptivePlSnapshot *s)
{
    Fixture *f=arg; AT_Engine *e=f->engine; int freq=100;
    static const int improved[]={100,80,60,70,90};
    ++f->snapshots;
    if(f->scenario==UNSUPPORTED || (f->scenario==MID_UNSUPPORTED && e->mode==AT_MODE_CANDIDATE))
        return ADAPTIVE_PL_NOT_PRESENT;
    if(f->scenario==NO_DATA && e->state!=AT_PRECHECK) return ADAPTIVE_PL_INCONSISTENT_SNAPSHOT;
    if(f->scenario==SLOW_READER && e->state!=AT_PRECHECK && (f->snapshots%2)==0)
        return ADAPTIVE_PL_INCONSISTENT_SNAPSHOT;
    if(e->mode==AT_MODE_CANDIDATE || e->mode==AT_MODE_VERIFY) {
        if(f->scenario!=SAME && f->scenario!=NOISY) freq=improved[e->current];
        if(f->scenario==IDENTICAL_PROFILE) freq=e->current==4 ? 60 : 100;
        if(f->scenario==NOISY && e->mode==AT_MODE_CANDIDATE) {
            const int noise[]={80,90,99,90,90}; freq=noise[e->repeat];
        }
    }
    if(f->scenario==DRIFT && e->mode==AT_MODE_CONTROL) freq=150;
    if(f->scenario==VERIFY_BAD && e->mode==AT_MODE_VERIFY) freq=150;
    if(f->realCadence) {
        f->sequence=(u32)((u64)(f->now-f->epoch)*e->hardware.clockHz /
            ((u64)e->hardware.windowSamples*1000U))+1U;
    } else if(++f->sequence==0) ++f->sequence;
    if(f->scenario==DROP_WINDOWS && (f->snapshots%4)==0) ++f->sequence;
    *s=sample(f->sequence,freq);
    if(f->realCadence) {
        u32 n=e->hardware.windowSamples;
        s->sampleCount=s->lockedSampleCount=n;
        s->amplitudeSum=100ULL*n; s->frequencyAbsSum=(u64)freq*n;
        s->frequencySignedSum=(s64)freq*n; s->frequencySquareSum=(u64)freq*freq*n;
        s->phaseAbsSum=80ULL*n; s->phaseSignedSum=80LL*n;
    }
    if(f->scenario==CAL_PHASE) {
        const s32 phases[]={-2000,2000,0,0,0}; s32 phase=phases[e->repeat];
        s->phaseFirst=s->phaseLast=phase; s->phaseSignedSum=(s64)phase*1000;
        s->phaseAbsMax=phase<0 ? (u32)-phase : (u32)phase;
        s->phaseAbsSum=(u64)s->phaseAbsMax*1000;
    }
    if(f->scenario==BAD_DATA) s->lockedSampleCount=1001;
    if(f->scenario==RAIL_CANDIDATE && e->mode==AT_MODE_CANDIDATE && e->current==1)
        s->railSampleCount=s->positiveRailSampleCount=1;
    if(f->scenario==SIGNAL_CHANGE && e->mode==AT_MODE_CANDIDATE) {
        s->amplitudeMin=s->amplitudeMax=10; s->amplitudeSum=10000;
    }
    if(f->scenario==LOSS_EVENTS && e->mode==AT_MODE_CANDIDATE && e->acc.windows>10)
        s->lossOfLockEventCount=4;
    if(f->scenario==COMMIT_ERROR && e->mode==AT_MODE_CANDIDATE && e->acc.windows>10)
        s->commitErrorCount=1;
    if(f->scenario==COUNTER_RESET && e->mode==AT_MODE_CANDIDATE) {
        s->lossOfLockEventCount=e->acc.windows>10 ? 1 : 2;
    }
    return ADAPTIVE_PL_OK;
}
static void setup(AT_Engine *e, Fixture *f, int scenario)
{
    AT_Hardware h={1000000,1000,10,0,-10000,10000};
    AT_IO io={read_profile,apply,snapshot,status,f};
    memset(f,0,sizeof(*f)); f->engine=e; f->scenario=scenario;
    f->original.kp=12345; f->original.ki=6789; f->original.kii=17;
    f->original.kd=13; f->original.dCoeff=9; f->active=f->original;
    AT_Init(e,&h,&io);
}
static void check_report_score(const AT_Engine *e)
{
    AT_Engine frozen=*e;
    const AT_Report *r=&e->report;
    if(!r->samples || !r->elapsedMs) return;
    frozen.hardware=r->hardware; frozen.scaleF=r->scaleF;
    frozen.scaleP=r->scaleP; frozen.scaleD=r->scaleD;
    near(r->score,AT_Score(&frozen,r));
    assert(r->runId==e->runId);
    assert(r->repeat<e->config.repeats);
    if(r->mode!=AT_MODE_CALIBRATE) near(r->deadband,10);
    if(r->groupSize) assert(r->groupSize==e->config.repeats);
}
static void run(AT_Engine *e, Fixture *f, u32 now, int cancelMode)
{
    u32 elapsed,lastReport=0;
    f->epoch=now;
    assert(AT_Start(e,now)==AT_ACCEPTED);
    assert(AT_Start(e,now)==AT_BUSY);
    for(elapsed=1; elapsed<125000 && e->busy; ++elapsed) {
        f->now=now+elapsed;
        if(cancelMode>=0 && e->mode==cancelMode && e->acc.windows>20) AT_Cancel(e);
        AT_Tick(e,now+elapsed);
        if(e->report.reportId && e->report.reportId!=lastReport) {
            check_report_score(e); lastReport=e->report.reportId;
            if(e->report.mode<6 && e->report.samples && (e->report.valid&1))
                ++f->counts[e->report.mode];
        }
    }
    assert(!e->busy); assert(elapsed<125000);
}
static void test_scenarios(void)
{
    AT_Engine e; Fixture f;
    setup(&e,&f,IMPROVE); run(&e,&f,0,-1);
    assert(e.result==AT_SUCCESS && e.state==AT_DONE && e.best==2 && e.current==2);
    assert(e.paramsValid && e.done && !e.failed && e.baselineReady && e.progress==100);
    assert(f.counts[AT_MODE_CALIBRATE]==3 && f.counts[AT_MODE_BASE]==3);
    assert(f.active.kp==e.profiles[2].kp && e.completed==33);
    near(e.scaleF,100); near(e.deadband,10); check_report_score(&e);
    setup(&e,&f,CAL_PHASE); e.hardware.phaseOffset=2000; run(&e,&f,0,-1);
    near(e.scaleP,2000); assert(e.done);
    setup(&e,&f,SAME); run(&e,&f,0,-1);
    assert(e.result==AT_NO_IMPROVEMENT && e.best==0 && !memcmp(&f.active,&f.original,sizeof(f.active)));
    /* Default frequency gains equal candidate 4. Time variation alone must not
     * relabel identical complete parameters as a newly improved profile. */
    setup(&e,&f,IDENTICAL_PROFILE); f.realCadence=1;
    e.hardware.clockHz=125000000; e.hardware.windowSamples=131072; e.hardware.settleMs=300;
    f.original.kp=0x400000; f.original.ki=0x100000; f.active=f.original;
    run(&e,&f,0,-1);
    assert(!memcmp(&e.profiles[0],&e.profiles[4],sizeof(AT_Profile)));
    assert(e.result==AT_NO_IMPROVEMENT && e.best==0 && e.current==0 && e.completed==33);
    near(e.bestMean,e.baselineMean); near(e.bestSpread,e.baselineSpread);
    assert(!memcmp(&f.active,&f.original,sizeof(f.active)));
    setup(&e,&f,NOISY); run(&e,&f,0,-1);
    assert(e.result==AT_NO_IMPROVEMENT && e.best==0);
    setup(&e,&f,DRIFT); run(&e,&f,0,-1);
    assert(e.result==AT_INPUT_CHANGED && (e.report.reasons&AT_R_DRIFT));
    assert(e.failed && !e.paramsValid && !memcmp(&f.active,&f.original,sizeof(f.active)));
    assert(e.report.groupSize==3 && e.report.mode==AT_MODE_CONTROL);
    setup(&e,&f,VERIFY_BAD); run(&e,&f,0,-1);
    assert(e.result==AT_VERIFY_FAILED && (e.report.reasons&AT_R_VERIFY));
    assert(e.report.groupSize==3 && e.report.mode==AT_MODE_VERIFY);
    assert(!memcmp(&f.active,&f.original,sizeof(f.active)));
    setup(&e,&f,VERIFY_LAST_UNLOCK); run(&e,&f,0,-1);
    assert(e.result==AT_VERIFY_FAILED && (e.report.reasons&AT_R_LOCK));
    assert(!e.paramsValid && !memcmp(&f.active,&f.original,sizeof(f.active)));
    setup(&e,&f,RAIL_CANDIDATE); run(&e,&f,0,-1);
    assert(e.result==AT_SUCCESS && e.best==2 && (e.rejectionReasons&AT_R_RAIL));
    setup(&e,&f,LOCK_CANDIDATE); run(&e,&f,0,-1);
    assert(e.result==AT_SUCCESS && e.best==2 && (e.rejectionReasons&AT_R_LOCK));
    setup(&e,&f,IMPROVE); run(&e,&f,0,AT_MODE_CANDIDATE);
    assert(e.result==AT_CANCEL && e.state==AT_CANCELED && !e.failed && !e.done && !e.paramsValid);
    assert((e.report.reasons&AT_R_CANCEL) && !e.report.valid);
    assert(!memcmp(&f.active,&f.original,sizeof(f.active)));
    setup(&e,&f,IMPROVE); run(&e,&f,0,AT_MODE_VERIFY); assert(e.result==AT_CANCEL);
    setup(&e,&f,BAD_ROLLBACK); run(&e,&f,0,AT_MODE_CANDIDATE);
    assert(e.result==AT_ROLLBACK_FAILED && (e.report.reasons&AT_R_IO));
    setup(&e,&f,LOCK_RESTORE_FAIL); run(&e,&f,0,AT_MODE_CANDIDATE);
    assert(e.result==AT_ROLLBACK_FAILED && (e.report.reasons&AT_R_LOCK));
    setup(&e,&f,BAD_APPLY); run(&e,&f,0,-1);
    assert(e.result==AT_READBACK_ERROR && !memcmp(&f.active,&f.original,sizeof(f.active)));
    setup(&e,&f,BAD_READ); run(&e,&f,0,-1); assert(e.result==AT_READBACK_ERROR && !f.applies);
    setup(&e,&f,BAD_DATA); run(&e,&f,0,-1); assert(e.result==AT_DATA_ERROR && !f.applies);
    setup(&e,&f,NO_DATA); run(&e,&f,0,-1); assert(e.result==AT_DATA_ERROR && e.report.readErrors>0);
    setup(&e,&f,UNSUPPORTED); run(&e,&f,0,-1); assert(e.result==AT_UNSUPPORTED && !f.applies);
    setup(&e,&f,MID_UNSUPPORTED); run(&e,&f,0,-1); assert(e.result==AT_UNSUPPORTED);
    setup(&e,&f,NO_LOCK); run(&e,&f,0,-1); assert(e.result==AT_NOT_LOCKED && !f.applies);
    setup(&e,&f,SIGNAL_CHANGE); run(&e,&f,0,-1); assert(e.result==AT_INPUT_CHANGED);
    setup(&e,&f,COMMIT_ERROR); run(&e,&f,0,-1);
    assert(e.result==AT_DATA_ERROR && e.report.commitErrors==1 && (e.report.reasons&AT_R_EVENTS));
    setup(&e,&f,SLOW_READER); f.realCadence=1; run(&e,&f,0,-1);
    assert(e.result==AT_DATA_ERROR && (e.report.reasons&AT_R_COVERAGE) && e.report.missing>0);
    setup(&e,&f,DROP_WINDOWS); run(&e,&f,0,-1); assert(e.result==AT_DATA_ERROR);
    setup(&e,&f,COUNTER_RESET); run(&e,&f,0,-1); assert(e.result==AT_DATA_ERROR);
    setup(&e,&f,LOSS_EVENTS); run(&e,&f,0,-1);
    assert((e.rejectionReasons&AT_R_EVENTS) && e.result==AT_NO_IMPROVEMENT);
    setup(&e,&f,IMPROVE); f.sequence=UINT32_MAX-20; run(&e,&f,UINT32_MAX-200,-1);
    assert(e.result==AT_SUCCESS && e.best==2);
    setup(&e,&f,IMPROVE); f.realCadence=1;
    e.hardware.clockHz=125000000; e.hardware.windowSamples=131072; e.hardware.settleMs=300;
    run(&e,&f,0,-1); assert(e.result==AT_SUCCESS && e.report.coverage>.98);
    assert(e.report.windows>=950 && e.report.windows<=955);
    setup(&e,&f,IMPROVE); f.realCadence=1;
    e.hardware.clockHz=3125000; e.hardware.windowSamples=4096; e.hardware.settleMs=800;
    run(&e,&f,0,-1); assert(e.result==AT_SUCCESS && e.report.coverage>.98);
    assert(e.report.windows>=761 && e.report.windows<=765);
    puts("PASS: production engine selection, drift, safety, cancellation, restore, errors and wraps");
}
static void advance(AT_Engine *e, u32 seq, int freq, u32 now, int expected)
{
    AdaptivePlSnapshot s=sample(seq,freq); assert(AT_AddSnapshot(e,&s,now)==expected);
}
static void test_accumulator(void)
{
    AT_Engine e; Fixture f; AT_Report r; AdaptivePlSnapshot s;
    setup(&e,&f,IMPROVE); e.deadband=2; AT_BeginWindow(&e,0);
    advance(&e,10,4,1,0); advance(&e,10,4,2,0); assert(e.acc.discard==1);
    advance(&e,11,4,3,0); advance(&e,12,4,4,1);
    advance(&e,13,-4,5,1); assert(e.acc.pairs==1 && e.acc.flips==1);
    advance(&e,14,2,6,1); advance(&e,15,-4,7,1); assert(e.acc.pairs==1);
    advance(&e,17,4,9,1); assert(e.acc.missing==1 && e.acc.pairs==1);
    advance(&e,18,-4,10,1); assert(e.acc.flips==2 && e.acc.pairs==2);
    advance(&e,18,-4,11,0); assert(e.acc.windows==6);
    AT_FinishWindow(&e,11,&r); assert(r.windows==6 && r.samples==6000 && r.missing==1);
    near(r.flipRate,1); near(r.frequencyMean,-1.0/3); near(r.frequencyRms,sqrt(14));
    assert(r.reasons&AT_R_COVERAGE);
    advance(&e,17,4,12,-1); assert(e.acc.reasons&AT_R_DATA);

    AT_BeginWindow(&e,0); advance(&e,UINT32_MAX-1,4,1,0); advance(&e,UINT32_MAX,4,2,0);
    advance(&e,1,4,3,1); assert(e.acc.missing==1);
    advance(&e,2,-4,4,1); assert(e.acc.flips==1);

    AT_BeginWindow(&e,0); advance(&e,1,4,1,0); advance(&e,2,4,2,0);
    s=sample(3,4); s.lockedSampleCount=999; assert(AT_AddSnapshot(&e,&s,3)==1);
    advance(&e,4,-4,4,1); assert(e.acc.pairs==0);
    s=sample(5,-4); s.phaseSaturatedSampleCount=1;
    assert(AT_AddSnapshot(&e,&s,5)==-2 && (e.acc.reasons&AT_R_PHASE_SAT));

    AT_BeginWindow(&e,0); advance(&e,1,4,1,0);
    s=sample(2,4); s.commitErrorCount=1;
    assert(AT_AddSnapshot(&e,&s,2)==-1 && (e.acc.reasons&AT_R_EVENTS));

    AT_BeginWindow(&e,0); s=sample(1,4); s.positiveRailSampleCount=1;
    assert(AT_AddSnapshot(&e,&s,1)==-1); /* OR cannot be lower than a constituent. */
    s=sample(1,4); s.frequencyAbsSum=100; assert(AT_AddSnapshot(&e,&s,1)==-1);
    s=sample(1,4); s.frequencySquareSum=17000; assert(AT_AddSnapshot(&e,&s,1)==-1);
    s=sample(1,4); s.amplitudeSum=1; assert(AT_AddSnapshot(&e,&s,1)==-1);
    s=sample(1,4); s.phaseFirst=1000; assert(AT_AddSnapshot(&e,&s,1)==-1);
    s=sample(1,4); s.lossOfLockEventCount=UINT32_MAX; assert(AT_AddSnapshot(&e,&s,1)==-1);
    s=sample(1,4); s.commitErrorCount=UINT32_MAX; assert(AT_AddSnapshot(&e,&s,1)==-1);
    s=sample(1,4); s.sequence=0; assert(AT_AddSnapshot(&e,&s,1)==-1);

    /* Legacy absolute moments clip -8192 to 8191, while exact moments do not. */
    AT_BeginWindow(&e,0); s=sample(1,-8192);
    s.frequencyAbsMax=8191; s.frequencyAbsSum=8191000;
    assert(AT_AddSnapshot(&e,&s,1)==0); s.sequence=2;
    assert(AT_AddSnapshot(&e,&s,2)==0); s.sequence=3;
    assert(AT_AddSnapshot(&e,&s,3)==1);
    AT_FinishWindow(&e,4,&r); near(r.frequencyMean,-8192); near(r.frequencyRms,8192);
    near(r.frequencyMae,8191);

    /* Actual elapsed-time coverage, not sequence density, controls acceptance. */
    AT_BeginWindow(&e,0); advance(&e,1,4,1,0); advance(&e,2,4,2,0);
    { u32 i; for(i=3;i<=602;++i) advance(&e,i,4,i,1); }
    AT_FinishWindow(&e,1002,&r); near(r.coverage,.6); assert(r.reasons&AT_R_COVERAGE);
    AT_BeginWindow(&e,0); advance(&e,1,4,1,0); advance(&e,2,4,2,0);
    { u32 i; for(i=3;i<=1002;++i) advance(&e,i,4,i,1); }
    AT_FinishWindow(&e,1002,&r); near(r.coverage,1); assert(!r.reasons && (r.valid&1));
    AT_BeginWindow(&e,0); s=sample(1,4);
    s.frequencySignedSum=1000; s.frequencyAbsSum=3000; s.frequencySquareSum=10000;
    s.phaseFirst=-10; s.phaseLast=20; s.phaseSignedSum=5000; s.phaseAbsSum=15000; s.phaseAbsMax=20;
    assert(AT_AddSnapshot(&e,&s,1)==0); s.sequence=2; assert(AT_AddSnapshot(&e,&s,2)==0);
    s.sequence=3; s.lossOfLockEventCount=1; assert(AT_AddSnapshot(&e,&s,3)==1);
    AT_FinishWindow(&e,3,&r);
    near(r.frequencyMean,1); near(r.frequencyRms,sqrt(10)); near(r.frequencyStd,3);
    near(r.frequencyMae,3); near(r.phaseMean,5); near(r.phaseMae,15);
    near(r.slope,30.0*1000000/999); near(r.outputHeadroom,.99);
    assert(r.lossEvents==1 && r.amplitudeMin==90 && r.amplitudeMax==110);
    puts("PASS: production window accumulator deadband, pairs, gaps, wrap, validity and coverage");
}
static u32 get32(const u8 *p)
{ return (u32)p[0]|(u32)p[1]<<8|(u32)p[2]<<16|(u32)p[3]<<24; }
static float getfloat(const u8 *p)
{ u32 u=get32(p); float f; memcpy(&f,&u,4); return f; }
static void test_diagnostics_and_lifecycle(void)
{
    AT_Engine e; Fixture f; u8 p[AT_DIAG_BYTES],runId; u32 reportId,count;
    setup(&e,&f,IMPROVE); assert(!AT_DiagnosticPage(&e,1,p)); run(&e,&f,0,-1);
    assert(AT_REPORT_PAGES==9 && AT_DiagnosticPage(&e,0,p)==44);
    reportId=get32(p+4); runId=p[3]; assert(reportId && runId==e.runId);
    e.report.frequencyMean=999; ++e.runId; ++e.report.reportId;
    assert(AT_DiagnosticPage(&e,2,p)==44 && p[3]==runId && get32(p+4)==reportId);
    near(getfloat(p+12),60);
    assert(AT_DiagnosticPage(&e,6,p)==44); near(getfloat(p+16),10);
    assert(getfloat(p+20)>0 && getfloat(p+28)>0);
    assert(AT_DiagnosticPage(&e,7,p)==44 && get32(p+32)==1000000 && get32(p+36)==1000);
    assert(AT_DiagnosticPage(&e,8,p)==44 && (s32)get32(p+16)==-10000 && get32(p+24)==3);
    assert(!AT_DiagnosticPage(&e,9,p) && !AT_DiagnosticPage(&e,0,0));
    AT_Invalidate(&e); assert(!e.paramsValid && e.current==255);
    count=e.reportCounter; runId=e.runId; AT_Clear(&e);
    assert(e.state==AT_IDLE && !e.baselineReady && e.current==255 && !e.frozenValid && !e.report.reportId);
    assert(e.reportCounter==count && e.runId==runId);
    e.config.windowMs=0; assert(AT_Start(&e,0)==AT_BAD_CONFIG && !e.busy);
    AT_DefaultConfig(&e.config); e.hardware.settleMs=3000; assert(AT_Start(&e,0)==AT_BAD_CONFIG);
    f.applies=0; e.hardware.settleMs=10; assert(AT_Start(&e,UINT32_MAX-10)==AT_ACCEPTED);
    AT_Cancel(&e); AT_Tick(&e,UINT32_MAX-9);
    assert(e.result==AT_CANCEL && !f.applies);
    setup(&e,&f,IMPROVE); e.runId=255; assert(AT_Start(&e,0)==AT_ACCEPTED && e.runId==1);
    AT_Tick(&e,120001); assert(e.result==AT_TIMEOUT && (e.report.reasons&AT_R_TIMEOUT));
}
int main(void)
{
    test_scenarios(); test_accumulator(); test_diagnostics_and_lifecycle();
    puts("PASS: frozen diagnostic pages and lifecycle"); return 0;
}
