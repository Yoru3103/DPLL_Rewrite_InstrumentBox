"""Exercise the production UART/MMIO adapter with a native C harness.

This isolates the adapter from BSP hardware and the separately tested numerical
engine. It checks hardware units, full-profile transactions, request validation,
and global command exclusion. It does not claim real-time/physical CDC coverage.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "DPLL_Rewrite.sdk/DPLL_2COM_v2/src"

PRELUDE = r'''
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "AutotuneEngine.h"
#define FREQ_METER_BASE_ADDR 0x100000U
#define DPLL_BASE_ADDR 0x200000U
#define Freq_Meter_Run_Statue_Addr (FREQ_METER_BASE_ADDR+(0x110U<<2))
typedef u64 XTime;
#define COUNTS_PER_SECOND 1000000U
static u32 regs[2][0x150], now_ms=1234, packed_len;
static u8 Uart0_TX_Buff[512], PC_HOST_CMD_data_Buff[512], PC_HOST_CMD_data_Size;
static u32 probe_rc, active_status, active_seq;
static int active_rc, commit_rc, start_calls, commit_calls;
static AdaptivePlParameters active_parameters, committed;
static u32 committed_seq;
static void XTime_GetTime(XTime *t) { *t=(XTime)now_ms*1000U; }
static u32 *reg_ptr(u32 addr) {
    u32 bank=addr>=DPLL_BASE_ADDR, base=bank ? DPLL_BASE_ADDR : FREQ_METER_BASE_ADDR;
    assert(addr>=base && (addr-base)/4<0x150 && !(addr&3U));
    return &regs[bank][(addr-base)/4];
}
static u32 Xil_In32(u32 a) { return *reg_ptr(a); }
static void Xil_Out32(u32 a,u32 v) { *reg_ptr(a)=v; }
static void PC_HOST_ASK_Pack(u32 n) { packed_len=n; }
int AdaptivePl_Probe(u32 base) { (void)base; return (int)probe_rc; }
int AdaptivePl_ReadActive(u32 base,AdaptivePlParameters *p,u32 *seq,u32 *status,u32 attempts) {
    (void)base; assert(attempts>0); *p=active_parameters;
    *seq=active_seq; *status=active_status; return active_rc;
}
int AdaptivePl_Commit(u32 base,const AdaptivePlParameters *p,u32 seq,u32 polls) {
    assert(polls>0 && polls<=100000U);
    assert(Xil_In32(base+(0x20U<<2))==0); /* Deliberate reacquisition. */
    committed=*p; committed_seq=seq; ++commit_calls; return commit_rc;
}
int AdaptivePl_ReadSnapshot(u32 base,AdaptivePlSnapshot *s,u32 attempts) {
    (void)base; (void)s; (void)attempts; return ADAPTIVE_PL_INCONSISTENT_SNAPSHOT;
}
void AT_Init(AT_Engine *e,const AT_Hardware *h,const AT_IO *io) {
    memset(e,0,sizeof(*e)); e->hardware=*h; e->io=*io;
    e->config.windowMs=1000; e->config.repeats=3;
    e->config.coveragePermille=800; e->config.amplitudeFloor=16;
    e->config.improvementPermille=30;
}
int AT_Start(AT_Engine *e,u32 now) {
    ++start_calls; e->busy=1; ++e->runId; e->runStartMs=now; return AT_ACCEPTED;
}
void AT_Tick(AT_Engine *e,u32 now) { (void)e; (void)now; }
void AT_Cancel(AT_Engine *e) { e->cancel=1; }
void AT_Invalidate(AT_Engine *e) { e->paramsValid=0; }
void AT_Clear(AT_Engine *e) { e->done=0; }
int AT_ConfigValid(const AT_Config *c) { return c->windowMs>=1000 && c->repeats>=1; }
int AT_DiagnosticPage(AT_Engine *e,u8 page,u8 *p) {
    (void)e; if(page>=AT_REPORT_PAGES) return 0;
    memset(p,0,AT_DIAG_BYTES); p[0]=2; p[1]=5; p[2]=page; return AT_DIAG_BYTES;
}
'''

CHECKS = r'''
static void request(AutotuneContext *ctx,u8 action,u8 length) {
    PC_HOST_CMD_data_Size=length; PC_HOST_CMD_data_Buff[4]=action;
    packed_len=0; Autotune_Command(ctx); assert(packed_len>0);
}
static u32 result_code(void) { return Uart0_TX_Buff[8]; }
int main(void) {
    AutotuneProfile p={11,12,13,14,15}, q;
    u32 bank,cmd,before;
    memset(regs,0,sizeof(regs));
    for(bank=0;bank<2;bank++) {
        regs[bank][0x28]=0x4fffffff; regs[bank][0x29]=0xb0000000;
        regs[bank][0x51]=0xfffffff9; regs[bank][0x20]=1;
        regs[bank][0x2a]=0x12345678;
        regs[bank][0x21]=101; regs[bank][0x22]=102;
        regs[bank][0x23]=103; regs[bank][0x24]=104; regs[bank][0x25]=0xfffc0015;
    }
    Autotune_Init();
    assert(FreqAutotune.engine.hardware.clockHz==125000000);
    assert(FreqAutotune.engine.hardware.windowSamples==131072);
    assert(DpllAutotune.engine.hardware.clockHz==3125000);
    assert(DpllAutotune.engine.hardware.windowSamples==4096);
    assert(FreqAutotune.engine.hardware.settleMs>=300);
    assert(DpllAutotune.engine.hardware.settleMs>=800);
    assert(FreqAutotune.engine.hardware.outputLow==(s32)0xb0000000);
    assert(FreqAutotune.engine.hardware.outputHigh==0x4fffffff);
    assert(FreqAutotune.engine.hardware.phaseOffset==-7);
    assert(DpllAutotune.engine.hardware.outputLow==(s32)0xb0000000);
    assert(DpllAutotune.engine.hardware.phaseOffset==-7);

    /* Legacy is used only when the atomic interface is absent or inactive. */
    probe_rc=(u32)ADAPTIVE_PL_NOT_PRESENT;
    assert(Autotune_ReadProfile(&FreqAutotune,&q) && q.kp==101 && q.dCoeff==21);
    probe_rc=ADAPTIVE_PL_OK; active_status=0;
    assert(Autotune_ReadProfile(&FreqAutotune,&q) && q.kii==103);
    active_parameters.kp=201; active_parameters.ki=202; active_parameters.kii=203;
    active_parameters.kd=204; active_parameters.dCoefficient=205;
    active_status=ADAPTIVE_PL_STATUS_ACTIVE;
    assert(Autotune_ReadProfile(&FreqAutotune,&q) && q.kp==201 && q.kd==204);
    active_rc=ADAPTIVE_PL_VERIFY_ERROR;
    assert(!Autotune_ReadProfile(&FreqAutotune,&q));
    active_rc=0; active_status|=ADAPTIVE_PL_STATUS_BUSY;
    assert(!Autotune_ReadProfile(&FreqAutotune,&q));

    /* Atomic apply uses a fresh nonzero sequence and restores lock/offset. */
    before=commit_calls;
    assert(!Autotune_IOApply(&FreqAutotune,&p,2));
    assert(commit_calls==before && regs[0][0x20]==1);
    active_status=ADAPTIVE_PL_STATUS_ACTIVE; active_seq=0xffffffffU;
    assert(Autotune_IOReadProfile(&FreqAutotune,&q));
    assert(Autotune_IOApply(&FreqAutotune,&p,2));
    assert(committed_seq==1 && committed.profileId==2);
    assert(committed.kp==11 && committed.ki==12 && committed.kii==13);
    assert(committed.kd==14 && committed.dCoefficient==15);
    assert(regs[0][0x20]==1 && regs[0][0x2a]==0x12345678);
    assert(regs[0][0x21]==101 && FreqAutotune.activeProfile==2);
    commit_rc=ADAPTIVE_PL_TIMEOUT;
    assert(!Autotune_IOApply(&FreqAutotune,&p,3));
    assert(regs[0][0x20]==1 && regs[0][0x2a]==0x12345678);
    assert(FreqAutotune.activeProfile==255);
    /* A prior failed write/readback may have damaged registers. Recovery must
     * use the precheck snapshot, not these now-corrupt live values. */
    regs[0][0x20]=0; regs[0][0x2a]=0x87654321;
    commit_rc=0;
    assert(Autotune_IOApply(&FreqAutotune,&p,0));
    assert(regs[0][0x20]==1 && regs[0][0x2a]==0x12345678);
    regs[1][0x20]=0;
    assert(Autotune_IOReadProfile(&DpllAutotune,&q));
    assert(Autotune_IOApply(&DpllAutotune,&p,4));
    assert(regs[1][0x20]==0 && regs[1][0x2a]==0x12345678);

    /* A truncated frame cannot re-use stale configuration or action bytes. */
    before=start_calls;
    request(&FreqAutotune,1,0); assert(result_code()==AT_INVALID_ACTION && packed_len==18);
    request(&FreqAutotune,1,2); assert(result_code()==AT_INVALID_ACTION);
    assert(start_calls==before);
    request(&FreqAutotune,7,20); assert(result_code()==AT_INVALID_ACTION);
    request(&FreqAutotune,5,1); assert(result_code()==AT_INVALID_ACTION);
    PC_HOST_CMD_data_Buff[5]=AT_REPORT_PAGES;
    request(&FreqAutotune,5,2); assert(result_code()==AT_INVALID_ACTION);
    request(&FreqAutotune,6,1);
    assert(packed_len==24 && Uart0_TX_Buff[5]==6);
    assert(Autotune_Get32(Uart0_TX_Buff+8)==1000);
    assert(Autotune_Get32(Uart0_TX_Buff+24)==30);
    Autotune_Put32(PC_HOST_CMD_data_Buff+5,1700);
    Autotune_Put32(PC_HOST_CMD_data_Buff+9,4);
    Autotune_Put32(PC_HOST_CMD_data_Buff+13,850);
    Autotune_Put32(PC_HOST_CMD_data_Buff+17,33);
    Autotune_Put32(PC_HOST_CMD_data_Buff+21,41);
    FreqAutotune.engine.paramsValid=1;
    request(&FreqAutotune,7,21);
    assert(result_code()==AT_SUCCESS && packed_len==18);
    assert(!FreqAutotune.engine.paramsValid);
    assert(FreqAutotune.engine.config.windowMs==1700);
    assert(FreqAutotune.engine.config.repeats==4);
    assert(FreqAutotune.engine.config.coveragePermille==850);
    assert(FreqAutotune.engine.config.amplitudeFloor==33);
    assert(FreqAutotune.engine.config.improvementPermille==41);
    request(&FreqAutotune,6,1);
    assert(packed_len==24 && Autotune_Get32(Uart0_TX_Buff+8)==1700);
    assert(Autotune_Get32(Uart0_TX_Buff+12)==4);
    assert(Autotune_Get32(Uart0_TX_Buff+16)==850);
    assert(Autotune_Get32(Uart0_TX_Buff+20)==33);
    assert(Autotune_Get32(Uart0_TX_Buff+24)==41);
    Autotune_Put32(PC_HOST_CMD_data_Buff+5,1);
    request(&FreqAutotune,7,21);
    assert(result_code()==AT_BAD_CONFIG && FreqAutotune.engine.config.windowMs==1700);
    PC_HOST_CMD_data_Buff[5]=0;
    request(&FreqAutotune,5,2);
    assert(packed_len==AT_DIAG_BYTES && Uart0_TX_Buff[5]==5 && Uart0_TX_Buff[6]==0);
    PC_HOST_CMD_data_Buff[5]=1;
    request(&FreqAutotune,4,2); assert(result_code()==AT_INVALID_POLICY);
    regs[0][0x110]=1;
    request(&FreqAutotune,1,1); assert(result_code()==AT_BUSY);
    assert(!AutotuneOwner && start_calls==before);
    regs[0][0x110]=0;
    request(&FreqAutotune,1,1);
    assert(result_code()==AT_ACCEPTED && AutotuneOwner==&FreqAutotune);
    assert(!FreqAutotune.restoreContextValid);
    request(&DpllAutotune,1,1); assert(result_code()==AT_BUSY);
    request(&DpllAutotune,7,21); assert(result_code()==AT_BUSY);
    request(&FreqAutotune,2,1); assert(FreqAutotune.engine.cancel);
    assert(Autotune_CommandBlocked(1) && Autotune_CommandBlocked(2));
    assert(Autotune_CommandBlocked(0x0c));
    assert(Autotune_CommandBlocked(0x1a) && Autotune_CommandBlocked(0x1b));
    for(cmd=0x80;cmd<=0x9a;cmd++)
        assert(Autotune_CommandBlocked((u8)cmd)==(cmd!=0x97 && cmd!=0x98));
    assert(!Autotune_CommandBlocked(9) && !Autotune_CommandBlocked(0x14));
    FreqAutotune.engine.busy=0; Autotune_Service(); assert(!AutotuneOwner);
    assert(!Autotune_CommandBlocked(0x86));
    assert(Autotune_DisplayScore(1.234)==1234);
    assert(Autotune_DisplayScore(70)==65535);
    assert(Autotune_DisplayScore(NAN)==65535);
    puts("PASS: production Autotune hardware/UART adapter");
    return 0;
}
'''


class IntegrationTests(unittest.TestCase):
    def test_production_adapter(self):
        compiler = shutil.which("gcc")
        self.assertIsNotNone(compiler, "gcc is required for the adapter test")
        code = (SRC / "helloworld.c").read_text(encoding="utf-8-sig")
        adapter = code.split("/* Complete PS-autonomous Autotune;", 1)[1]
        adapter = "/* Complete PS-autonomous Autotune;" + adapter.split(
            "void CMD_01_READ_MWS_SETTING(void)", 1)[0]
        with tempfile.TemporaryDirectory(prefix="autotune_adapter_") as tmp:
            source = Path(tmp) / "adapter.c"
            binary = Path(tmp) / "adapter.exe"
            source.write_text(PRELUDE + adapter + CHECKS, encoding="utf-8")
            built = subprocess.run([
                compiler, "-std=c99", "-Wall", "-Wextra", "-Werror",
                "-Wno-unused-function", "-Wno-sign-compare",
                "-I", str(ROOT / "tests/ps/include"), "-I", str(SRC),
                str(source), "-lm", "-o", str(binary),
            ], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            ran = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            self.assertIn("PASS:", ran.stdout)

    def test_ps_bus_and_loop_bus_share_global_clock(self):
        top = (ROOT / "DPLL_Rewrite.srcs/sources_1/ReadPitaya/red_pitaya_top.v").read_text(
            encoding="utf-8", errors="replace")
        self.assertIn(".axi0_clk_i(adc_clk)", top)
        self.assertNotIn(".axi0_clk_i(adc_clk_in)", top)
        self.assertIn("BUFG bufg_adc_clk", top)
        for module in ("dpll_wrapper dpll_wrapper_inst", "Digital_Freq_Meter Digital_Freq_Meter_inst"):
            instance = top.split(module, 1)[1].split(");", 1)[0]
            self.assertRegex(instance, r"\.clk1\s*\(\s*adc_clk\s*\)")

    def test_uart_dispatch_exclusion_and_pending_frame(self):
        code = (SRC / "helloworld.c").read_text(encoding="utf-8-sig")
        dispatch = code.split("void PC_HOST_CMD_Respond(void)", 1)[1]
        dispatch = dispatch.split("/*********************************UART1", 1)[0]
        self.assertLess(dispatch.index("Autotune_CommandBlocked("),
                        dispatch.index("switch(PC_HOST_CMD_GET)"))
        self.assertRegex(code, r"volatile\s+(?:uint8_t|u8)\s+PC_HOST_CMD_RX_Mark")
        receiver = code.split("void PC_HOST_CMD_Get(void)\n{", 1)[1]
        receiver = receiver.split("/* Complete PS-autonomous", 1)[0]
        self.assertRegex(receiver, r"if\s*\(PC_HOST_CMD_RX_Mark\)\s*return")
        self.assertLess(receiver.index("if(PC_HOST_CMD_RX_Mark)"),
                        receiver.index("PC_HOST_CMD_RX_Mark = 1"))


if __name__ == "__main__":
    unittest.main()
