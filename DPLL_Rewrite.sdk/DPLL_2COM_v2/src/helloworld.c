

#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "Peripherals.h"
#include "sleep.h"
#include "xil_types.h"
#include "xparameters.h"
#include "xparameters_ps.h"
#include "xscugic.h"
#include "xuartps.h"
#include "xuartps_hw.h"
#include "xtime_l.h"

XUartPs XUartPs_uart0;
XUartPs XUartPs_uart1;
XScuGic XPS_XScuGic;

uint8_t STM8_EEPROM_Data[44 + 32];
uint8_t PLL_Lock_Status;

uint32_t Uart1_STM8_Save_EEPROM(void);
uint32_t Uart1_STM8_Read_EEPROM(void);
uint32_t Uart1_STM8_Set_MWS_CFG(uint32_t Frequency_Code,uint8_t Power_Code);
uint32_t Uart1_STM8_Get_MWS_CFG(uint32_t* Frequency_Code,uint8_t* Power_Code);
uint32_t Uart1_STM8_Set_RF_ON(void);
uint32_t Uart1_STM8_Set_RF_OFF(void);
uint32_t Uart1_STM8_Read_MWS_Status(uint8_t* Status);
uint32_t Uart1_STM8_Set_Vbias_DAC(int16_t DACA,int16_t DACB);
uint32_t Uart1_STM8_Read_Vbias_DAC(int16_t* DACA,int16_t* DACB);
uint32_t Uart1_STM8_Read_Vbias_ADC(uint16_t* ADCA,uint16_t* ADCB);

void XPS_Core_init(void)
{
	XScuGic_Config *XScuGic_Config_ps;
	XScuGic_Config_ps = XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
	XScuGic_CfgInitialize(&XPS_XScuGic,XScuGic_Config_ps,XScuGic_Config_ps->CpuBaseAddress);

	Xil_ExceptionInit();
	Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,(Xil_ExceptionHandler)XScuGic_InterruptHandler,(void *)&XPS_XScuGic);
	Xil_ExceptionEnable();
}

void Write_PLL_Data_From_EEPROM(void)
{
	u32 data;
	Xil_Out32(DAC0_Centre_Frequency_Addr,*((uint32_t*)&STM8_EEPROM_Data[0+8]));//中心频率
	Xil_Out32(VOC_Fre_Mul_Addr,*((uint16_t*)&STM8_EEPROM_Data[4+8]));//MUL
	Xil_Out32(VOC_Fre_Div_Addr,*((uint16_t*)&STM8_EEPROM_Data[6+8]));//DIV
    Xil_Out32(PLL0_PID_GainP_Addr,*((uint32_t*)&STM8_EEPROM_Data[8+8]));
    Xil_Out32(PLL0_PID_GainI_Addr,*((uint32_t*)&STM8_EEPROM_Data[12+8]));
    Xil_Out32(PLL0_PID_GainI2_Addr,*((uint32_t*)&STM8_EEPROM_Data[16+8]));
    Xil_Out32(PLL0_PID_GainD_Addr,*((uint32_t*)&STM8_EEPROM_Data[20+8]));
    data = *((uint16_t*)&STM8_EEPROM_Data[24+8]);
    Xil_Out32(PID_Freq_Pos_Limit_Addr,data<<16);//上位机储存和传入参数为高16bit写入到FPGA内部为32Bit
    data = *((uint16_t*)&STM8_EEPROM_Data[26+8]);
    Xil_Out32(PID_Freq_Neg_Limit_Addr,data<<16);//上位机储存和传入参数为高16bit写入到FPGA内部为32Bit
    Xil_Out32(DAC0_Freq_Residuals_Threshold_Addr,*((uint16_t*)&STM8_EEPROM_Data[28+8]));//14Bit
    Xil_Out32(DAC0_Phase_Residuals_Threshold_Addr,*((uint16_t*)&STM8_EEPROM_Data[30+8]));//32Bit
    Xil_Out32(DAC0_VOC_Amplitude_Addr,*((uint16_t*)&STM8_EEPROM_Data[32+8]));//amplitude 15bit;
}


/*********************************UART0  PC-USBCOM****************************/
#define PC_CMD_READ_MWS_SETTING				0x01
#define PC_CMD_READ_MWS_STATUS				0x02
#define PC_CMD_READ_PLL_FREQ_SETTING		0x03
#define PC_CMD_READ_PLL_MUL_DIV_SETTING		0x04
#define PC_CMD_READ_PLL_THRESHOLD_SETTING	0x05
#define PC_CMD_READ_PLL_LIMIT_SETTING		0x06
#define PC_CMD_READ_PLL_PID_SETTING			0x07
#define PC_CMD_READ_PLL_AMP_SETTING			0x08
#define PC_CMD_READ_PLL_STATUS				0x09

#define PC_CMD_READ_VERSION					0x0A
#define PC_CMD_READ_DATA_LOG				0x0C

#define PC_CMD_READ_FREQMETER_FREQ_SETTING			0x10
#define PC_CMD_READ_FREQMETER_THRESHOLD_SETTING		0x11
#define PC_CMD_READ_FREQMETER_LIMIT_SETTING			0x12
#define PC_CMD_READ_FREQMETER_PID_SETTING			0x13
#define PC_CMD_READ_FREQMETER_STATUS				0x14
#define PC_CMD_READ_FREQMETER_RUN_STATUS			0x15
#define PC_CMD_READ_FREQMETER_TIMER_SETTING			0x16
#define PC_CMD_READ_FREQMETER_CNT					0x17

#define PC_CMD_VBIAS_READ_DAC	 			0x1A
#define PC_CMD_VBIAS_READ_ADC	 			0x1B



#define PC_CMD_WRITE_MWS_FREQ_PWR			0x81
#define PC_CMD_WRITE_PLL_FREQ				0x82
#define PC_CMD_WRITE_PLL_MUL_DIV			0x83
#define PC_CMD_WRITE_PLL_THRESHOLD			0x84
#define PC_CMD_WRITE_PLL_LIMIT				0x85
#define PC_CMD_WRITE_PLL_PID				0x86
#define PC_CMD_WRITE_PLL_AMP				0x87
#define PC_CMD_WRITE_MWS_ON					0x88
#define PC_CMD_WRITE_MWS_OFF				0x89
#define PC_CMD_WRITE_PLL_ON					0x8A
#define PC_CMD_WRITE_PLL_OFF				0x8B
#define PC_CMD_LOAD_EEPROM					0x8C
#define PC_CMD_SAVE_EEPROM					0x8D
#define PC_CMD_PLL_RESET					0x8E

#define PC_CMD_FREQMETER_FREQ				0x90
#define PC_CMD_FREQMETER_THRESHOLD			0x91
#define PC_CMD_FREQMETER_LIMIT				0x92
#define PC_CMD_FREQMETER_PID				0x93
#define PC_CMD_FREQMETER_TIMER				0x94
#define PC_CMD_FREQMETER_TRIG				0x95
#define PC_CMD_FREQMETER_RESET	 			0x96
#define PC_CMD_AUTOTUNE_FREQ_METER		0x97
#define PC_CMD_AUTOTUNE_DPLL			0x98

#define PC_CMD_VBIAS_WRITE_DAC	 			0x9A



uint8_t Uart0_RX_Buff[512];
uint8_t Uart0_TX_Buff[512];
uint8_t PC_HOST_CMD_data_Buff[512];
uint32_t Uart0_RX_Num;
uint8_t PC_HOST_CMD_ASK;
uint8_t PC_HOST_CMD_GET;
uint8_t PC_HOST_CMD_RX_Mark = 0;
uint8_t PC_HOST_CMD_data_Size = 0;
uint64_t Freq_meter_gate_time_cache = 0;

void PC_HOST_CMD_Get(void);

void Uart0_Handler(void *CallBackRef)
{
	u32 IsrStatus;
	u32 RX_Num;

	IsrStatus =  XUartPs_ReadReg(XUartPs_uart0.Config.BaseAddress, XUARTPS_IMR_OFFSET);
	IsrStatus &= XUartPs_ReadReg(XUartPs_uart0.Config.BaseAddress, XUARTPS_ISR_OFFSET);

	if((IsrStatus & (u32)XUARTPS_IXR_RXOVR)!=0)
	{
		XUartPs_WriteReg(XUartPs_uart0.Config.BaseAddress, XUARTPS_ISR_OFFSET, XUARTPS_IXR_RXOVR);
		RX_Num=XUartPs_Recv(&XUartPs_uart0,&Uart0_RX_Buff[Uart0_RX_Num],512-Uart0_RX_Num);
		Uart0_RX_Num+=RX_Num;
	}
	if((IsrStatus & (u32)XUARTPS_IXR_TOUT)!=0)
	{
		XUartPs_WriteReg(XUartPs_uart0.Config.BaseAddress, XUARTPS_ISR_OFFSET, XUARTPS_IXR_TOUT);
		RX_Num=XUartPs_Recv(&XUartPs_uart0,&Uart0_RX_Buff[Uart0_RX_Num],512-Uart0_RX_Num);
		Uart0_RX_Num+=RX_Num;
		if(Uart0_RX_Num!=0)PC_HOST_CMD_Get();
		Uart0_RX_Num=0;
	}
}

void Uart0PS_Init(void)
{
	XUartPs_Config *XUartPs_Config_uart0;
	XUartPsFormat XUartPsFormat_uart0;

	int status;

	XUartPs_Config_uart0 = XUartPs_LookupConfig(XPAR_PS7_UART_0_DEVICE_ID);//获得串口1配置信息
	status = XUartPs_CfgInitialize(&XUartPs_uart0,XUartPs_Config_uart0,XUartPs_Config_uart0->BaseAddress);
	if(status != XST_SUCCESS)
	{
		print("Initialize uart1 fail\n");
	}
	XUartPs_SetOperMode(&XUartPs_uart0, XUARTPS_OPER_MODE_NORMAL);
	XUartPsFormat_uart0.BaudRate = 921600;//波特率921600
	XUartPsFormat_uart0.DataBits = XUARTPS_FORMAT_8_BITS;
	XUartPsFormat_uart0.Parity = XUARTPS_FORMAT_NO_PARITY;
	XUartPsFormat_uart0.StopBits = XUARTPS_FORMAT_1_STOP_BIT;
	status = XUartPs_SetDataFormat(&XUartPs_uart0,&XUartPsFormat_uart0);
	if(status != XST_SUCCESS)
	{
		print("set Buad Rate fail\n");
	}
	XUartPs_SetFifoThreshold(&XUartPs_uart0,32);
	XUartPs_SetRecvTimeout(&XUartPs_uart0,4);//4*4=16 timeout IXR
	XUartPs_SetInterruptMask(&XUartPs_uart0,XUARTPS_IXR_RXOVR|XUARTPS_IXR_TOUT);//开中断

	XScuGic_Disable(&XPS_XScuGic,XPS_UART0_INT_ID);
	//XScuGic_SetPriorityTriggerType(&XPS_XScuGic,XPS_UART0_INT_ID,16,1);
	XScuGic_Connect(&XPS_XScuGic,XPS_UART0_INT_ID,(Xil_ExceptionHandler)Uart0_Handler,(void *)&XUartPs_uart0);//入口
	XScuGic_Enable(&XPS_XScuGic,XPS_UART0_INT_ID);

	Uart0_RX_Num=0;
}

void PC_HOST_ASK_Pack(uint32_t Data_Size)
{
	uint32_t i;
	uint32_t checksum = 0;
	Uart0_TX_Buff[0] = 0xA2;
	Uart0_TX_Buff[3] = Data_Size;
	for(i=2;i<(Data_Size+4);i++)
	{
		checksum += Uart0_TX_Buff[i];
	}
	Uart0_TX_Buff[1] = checksum;
	for(i=0;i<(Data_Size+4);i++)XUartPs_SendByte(XUartPs_uart0.Config.BaseAddress,Uart0_TX_Buff[i]);
}

void PC_HOST_Send_ASK(uint8_t CMD,uint8_t Ask)
{
	Uart0_TX_Buff[2] = CMD;
	Uart0_TX_Buff[4] = Ask;
	PC_HOST_ASK_Pack(1);
}
void PC_HOST_Send_ASK_Only(uint8_t Ask)
{
	Uart0_TX_Buff[4] = Ask;
	PC_HOST_ASK_Pack(1);
}

void PC_HOST_CMD_Get(void)
{
	u32 i;
	u32 CheckSm=0;
	PC_HOST_CMD_RX_Mark = 1;
	if(Uart0_RX_Buff[0]!=0xC6)
	{
		PC_HOST_CMD_ASK = 0xF0;
		print("Err F0 Head\r\n");
		printf("M %.2X %.2X %.2X %.2X %.2X %.2X\r\n",Uart0_RX_Buff[0],Uart0_RX_Buff[1],Uart0_RX_Buff[2],Uart0_RX_Buff[3],Uart0_RX_Buff[4],Uart0_RX_Buff[5]);
		return;
	}
	if((Uart0_RX_Num<4)||(Uart0_RX_Num>48))
	{
		PC_HOST_CMD_ASK = 0xF1;
		print("Err F1 Length\r\n");
		return;
	}
	if(Uart0_RX_Buff[3]!=(Uart0_RX_Num-4))
	{
		PC_HOST_CMD_ASK = 0xF2;
		print("Err F2 nums\r\n");
		return;
	}
	if(((Uart0_RX_Buff[2]<0x80)&&(Uart0_RX_Buff[2]>0x1B))||(Uart0_RX_Buff[2]>0x9A))
	{
		PC_HOST_CMD_ASK = 0xF3;
		print("Err F3 cmd\r\n");
		return;
	}
	for(i=2;i<(Uart0_RX_Num);i++)
	{
		CheckSm += Uart0_RX_Buff[i];
	}
	if(Uart0_RX_Buff[1]!=(CheckSm&0xFF))
	{
		PC_HOST_CMD_ASK = 0xF4;
		print("Err F4 checksum\r\n");
		return;
	}
	PC_HOST_CMD_GET = Uart0_RX_Buff[2];
	PC_HOST_CMD_data_Size = Uart0_RX_Buff[3];
	if(Uart0_RX_Buff[3]>0)
	for(i=0;i<Uart0_RX_Num;i++)
	{
		PC_HOST_CMD_data_Buff[i] = Uart0_RX_Buff[i];
	}
	PC_HOST_CMD_ASK = 0x00;
}

/* Stage 1 adaptive-loop framework.  Candidate tables are introduced in Stage 2. */
#define AUTOTUNE_PROTOCOL_VERSION       1U
#define AUTOTUNE_SERVICE_PERIOD_MS      50U						// executing period of Autotune_Task();sample frequency = 1000 / 50 = 20Hz
#define AUTOTUNE_BASELINE_TIME_MS       500U					// 当前参数进行基线统计的时间窗口
#define AUTOTUNE_VERIFY_TIME_MS         500U					// 最终应用所选参数后，再进行验证一次的时间窗口
#define AUTOTUNE_PROFILE_BASELINE       0U						// stage1中先只采集原始参数进行尝试比对
#define AUTOTUNE_PROFILE_NONE           0xFFU					// 表示当前没有有效的profile

typedef enum {
	AUTOTUNE_TARGET_FREQ = 0,
	AUTOTUNE_TARGET_DPLL = 1
} AutotuneTarget;


// Control Command from PC
typedef enum {
	AUTOTUNE_ACTION_QUERY = 0,					// 查询状态
	AUTOTUNE_ACTION_START = 1,					// 启动autotune
	AUTOTUNE_ACTION_CANCEL = 2,					// 取消正在运行的autotune
	AUTOTUNE_ACTION_CLEAR = 3,					// 清除状态
	AUTOTUNE_ACTION_SET_POLICY = 4				// 设置autotune策略
} AutotuneAction;

typedef enum {
	AUTOTUNE_POLICY_HOST_ONLY = 0,				// 只允许PC主动发送START启动
	AUTOTUNE_POLICY_BOOT_ONCE = 1,				// 上电自动调参一次
	AUTOTUNE_POLICY_BOOT_AND_RECOVER = 2		// 上述均开启
} AutotunePolicy;

/*
 * 自动调参执行状态机。
 *
 * IDLE
 *   ↓
 * PRECHECK
 *   ↓
 * BASELINE
 *   ↓
 * SELECT_BEST
 *   ↓
 * APPLY_BEST
 *   ↓
 * VERIFY
 *   ↓
 * DONE
 *
 * 出错/取消：
 *   ↓
 * ROLLBACK
 *   ↓
 * FAILED / CANCELED
 */
typedef enum {
	AUTOTUNE_EXEC_IDLE = 0,
	AUTOTUNE_EXEC_PRECHECK = 1,				// 启动前检查：保存参数、检查当前锁定状态。
	AUTOTUNE_EXEC_BASELINE = 2,				// 测量当前参数的基线性能。
	AUTOTUNE_EXEC_APPLY_CANDIDATE = 3,		// Stage 2：写入一组候选PID参数。
	AUTOTUNE_EXEC_SETTLE = 4,				// Stage 2：参数切换后等待PLL稳定。
	AUTOTUNE_EXEC_EVALUATE = 5,				// Stage 2：采样并评价当前候选参数。
	AUTOTUNE_EXEC_NEXT_CANDIDATE = 6,		// Stage 2：切换到下一组候选参数。
	AUTOTUNE_EXEC_SELECT_BEST = 7,			// 所有候选测试完成，选择评分最佳参数。
	AUTOTUNE_EXEC_APPLY_BEST = 8,			// 将最佳参数正式写入PL。
	AUTOTUNE_EXEC_VERIFY = 9,				// 应用最佳参数后再次验证锁定性能。
	AUTOTUNE_EXEC_ROLLBACK = 10,			// 调参失败/取消时恢复调参开始前的参数。
	AUTOTUNE_EXEC_DONE = 11,				// 自动调参成功完成。
	AUTOTUNE_EXEC_FAILED = 12,				// 自动调参失败。
	AUTOTUNE_EXEC_CANCELED = 13				// 用户主动取消。
} AutotuneExecState;

typedef enum {
	AUTOTUNE_HEALTH_UNINITIALIZED = 0,		// 尚未完成任何有效的参数验证。
	AUTOTUNE_HEALTH_VALID = 1,				// 当前参数有效且保持锁定。
	AUTOTUNE_HEALTH_DEGRADED = 2,			// Stage 2：性能下降但还没有完全失锁。
	AUTOTUNE_HEALTH_LOST = 3,				// 已经检测到失锁。
	AUTOTUNE_HEALTH_RETUNE_PENDING = 4,		// Stage 2：已经判断需要重新调参。
	AUTOTUNE_HEALTH_FAULT = 5				// 参数写入/回读等硬件异常。
} AutotuneHealthState;

typedef enum {
	AUTOTUNE_RESULT_NONE = 0,				// 还无结果
	AUTOTUNE_RESULT_SUCCESS = 1,			// 成功
	AUTOTUNE_RESULT_ACCEPTED = 2,			// 命令已接收，任务还在运行
	AUTOTUNE_RESULT_BUSY = 3,				// 当前已有任务运行，无法启动新的任务
	AUTOTUNE_RESULT_REJECTED = 4,			// 当前状态下拒绝该操作。
	AUTOTUNE_RESULT_INVALID_ACTION = 5,		// PC发送了不存在的action。
	AUTOTUNE_RESULT_INVALID_POLICY = 6,		// PC发送了不存在的policy。
	AUTOTUNE_RESULT_NOT_LOCKED = 7,			// 启动前或验证阶段发现PLL没有有效锁定。
	AUTOTUNE_RESULT_READBACK_ERROR = 8,		// 写入PL参数后回读不一致。
	AUTOTUNE_RESULT_CANCELED = 9			// 用户主动取消
} AutotuneResult;

typedef struct {
	u32 kp;
	u32 ki;
	u32 kii;
	u32 kd;
	u32 dCoeff;			// D项相关滤波系数
} AutotuneProfile;

typedef struct {
	u64 amplitudeSum;						// 幅值累计值
	u64 absFreqSum;							// |瞬时频率误差|累计值
	u64 absPhaseSum;						// |相位残差|累计值
	u32 amplitudeMin;						// 窗口中的最小幅值
	u32 amplitudeMax;						// 窗口中的最大幅值
	u32 sampleCount;						// 总采样次数
	u32 lockedCount;						// 采样时判定为锁定的次数
} AutotuneMetrics;

typedef struct {
	AutotuneTarget target;
	AutotunePolicy policy;


	AutotuneExecState execState;
	AutotuneHealthState healthState;
	AutotuneResult result;


	AutotuneProfile originalProfile;		// 原始PID参数
	AutotuneMetrics metrics;				// 当前窗口数据
	u32 originalManualOffset;				// 参数写入过程中保存manual offset。


	u32 runStartMs;							// 任务开始时间
	u32 stateStartMs;						// 状态开始时间
	u32 lastServiceMs;						// 上次任务执行时间


	u16 currentScore;						// 当前profile评分
	u16 bestScore;							// 最佳评分


	u8 runId;								// 任务ID
	u8 progress;							// 任务进度
	u8 currentProfileId;					// 当前测试profile编号
	u8 activeProfileId;						// 当前写入硬件并生效的profile编号
	u8 bestProfileId;						// 当前最佳profile编号


	u8 done;								// 任务完成状态
	u8 busy;								// 执行任务状态
	u8 failed;								// 任务失败状态
	u8 paramsValid;							// 当前PID参数已验证
	u8 lockValid;							// 当前锁定状态有效
	u8 retunePending;						// 检测到需要重新调参
	u8 cancelRequested;						// PC取消请求
	u8 originalProfileValid;				// 原始profile保存了有效参数
} AutotuneContext;

static AutotuneContext FreqAutotune;
static AutotuneContext DpllAutotune;
static AutotuneContext *AutotuneOwner = NULL;		// 确保同时只运行一个调参

static u32 Autotune_Millis(void)
{
	XTime now;
	XTime_GetTime(&now);
	return (u32)(now / (COUNTS_PER_SECOND / 1000U));
}

// 无符号减法，即使计时器发生一次溢出，在时间间隔远小于2^32ms时仍然可以正常工作
static u32 Autotune_Elapsed(u32 now, u32 start)
{
	return now - start;
}

// 处理INT32_MIN问题
static u32 Autotune_Abs32(s32 value)
{
	if(value >= 0) return (u32)value;
	return (u32)(-(value + 1)) + 1U;
}

// 将14bit扩展为32bit有符号数
static s32 Autotune_SignExtend14(u32 value)
{
	value &= 0x3FFFU;
	if((value & 0x2000U) != 0U) value |= 0xFFFFC000U;
	return (s32)value;
}

// 根据FREQ与PLL自动返回对应的Lock控制器、手动频率offset、当前环路状态寄存器
static u32 Autotune_LockAddr(const AutotuneContext *ctx)
{
	return (ctx->target == AUTOTUNE_TARGET_FREQ) ? Freq_Meter_Lock_Ctrl_Addr : PLL0_Lock_Ctrl_Addr;
}

static u32 Autotune_ManualOffsetAddr(const AutotuneContext *ctx)
{
	return (ctx->target == AUTOTUNE_TARGET_FREQ) ? Freq_Meter_Freq_Manual_Offset_Addr : VCO_Freq_Manual_Offset_Addr;
}

static u32 Autotune_StatusRegister(const AutotuneContext *ctx)
{
	return Xil_In32((ctx->target == AUTOTUNE_TARGET_FREQ) ? Freq_Meter_System_Statue_Addr : System_Statue);
}

// 读取当前PID参数
static void Autotune_ReadProfile(const AutotuneContext *ctx, AutotuneProfile *profile)
{
	if(ctx->target == AUTOTUNE_TARGET_FREQ) {
		profile->kp = Xil_In32(Freq_Meter_PID_GainP_Addr);
		profile->ki = Xil_In32(Freq_Meter_PID_GainI_Addr);
		profile->kii = Xil_In32(Freq_Meter_PID_GainI2_Addr);
		profile->kd = Xil_In32(Freq_Meter_PID_GainD_Addr);
		profile->dCoeff = Xil_In32(Freq_Meter_Coefd_Filter_Addr);
	} else {
		profile->kp = Xil_In32(PLL0_PID_GainP_Addr);
		profile->ki = Xil_In32(PLL0_PID_GainI_Addr);
		profile->kii = Xil_In32(PLL0_PID_GainI2_Addr);
		profile->kd = Xil_In32(PLL0_PID_GainD_Addr);
		profile->dCoeff = Xil_In32(PLL0_Coefd_Filter_Addr);
	}
}

static int Autotune_ProfileEqual(const AutotuneProfile *left, const AutotuneProfile *right)
{
	return left->kp == right->kp && left->ki == right->ki && left->kii == right->kii &&
		left->kd == right->kd && left->dCoeff == right->dCoeff;
}

/* Scheme B transaction: only the selected loop is unlocked and all fields are verified. */
static int Autotune_ApplyProfile(AutotuneContext *ctx, const AutotuneProfile *profile)
{
	AutotuneProfile active;
	Autotune_ReadProfile(ctx, &active);
	if(Autotune_ProfileEqual(&active, profile)) return 1;

	ctx->originalManualOffset = Xil_In32(Autotune_ManualOffsetAddr(ctx));
	Xil_Out32(Autotune_LockAddr(ctx), 0U);
	if(ctx->target == AUTOTUNE_TARGET_FREQ) {
		Xil_Out32(Freq_Meter_PID_GainP_Addr, profile->kp);
		Xil_Out32(Freq_Meter_PID_GainI_Addr, profile->ki);
		Xil_Out32(Freq_Meter_PID_GainI2_Addr, profile->kii);
		Xil_Out32(Freq_Meter_PID_GainD_Addr, profile->kd);
		Xil_Out32(Freq_Meter_Coefd_Filter_Addr, profile->dCoeff);
	} else {
		Xil_Out32(PLL0_PID_GainP_Addr, profile->kp);
		Xil_Out32(PLL0_PID_GainI_Addr, profile->ki);
		Xil_Out32(PLL0_PID_GainI2_Addr, profile->kii);
		Xil_Out32(PLL0_PID_GainD_Addr, profile->kd);
		Xil_Out32(PLL0_Coefd_Filter_Addr, profile->dCoeff);
	}
	Autotune_ReadProfile(ctx, &active);
	Xil_Out32(Autotune_ManualOffsetAddr(ctx), ctx->originalManualOffset);
	Xil_Out32(Autotune_LockAddr(ctx), 1U);
	return Autotune_ProfileEqual(&active, profile);
}

// 每次开启新的评价窗口前清空统计数据
static void Autotune_ResetMetrics(AutotuneMetrics *metrics)
{
	metrics->amplitudeSum = 0U;
	metrics->absFreqSum = 0U;
	metrics->absPhaseSum = 0U;
	metrics->amplitudeMin = 0xFFFFFFFFU;
	metrics->amplitudeMax = 0U;
	metrics->sampleCount = 0U;
	metrics->lockedCount = 0U;
}

static void Autotune_Sample(AutotuneContext *ctx)
{
	u32 amplitude;
	u32 frequency;
	u32 phase;
	u32 status;
	if(ctx->target == AUTOTUNE_TARGET_FREQ) {
		amplitude = Xil_In32(Freq_Meter_Amplitude_Addr) & 0xFFFFU;
		frequency = Xil_In32(Freq_Meter_inst_frequency_Addr);
		phase = Xil_In32(Freq_Meter_PLL_phase_residuals_Addr);
	} else {
		amplitude = Xil_In32(DDC0_Amplitude) & 0xFFFFU;
		frequency = Xil_In32(DDC0_inst_frequency);
		phase = Xil_In32(PLL0_phase_residuals);
	}
	status = Autotune_StatusRegister(ctx);
	ctx->metrics.amplitudeSum += amplitude;
	ctx->metrics.absFreqSum += Autotune_Abs32(Autotune_SignExtend14(frequency));
	ctx->metrics.absPhaseSum += Autotune_Abs32((s32)phase);
	if(amplitude < ctx->metrics.amplitudeMin) ctx->metrics.amplitudeMin = amplitude;
	if(amplitude > ctx->metrics.amplitudeMax) ctx->metrics.amplitudeMax = amplitude;
	ctx->metrics.sampleCount++;
	if((status & 0x3FU) == 0x30U) ctx->metrics.lockedCount++;
}

static u16 Autotune_Score(const AutotuneMetrics *metrics)
{
	u64 score;
	if(metrics->sampleCount == 0U) return 0xFFFFU;
	score = metrics->absFreqSum / metrics->sampleCount;
	score += (metrics->absPhaseSum / metrics->sampleCount) >> 10;
	score += ((u64)(metrics->sampleCount - metrics->lockedCount) * 1000U) / metrics->sampleCount;
	return (score > 0xFFFFU) ? 0xFFFFU : (u16)score;
}

// 切换状态机状态
static void Autotune_SetState(AutotuneContext *ctx, AutotuneExecState state, u32 now)
{
	ctx->execState = state;
	ctx->stateStartMs = now;
}

// 释放状态机
static void Autotune_ReleaseOwner(AutotuneContext *ctx)
{
	if(AutotuneOwner == ctx) AutotuneOwner = NULL;
	ctx->busy = 0U;
}

static void Autotune_Fail(AutotuneContext *ctx, AutotuneResult result, u32 now)
{
	ctx->done = 0U;
	ctx->failed = 1U;
	ctx->paramsValid = 0U;
	ctx->result = result;
	ctx->healthState = (result == AUTOTUNE_RESULT_READBACK_ERROR) ? AUTOTUNE_HEALTH_FAULT : AUTOTUNE_HEALTH_LOST;
	Autotune_SetState(ctx, AUTOTUNE_EXEC_FAILED, now);
	Autotune_ReleaseOwner(ctx);
}

/*
 * bit 0      done
 * bit 1      busy
 * bit 2      failed
 * bit 3      paramsValid
 * bit 4      lockValid
 * bit 5      retunePending
 * bit 6      recover policy enabled
 * bit 7      automatic policy enabled
 *
 * bit 8~11   execState
 * bit 12~15  healthState
 * bit 16~23  result
 * bit 24~31  runId
 */
static u32 Autotune_StatusWord(const AutotuneContext *ctx, AutotuneResult responseResult)
{
	u32 status = 0U;
	AutotuneResult result = (responseResult == (AutotuneResult)0xFF) ? ctx->result : responseResult;
	status |= ctx->done ? (1U << 0) : 0U;
	status |= ctx->busy ? (1U << 1) : 0U;
	status |= ctx->failed ? (1U << 2) : 0U;
	status |= ctx->paramsValid ? (1U << 3) : 0U;
	status |= ctx->lockValid ? (1U << 4) : 0U;
	status |= ctx->retunePending ? (1U << 5) : 0U;
	status |= (ctx->policy == AUTOTUNE_POLICY_BOOT_AND_RECOVER) ? (1U << 6) : 0U;
	status |= (ctx->policy != AUTOTUNE_POLICY_HOST_ONLY) ? (1U << 7) : 0U;
	status |= ((u32)ctx->execState & 0x0FU) << 8;
	status |= ((u32)ctx->healthState & 0x0FU) << 12;
	status |= ((u32)result & 0xFFU) << 16;
	status |= ((u32)ctx->runId) << 24;
	return status;
}

static u8 Autotune_Ready(const AutotuneContext *ctx)
{
	return ctx->done && ctx->paramsValid && ctx->lockValid;
}

/*
 * Payload:
 *
 * [4]      protocol version
 * [5]      action
 *
 * [6:9]    status word, little-endian
 *
 * [10]     progress
 * [11]     current profile id
 * [12]     active profile id
 * [13]     best profile id
 *
 * [14:15]  current score
 * [16:17]  best score
 *
 * [18:21]  elapsed time(ms)
 */
static void Autotune_SendResponse(AutotuneContext *ctx, u8 action, AutotuneResult responseResult)
{
	u32 status = Autotune_StatusWord(ctx, responseResult);
	u32 elapsed = ctx->runStartMs ? Autotune_Elapsed(Autotune_Millis(), ctx->runStartMs) : 0U;
	Uart0_TX_Buff[4] = AUTOTUNE_PROTOCOL_VERSION;
	Uart0_TX_Buff[5] = action;
	Uart0_TX_Buff[6] = status & 0xFFU;
	Uart0_TX_Buff[7] = (status >> 8) & 0xFFU;
	Uart0_TX_Buff[8] = (status >> 16) & 0xFFU;
	Uart0_TX_Buff[9] = (status >> 24) & 0xFFU;
	Uart0_TX_Buff[10] = ctx->progress;
	Uart0_TX_Buff[11] = ctx->currentProfileId;
	Uart0_TX_Buff[12] = ctx->activeProfileId;
	Uart0_TX_Buff[13] = ctx->bestProfileId;
	Uart0_TX_Buff[14] = ctx->currentScore & 0xFFU;
	Uart0_TX_Buff[15] = (ctx->currentScore >> 8) & 0xFFU;
	Uart0_TX_Buff[16] = ctx->bestScore & 0xFFU;
	Uart0_TX_Buff[17] = (ctx->bestScore >> 8) & 0xFFU;
	Uart0_TX_Buff[18] = elapsed & 0xFFU;
	Uart0_TX_Buff[19] = (elapsed >> 8) & 0xFFU;
	Uart0_TX_Buff[20] = (elapsed >> 16) & 0xFFU;
	Uart0_TX_Buff[21] = (elapsed >> 24) & 0xFFU;
	PC_HOST_ASK_Pack(18);
}

static void Autotune_Start(AutotuneContext *ctx, u32 now)
{
	ctx->runId++;
	ctx->done = 0U;
	ctx->failed = 0U;
	ctx->busy = 1U;
	ctx->retunePending = 0U;
	ctx->cancelRequested = 0U;
	ctx->originalProfileValid = 0U;							// PRECHECK尚未保存originalProfile
	ctx->result = AUTOTUNE_RESULT_ACCEPTED;					// START只是被接受，还没有成功完成
	ctx->progress = 1U;	
	ctx->currentProfileId = AUTOTUNE_PROFILE_BASELINE;
	ctx->bestProfileId = AUTOTUNE_PROFILE_NONE;
	ctx->currentScore = 0xFFFFU;							// 0xFFFF表示尚未获得有效score
	ctx->bestScore = 0xFFFFU;
	ctx->runStartMs = now;
	Autotune_ResetMetrics(&ctx->metrics);
	AutotuneOwner = ctx;
	Autotune_SetState(ctx, AUTOTUNE_EXEC_PRECHECK, now);
}

static void Autotune_Command(AutotuneContext *ctx)
{
	u8 action = (PC_HOST_CMD_data_Size >= 1U) ? PC_HOST_CMD_data_Buff[4] : 0xFFU;
	u32 now = Autotune_Millis();
	AutotuneResult response = (AutotuneResult)0xFF;

	switch(action) {
	case AUTOTUNE_ACTION_QUERY:
		break;
	case AUTOTUNE_ACTION_START:
		if(ctx->busy || (AutotuneOwner != NULL && AutotuneOwner != ctx)) {
			response = AUTOTUNE_RESULT_BUSY;
		} else {
			Autotune_Start(ctx, now);
		}
		break;
	case AUTOTUNE_ACTION_CANCEL:
		if(ctx->busy) ctx->cancelRequested = 1U;
		else response = AUTOTUNE_RESULT_REJECTED;
		break;
	case AUTOTUNE_ACTION_CLEAR:
		if(ctx->busy) {
			response = AUTOTUNE_RESULT_BUSY;
		} else {
			ctx->done = 0U;
			ctx->failed = 0U;
			ctx->result = AUTOTUNE_RESULT_NONE;
			ctx->progress = 0U;
			Autotune_SetState(ctx, AUTOTUNE_EXEC_IDLE, now);
		}
		break;
	case AUTOTUNE_ACTION_SET_POLICY:
		if(ctx->busy) {
			response = AUTOTUNE_RESULT_BUSY;
		} else if(PC_HOST_CMD_data_Size < 2U || PC_HOST_CMD_data_Buff[5] > AUTOTUNE_POLICY_BOOT_AND_RECOVER) {
			response = AUTOTUNE_RESULT_INVALID_POLICY;
		} else {
			ctx->policy = (AutotunePolicy)PC_HOST_CMD_data_Buff[5];
		}
		break;
	default:
		response = AUTOTUNE_RESULT_INVALID_ACTION;
		break;
	}
	Autotune_SendResponse(ctx, action, response);
}

static void Autotune_Task(AutotuneContext *ctx, u32 now)
{
	if(Autotune_Elapsed(now, ctx->lastServiceMs) < AUTOTUNE_SERVICE_PERIOD_MS) return;		// 50ms调用一次
	ctx->lastServiceMs = now;

	if(ctx->paramsValid && !ctx->busy) {
		ctx->lockValid = ((Autotune_StatusRegister(ctx) & 0x3FU) == 0x30U);
		ctx->healthState = ctx->lockValid ? AUTOTUNE_HEALTH_VALID : AUTOTUNE_HEALTH_LOST;
		if(!ctx->lockValid && ctx->policy == AUTOTUNE_POLICY_BOOT_AND_RECOVER) ctx->retunePending = 1U;
	}
	// 没任务直接返回
	if(!ctx->busy) return;
	if(ctx->cancelRequested && ctx->execState != AUTOTUNE_EXEC_ROLLBACK) {
		Autotune_SetState(ctx, AUTOTUNE_EXEC_ROLLBACK, now);
	}

	switch(ctx->execState) {
	case AUTOTUNE_EXEC_PRECHECK:
		Autotune_ReadProfile(ctx, &ctx->originalProfile);
		ctx->originalManualOffset = Xil_In32(Autotune_ManualOffsetAddr(ctx));
		ctx->originalProfileValid = 1U;
		if((Autotune_StatusRegister(ctx) & 0x20U) == 0U) {
			Autotune_Fail(ctx, AUTOTUNE_RESULT_NOT_LOCKED, now);
			break;
		}
		ctx->progress = 10U;
		Autotune_ResetMetrics(&ctx->metrics);
		Autotune_SetState(ctx, AUTOTUNE_EXEC_BASELINE, now);
		break;
	case AUTOTUNE_EXEC_BASELINE:
		Autotune_Sample(ctx);
		ctx->progress = 10U + (u8)((Autotune_Elapsed(now, ctx->stateStartMs) * 35U) / AUTOTUNE_BASELINE_TIME_MS);
		if(Autotune_Elapsed(now, ctx->stateStartMs) >= AUTOTUNE_BASELINE_TIME_MS) {
			ctx->currentScore = Autotune_Score(&ctx->metrics);
			if(ctx->metrics.sampleCount < 3U || ctx->metrics.lockedCount * 2U < ctx->metrics.sampleCount) {
				Autotune_Fail(ctx, AUTOTUNE_RESULT_NOT_LOCKED, now);
			} else {
				ctx->bestScore = ctx->currentScore;
				ctx->bestProfileId = AUTOTUNE_PROFILE_BASELINE;
				Autotune_SetState(ctx, AUTOTUNE_EXEC_SELECT_BEST, now);
			}
		}
		break;
	case AUTOTUNE_EXEC_SELECT_BEST:
		ctx->progress = 50U;
		Autotune_SetState(ctx, AUTOTUNE_EXEC_APPLY_BEST, now);
		break;
	case AUTOTUNE_EXEC_APPLY_BEST:
		if(!Autotune_ApplyProfile(ctx, &ctx->originalProfile)) {
			Autotune_SetState(ctx, AUTOTUNE_EXEC_ROLLBACK, now);
		} else {
			ctx->activeProfileId = AUTOTUNE_PROFILE_BASELINE;
			ctx->progress = 60U;
			Autotune_ResetMetrics(&ctx->metrics);
			Autotune_SetState(ctx, AUTOTUNE_EXEC_VERIFY, now);
		}
		break;
	case AUTOTUNE_EXEC_VERIFY:
		Autotune_Sample(ctx);
		ctx->progress = 60U + (u8)((Autotune_Elapsed(now, ctx->stateStartMs) * 39U) / AUTOTUNE_VERIFY_TIME_MS);
		if(Autotune_Elapsed(now, ctx->stateStartMs) >= AUTOTUNE_VERIFY_TIME_MS) {
			if(ctx->metrics.sampleCount < 3U || ctx->metrics.lockedCount * 2U < ctx->metrics.sampleCount) {
				Autotune_SetState(ctx, AUTOTUNE_EXEC_ROLLBACK, now);
			} else {
				ctx->done = 1U;
				ctx->failed = 0U;
				ctx->paramsValid = 1U;
				ctx->lockValid = 1U;
				ctx->result = AUTOTUNE_RESULT_SUCCESS;
				ctx->healthState = AUTOTUNE_HEALTH_VALID;
				ctx->progress = 100U;
				Autotune_SetState(ctx, AUTOTUNE_EXEC_DONE, now);
				Autotune_ReleaseOwner(ctx);
			}
		}
		break;
	case AUTOTUNE_EXEC_ROLLBACK:
		if(ctx->originalProfileValid && !Autotune_ApplyProfile(ctx, &ctx->originalProfile)) {
			Autotune_Fail(ctx, AUTOTUNE_RESULT_READBACK_ERROR, now);
		} else if(ctx->cancelRequested) {
			ctx->done = 0U;
			ctx->failed = 0U;
			ctx->result = AUTOTUNE_RESULT_CANCELED;
			ctx->progress = 0U;
			Autotune_SetState(ctx, AUTOTUNE_EXEC_CANCELED, now);
			Autotune_ReleaseOwner(ctx);
		} else {
			Autotune_Fail(ctx, AUTOTUNE_RESULT_NOT_LOCKED, now);
		}
		break;
	default:
		break;
	}
}

static void Autotune_InitContext(AutotuneContext *ctx, AutotuneTarget target)
{
	u32 now = Autotune_Millis();
	ctx->target = target;
	ctx->policy = AUTOTUNE_POLICY_HOST_ONLY;
	ctx->execState = AUTOTUNE_EXEC_IDLE;
	ctx->healthState = AUTOTUNE_HEALTH_UNINITIALIZED;
	ctx->result = AUTOTUNE_RESULT_NONE;
	ctx->runId = 0U;
	ctx->progress = 0U;
	ctx->currentProfileId = AUTOTUNE_PROFILE_NONE;
	ctx->activeProfileId = AUTOTUNE_PROFILE_NONE;
	ctx->bestProfileId = AUTOTUNE_PROFILE_NONE;
	ctx->currentScore = 0xFFFFU;
	ctx->bestScore = 0xFFFFU;
	ctx->done = ctx->busy = ctx->failed = 0U;
	ctx->paramsValid = ctx->lockValid = ctx->retunePending = ctx->cancelRequested = 0U;
	ctx->originalProfileValid = 0U;
	ctx->runStartMs = ctx->stateStartMs = ctx->lastServiceMs = now;
	Autotune_ResetMetrics(&ctx->metrics);
}

static void Autotune_Init(void)
{
	AutotuneOwner = NULL;
	Autotune_InitContext(&FreqAutotune, AUTOTUNE_TARGET_FREQ);
	Autotune_InitContext(&DpllAutotune, AUTOTUNE_TARGET_DPLL);
}

static void Autotune_Service(void)
{
	u32 now = Autotune_Millis();
	Autotune_Task(&FreqAutotune, now);
	Autotune_Task(&DpllAutotune, now);
}

static void Autotune_ManualOverride(AutotuneContext *ctx)
{
	ctx->paramsValid = 0U;
	ctx->retunePending = 0U;
	ctx->activeProfileId = AUTOTUNE_PROFILE_NONE;
	ctx->healthState = AUTOTUNE_HEALTH_UNINITIALIZED;
}

void CMD_01_READ_MWS_SETTING(void)
{
	uint32_t Error_Code;
	uint32_t Freq;
	uint8_t pwr;
	Error_Code = Uart1_STM8_Get_MWS_CFG(&Freq,&pwr);
	if(Error_Code)
	{
		PC_HOST_Send_ASK(0xFE,Error_Code);
		return;
	}
	Uart0_TX_Buff[4] = Freq&0xFF;
	Uart0_TX_Buff[5] = (Freq>>8)&0xFF;
	Uart0_TX_Buff[6] = (Freq>>16)&0xFF;
	Uart0_TX_Buff[7] = (Freq>>24)&0xFF;
	Uart0_TX_Buff[8] = pwr;
	PC_HOST_ASK_Pack(5);
}
void CMD_02_READ_MWS_STATUS(void)
{
	uint32_t Error_Code;
	uint8_t sta;
	Error_Code = Uart1_STM8_Read_MWS_Status(&sta);
	if(Error_Code)
	{
		Uart0_TX_Buff[4] = 0x80;
		PC_HOST_ASK_Pack(1);
		return;
	}
	Uart0_TX_Buff[4] = sta;
	PC_HOST_ASK_Pack(1);

}
void CMD_03_READ_PLL_FREQ_SETTING(void)
{
	uint32_t i;
	i = Xil_In32(DAC0_Centre_Frequency_Addr);
	Uart0_TX_Buff[4] = i&0xFF;
	Uart0_TX_Buff[5] = (i>>8)&0xFF;
	Uart0_TX_Buff[6] = (i>>16)&0xFF;
	Uart0_TX_Buff[7] = (i>>24)&0xFF;

	PC_HOST_ASK_Pack(4);
}
void CMD_04_READ_PLL_MUL_DIV_SETTING(void)
{
	uint32_t i;
	i = Xil_In32(VOC_Fre_Mul_Addr);
	Uart0_TX_Buff[4] = i&0xFF;
	Uart0_TX_Buff[5] = (i>>8)&0xFF;
	i = Xil_In32(VOC_Fre_Div_Addr);
	Uart0_TX_Buff[6] = i&0xFF;
	Uart0_TX_Buff[7] = (i>>8)&0xFF;

	PC_HOST_ASK_Pack(4);
}
void CMD_05_READ_PLL_THRESHOLD_SETTING(void)
{
	uint32_t i;
	i = Xil_In32(DAC0_Phase_Residuals_Threshold_Addr);
	Uart0_TX_Buff[4] = i&0xFF;
	Uart0_TX_Buff[5] = (i>>8)&0xFF;
	i = Xil_In32(DAC0_Freq_Residuals_Threshold_Addr);
	Uart0_TX_Buff[6] = i&0xFF;
	Uart0_TX_Buff[7] = (i>>8)&0xFF;

	PC_HOST_ASK_Pack(4);
}
void CMD_06_READ_PLL_LIMIT_SETTING(void)
{
	uint32_t i;
	i = Xil_In32(PID_Freq_Pos_Limit_Addr);
	Uart0_TX_Buff[4] = (i>>16)&0xFF;
	Uart0_TX_Buff[5] = (i>>24)&0xFF;
	i = Xil_In32(PID_Freq_Neg_Limit_Addr);
	Uart0_TX_Buff[6] = (i>>16)&0xFF;
	Uart0_TX_Buff[7] = (i>>24)&0xFF;

	PC_HOST_ASK_Pack(4);
}
void CMD_07_READ_PLL_PID_SETTING(void)
{
	uint32_t i;
	i = Xil_In32(PLL0_PID_GainP_Addr);
	Uart0_TX_Buff[4] = i&0xFF;
	Uart0_TX_Buff[5] = (i>>8)&0xFF;
	Uart0_TX_Buff[6] = (i>>16)&0xFF;
	Uart0_TX_Buff[7] = (i>>24)&0xFF;
	i = Xil_In32(PLL0_PID_GainI_Addr);
	Uart0_TX_Buff[8] = i&0xFF;
	Uart0_TX_Buff[9] = (i>>8)&0xFF;
	Uart0_TX_Buff[10] = (i>>16)&0xFF;
	Uart0_TX_Buff[11] = (i>>24)&0xFF;
	i = Xil_In32(PLL0_PID_GainI2_Addr);
	Uart0_TX_Buff[12] = i&0xFF;
	Uart0_TX_Buff[13] = (i>>8)&0xFF;
	Uart0_TX_Buff[14] = (i>>16)&0xFF;
	Uart0_TX_Buff[15] = (i>>24)&0xFF;
	i = Xil_In32(PLL0_PID_GainD_Addr);
	Uart0_TX_Buff[16] = i&0xFF;
	Uart0_TX_Buff[17] = (i>>8)&0xFF;
	Uart0_TX_Buff[18] = (i>>16)&0xFF;
	Uart0_TX_Buff[19] = (i>>24)&0xFF;

	PC_HOST_ASK_Pack(16);
}
void CMD_08_READ_PLL_AMP_SETTING(void)
{
	uint32_t i;
	i = Xil_In32(DAC0_VOC_Amplitude_Addr);
	Uart0_TX_Buff[4] = i&0xFF;
	Uart0_TX_Buff[5] = (i>>8)&0xFF;

	PC_HOST_ASK_Pack(2);
}
void CMD_09_PLL_STATUS(void)
{
	uint32_t i,data;
	i = Xil_In32(PLL0_Output_Limit_Average);
	Uart0_TX_Buff[4] = i&0xFF;
	Uart0_TX_Buff[5] = (i>>8)&0xFF;
	Uart0_TX_Buff[6] = (i>>16)&0xFF;
	Uart0_TX_Buff[7] = (i>>24)&0xFF;

	i = Xil_In32(PLL0_phase_residuals);
	Uart0_TX_Buff[8] = i&0xFF;
	Uart0_TX_Buff[9] = (i>>8)&0xFF;
	Uart0_TX_Buff[10] = (i>>16)&0xFF;
	Uart0_TX_Buff[11] = (i>>24)&0xFF;

	i = Xil_In32(DDC0_inst_frequency);
	Uart0_TX_Buff[12] = (i>>0)&0xFF;
	Uart0_TX_Buff[13] = (i>>8)&0xFF;

	i = Xil_In32(System_Statue);
	data = i&0x3F;
	Uart0_TX_Buff[14] = PLL_Lock_Status|data;
	if(Autotune_Ready(&DpllAutotune)) Uart0_TX_Buff[14] |= 0x80U;
	if(DpllAutotune.busy) Uart0_TX_Buff[14] |= 0x40U;

	PC_HOST_ASK_Pack(11);
}

void CMD_0A_READ_VERSION(void)
{
	Uart0_TX_Buff[4] = 2;
	PC_HOST_ASK_Pack(1);
}

uint16_t DataLog_Buff[2048];

void CMD_0C_DataLog_Read(void)
{
	uint32_t i,checksum = 0;

	Xil_Out32(ADC_LOG_Trigger_Addr,1);
	usleep(100);

	for(i=0;i<2048;i++)
	{
		DataLog_Buff[i] = Xil_In32(ADC_LOG_Buff_Begin_Addr + i*4);
		checksum += DataLog_Buff[i]&0xFF;
		checksum += (DataLog_Buff[i]>>8)&0xFF;
	}
	Uart0_TX_Buff[4] = 0x00;
	Uart0_TX_Buff[5] = 0x10;
	Uart0_TX_Buff[6] = 0x00;
	Uart0_TX_Buff[7] = 0x00;

	Uart0_TX_Buff[8] = checksum&0xFF;
	Uart0_TX_Buff[9] = (checksum>>8)&0xFF;

	PC_HOST_ASK_Pack(6);
	for(i=0;i<2048;i++)
	{
		XUartPs_SendByte(XUartPs_uart0.Config.BaseAddress,DataLog_Buff[i]);
		XUartPs_SendByte(XUartPs_uart0.Config.BaseAddress,DataLog_Buff[i]>>8);
	}

}


void CMD_10_READ_FREQMETER_FREQ_SETTING(void)
{
	uint32_t i;
	i = Xil_In32(Freq_Meter_Centre_Frequency_Addr);
	Uart0_TX_Buff[4] = i&0xFF;
	Uart0_TX_Buff[5] = (i>>8)&0xFF;
	Uart0_TX_Buff[6] = (i>>16)&0xFF;
	Uart0_TX_Buff[7] = (i>>24)&0xFF;

	PC_HOST_ASK_Pack(4);
}

void CMD_11_READ_FREQMETER_THRESHOLD_SETTING(void)
{
	uint32_t i;
	i = Xil_In32(Freq_Meter_Phase_Residuals_Threshold_Addr);
	Uart0_TX_Buff[4] = i&0xFF;
	Uart0_TX_Buff[5] = (i>>8)&0xFF;
	i = Xil_In32(Freq_Meter_Freq_Residuals_Threshold_Addr);
	Uart0_TX_Buff[6] = i&0xFF;
	Uart0_TX_Buff[7] = (i>>8)&0xFF;

	PC_HOST_ASK_Pack(4);
}
void CMD_12_READ_FREQMETER_LIMIT_SETTING(void)
{
	uint32_t i;
	i = Xil_In32(Freq_Meter_Freq_Pos_Limit_Addr);
	Uart0_TX_Buff[4] = (i>>16)&0xFF;
	Uart0_TX_Buff[5] = (i>>24)&0xFF;
	i = Xil_In32(Freq_Meter_Freq_Neg_Limit_Addr);
	Uart0_TX_Buff[6] = (i>>16)&0xFF;
	Uart0_TX_Buff[7] = (i>>24)&0xFF;

	PC_HOST_ASK_Pack(4);
}
void CMD_13_READ_FREQMETER_PID_SETTING(void)
{
	uint32_t i;
	i = Xil_In32(Freq_Meter_PID_GainP_Addr);
	Uart0_TX_Buff[4] = i&0xFF;
	Uart0_TX_Buff[5] = (i>>8)&0xFF;
	Uart0_TX_Buff[6] = (i>>16)&0xFF;
	Uart0_TX_Buff[7] = (i>>24)&0xFF;
	i = Xil_In32(Freq_Meter_PID_GainI_Addr);
	Uart0_TX_Buff[8] = i&0xFF;
	Uart0_TX_Buff[9] = (i>>8)&0xFF;
	Uart0_TX_Buff[10] = (i>>16)&0xFF;
	Uart0_TX_Buff[11] = (i>>24)&0xFF;
	i = Xil_In32(Freq_Meter_PID_GainI2_Addr);
	Uart0_TX_Buff[12] = i&0xFF;
	Uart0_TX_Buff[13] = (i>>8)&0xFF;
	Uart0_TX_Buff[14] = (i>>16)&0xFF;
	Uart0_TX_Buff[15] = (i>>24)&0xFF;
	i = Xil_In32(Freq_Meter_PID_GainD_Addr);
	Uart0_TX_Buff[16] = i&0xFF;
	Uart0_TX_Buff[17] = (i>>8)&0xFF;
	Uart0_TX_Buff[18] = (i>>16)&0xFF;
	Uart0_TX_Buff[19] = (i>>24)&0xFF;

	PC_HOST_ASK_Pack(16);
}
void CMD_14_READ_FREQMETER_STATUS(void)
{
	uint32_t i,data;

	i = Xil_In32(Freq_Meter_PLL_phase_residuals_Addr);
	Uart0_TX_Buff[4] = i&0xFF;
	Uart0_TX_Buff[5] = (i>>8)&0xFF;
	Uart0_TX_Buff[6] = (i>>16)&0xFF;
	Uart0_TX_Buff[7] = (i>>24)&0xFF;

	i = Xil_In32(Freq_Meter_inst_frequency_Addr);
	Uart0_TX_Buff[8] = (i>>0)&0xFF;
	Uart0_TX_Buff[9] = (i>>8)&0xFF;

	i = Xil_In32(Freq_Meter_System_Statue_Addr);
	data = i&0x3F;
	Uart0_TX_Buff[10] = 0x20|data;
	if(Autotune_Ready(&FreqAutotune)) Uart0_TX_Buff[10] |= 0x80U;
	if(FreqAutotune.busy) Uart0_TX_Buff[10] |= 0x40U;

	PC_HOST_ASK_Pack(7);
}

void CMD_15_READ_FREQMETER_RUN_STATUS(void)
{
	uint32_t data;

	data = Xil_In32(Freq_Meter_Run_Statue_Addr);
	if(data != 0)Uart0_TX_Buff[4] = 1;
	else Uart0_TX_Buff[4] = 0;

	PC_HOST_ASK_Pack(1);
}

void CMD_16_READ_FREQMETER_TIMER(void)
{
	uint32_t i;

	i = Xil_In32(Freq_Meter_Gate_Time_L_Addr);
	Uart0_TX_Buff[4] = i&0xFF;
	Uart0_TX_Buff[5] = (i>>8)&0xFF;
	Uart0_TX_Buff[6] = (i>>16)&0xFF;
	Uart0_TX_Buff[7] = (i>>24)&0xFF;

	i = Xil_In32(Freq_Meter_Gate_Time_H_Addr);
	Uart0_TX_Buff[8] = i&0xFF;
	Uart0_TX_Buff[9] = (i>>8)&0xFF;

	PC_HOST_ASK_Pack(6);
}

void CMD_17_READ_FREQMETER_CNT(void)
{
	uint32_t i;

	i = Xil_In32(Freq_Meter_DataL_Output_Addr);
	Uart0_TX_Buff[4] = i&0xFF;
	Uart0_TX_Buff[5] = (i>>8)&0xFF;
	Uart0_TX_Buff[6] = (i>>16)&0xFF;
	Uart0_TX_Buff[7] = (i>>24)&0xFF;

	i = Xil_In32(Freq_Meter_DataM_Output_Addr);
	Uart0_TX_Buff[8] = i&0xFF;
	Uart0_TX_Buff[9] = (i>>8)&0xFF;
	Uart0_TX_Buff[10] = (i>>16)&0xFF;
	Uart0_TX_Buff[11] = (i>>24)&0xFF;

	i = Xil_In32(Freq_Meter_DataH_Output_Addr);
	Uart0_TX_Buff[12] = i&0xFF;
	Uart0_TX_Buff[13] = (i>>8)&0xFF;

	Uart0_TX_Buff[14] = Freq_meter_gate_time_cache&0xFF;
	Uart0_TX_Buff[15] = (Freq_meter_gate_time_cache>>8)&0xFF;
	Uart0_TX_Buff[16] = (Freq_meter_gate_time_cache>>16)&0xFF;
	Uart0_TX_Buff[17] = (Freq_meter_gate_time_cache>>24)&0xFF;
	Uart0_TX_Buff[18] = (Freq_meter_gate_time_cache>>32)&0xFF;
	Uart0_TX_Buff[19] = (Freq_meter_gate_time_cache>>40)&0xFF;

	PC_HOST_ASK_Pack(16);
}

void CMD_1A_READ_VBIAS_DAC(void)
{
	uint32_t Error_Code;
	int16_t dataA,dataB;

	Error_Code = Uart1_STM8_Read_Vbias_DAC(&dataA,&dataB);
	if(Error_Code)
	{
		PC_HOST_Send_ASK(0xFE,Error_Code);
		return;
	}
	Uart0_TX_Buff[4] = dataA&0xFF;
	Uart0_TX_Buff[5] = (dataA>>8)&0xFF;

	Uart0_TX_Buff[6] = dataB&0xFF;
	Uart0_TX_Buff[7] = (dataB>>8)&0xFF;

	PC_HOST_ASK_Pack(4);
}

void CMD_1B_READ_VBIAS_ADC(void)
{
	uint32_t Error_Code;
	uint16_t dataA,dataB;

	Error_Code = Uart1_STM8_Read_Vbias_ADC(&dataA,&dataB);
	if(Error_Code)
	{
		PC_HOST_Send_ASK(0xFE,Error_Code);
		return;
	}
	Uart0_TX_Buff[4] = dataA&0xFF;
	Uart0_TX_Buff[5] = (dataA>>8)&0xFF;

	Uart0_TX_Buff[6] = dataB&0xFF;
	Uart0_TX_Buff[7] = (dataB>>8)&0xFF;

	PC_HOST_ASK_Pack(4);
}


void CMD_81_WRITE_MWS_FREQ_PWR(void)
{
	uint32_t Error_Code;
	uint32_t freq;
	uint8_t pwr = PC_HOST_CMD_data_Buff[8];
	freq = PC_HOST_CMD_data_Buff[4]|((uint8_t)PC_HOST_CMD_data_Buff[5]<<8)|((uint8_t)PC_HOST_CMD_data_Buff[6]<<16)|((uint8_t)PC_HOST_CMD_data_Buff[7]<<24);
	Error_Code = Uart1_STM8_Set_MWS_CFG(freq,pwr);
	PC_HOST_Send_ASK_Only(Error_Code);
}
void CMD_82_WRITE_PLL_FREQ(void)
{
	*((uint32_t*)&STM8_EEPROM_Data[0+8]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[4]);
	Xil_Out32(DAC0_Centre_Frequency_Addr,*((uint32_t*)&STM8_EEPROM_Data[0+8]));//中心频率
	PC_HOST_Send_ASK_Only(0);
}
void CMD_83_WRITE_PLL_MUL_DIV(void)
{
	*((uint32_t*)&STM8_EEPROM_Data[4+8]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[4]);
	Xil_Out32(VOC_Fre_Mul_Addr,*((uint16_t*)&STM8_EEPROM_Data[4+8]));//MUL
	Xil_Out32(VOC_Fre_Div_Addr,*((uint16_t*)&STM8_EEPROM_Data[6+8]));//DIV
	PC_HOST_Send_ASK_Only(0);
}
void CMD_84_WRITE_PLL_THRESHOLD(void)
{
	*((uint32_t*)&STM8_EEPROM_Data[28+8]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[4]);
    Xil_Out32(DAC0_Freq_Residuals_Threshold_Addr,*((uint16_t*)&STM8_EEPROM_Data[28+8]));//14Bit
    Xil_Out32(DAC0_Phase_Residuals_Threshold_Addr,*((uint16_t*)&STM8_EEPROM_Data[30+8]));//32Bit
	PC_HOST_Send_ASK_Only(0);
}
void CMD_85_WRITE_PLL_LIMIT(void)
{
	uint32_t data;
	data = *((uint16_t*)&PC_HOST_CMD_data_Buff[4]);
	if(data > 0x7FFF) data = 0x7FFF;
	*((uint16_t*)&STM8_EEPROM_Data[24+8]) = data;
    Xil_Out32(PID_Freq_Pos_Limit_Addr,data<<16);//上位机储存和传入参数为高16bit写入到FPGA内部为32Bit

	data = *((uint16_t*)&PC_HOST_CMD_data_Buff[6]);
	if(data < 0x8000) data = 0x8000;
	*((uint16_t*)&STM8_EEPROM_Data[26+8]) = data;
    Xil_Out32(PID_Freq_Neg_Limit_Addr,data<<16);//上位机储存和传入参数为高16bit写入到FPGA内部为32Bit
	PC_HOST_Send_ASK_Only(0);
}
void CMD_86_WRITE_PLL_PID(void)
{
	if(DpllAutotune.busy) {
		PC_HOST_Send_ASK_Only(AUTOTUNE_RESULT_BUSY);
		return;
	}
	*((uint32_t*)&STM8_EEPROM_Data[8+8]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[4]);
	*((uint32_t*)&STM8_EEPROM_Data[12+8]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[8]);
	*((uint32_t*)&STM8_EEPROM_Data[16+8]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[12]);
	*((uint32_t*)&STM8_EEPROM_Data[20+8]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[16]);
    Xil_Out32(PLL0_PID_GainP_Addr,*((uint32_t*)&STM8_EEPROM_Data[8+8]));
    Xil_Out32(PLL0_PID_GainI_Addr,*((uint32_t*)&STM8_EEPROM_Data[12+8]));
    Xil_Out32(PLL0_PID_GainI2_Addr,*((uint32_t*)&STM8_EEPROM_Data[16+8]));
    Xil_Out32(PLL0_PID_GainD_Addr,*((uint32_t*)&STM8_EEPROM_Data[20+8]));
	Autotune_ManualOverride(&DpllAutotune);
	PC_HOST_Send_ASK_Only(0);
}
void CMD_87_WRITE_PLL_AMP(void)
{
	*((uint16_t*)&STM8_EEPROM_Data[32+8]) = *((uint16_t*)&PC_HOST_CMD_data_Buff[4]);
	Xil_Out32(DAC0_VOC_Amplitude_Addr,*((uint16_t*)&STM8_EEPROM_Data[32+8]));//amplitude 15bit;
	PC_HOST_Send_ASK_Only(0);
}
void CMD_88_WRITE_MWS_ON(void)
{
	uint32_t Error_Code;
	Error_Code = Uart1_STM8_Set_RF_ON();
	PC_HOST_Send_ASK_Only(Error_Code);
}
void CMD_89_WRITE_MWS_OFF(void)
{
	uint32_t Error_Code;
	Error_Code = Uart1_STM8_Set_RF_OFF();
	PC_HOST_Send_ASK_Only(Error_Code);
}
void CMD_8C_LOAD_EEPROM(void)
{
	uint32_t Error_Code;
	if(DpllAutotune.busy) {
		PC_HOST_Send_ASK_Only(AUTOTUNE_RESULT_BUSY);
		return;
	}
	Error_Code = Uart1_STM8_Read_EEPROM();
	Write_PLL_Data_From_EEPROM();
	Autotune_ManualOverride(&DpllAutotune);
	PC_HOST_Send_ASK_Only(Error_Code);
}
void CMD_8D_SAVE_EEPROM(void)
{
	uint32_t Error_Code;
	Error_Code = Uart1_STM8_Save_EEPROM();
	PC_HOST_Send_ASK_Only(Error_Code);
}

void CMD_90_WRITE_FREQMETER_FREQ(void)
{
	*((uint32_t*)&STM8_EEPROM_Data[0+44]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[4]);
	Xil_Out32(Freq_Meter_Centre_Frequency_Addr,*((uint32_t*)&STM8_EEPROM_Data[0+44]));//中心频率
	PC_HOST_Send_ASK_Only(0);
}
void CMD_91_WRITE_FREQMETER_THRESHOLD(void)
{
	*((uint32_t*)&STM8_EEPROM_Data[4+44]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[4]);
    Xil_Out32(Freq_Meter_Freq_Residuals_Threshold_Addr,*((uint16_t*)&STM8_EEPROM_Data[4+44]));//14Bit
    Xil_Out32(Freq_Meter_Phase_Residuals_Threshold_Addr,*((uint16_t*)&STM8_EEPROM_Data[6+44]));//32Bit
	PC_HOST_Send_ASK_Only(0);
}
void CMD_92_WRITE_FREQMETER_LIMIT(void)
{
	uint32_t data;

	//*((uint16_t*)&STM8_EEPROM_Data[8+44]) = *((uint16_t*)&PC_HOST_CMD_data_Buff[4]);
	//*((uint16_t*)&STM8_EEPROM_Data[10+44]) = *((uint16_t*)&PC_HOST_CMD_data_Buff[6]);
    //data = *((uint16_t*)&STM8_EEPROM_Data[8+44]);
    //Xil_Out32(Freq_Meter_Freq_Pos_Limit_Addr,data<<16);//上位机储存和传入参数为高16bit写入到FPGA内部为32Bit
    //data = *((uint16_t*)&STM8_EEPROM_Data[10+44]);
    //Xil_Out32(Freq_Meter_Freq_Neg_Limit_Addr,data<<16);//上位机储存和传入参数为高16bit写入到FPGA内部为32Bit

	data = *((uint16_t*)&PC_HOST_CMD_data_Buff[4]);
	if(data > 0x7FFF) data = 0x3FFF;
	*((uint16_t*)&STM8_EEPROM_Data[8+44]) = data;
    Xil_Out32(PID_Freq_Pos_Limit_Addr,data<<16);//上位机储存和传入参数为高16bit写入到FPGA内部为32Bit

	data = *((uint16_t*)&PC_HOST_CMD_data_Buff[6]);
	if(data < 0xA000) data = 0xA000;
	*((uint16_t*)&STM8_EEPROM_Data[10+44]) = data;
    Xil_Out32(PID_Freq_Neg_Limit_Addr,data<<16);//上位机储存和传入参数为高16bit写入到FPGA内部为32Bit

	PC_HOST_Send_ASK_Only(0);
}
void CMD_93_WRITE_FREQMETER_PID(void)
{
	if(FreqAutotune.busy) {
		PC_HOST_Send_ASK_Only(AUTOTUNE_RESULT_BUSY);
		return;
	}
	*((uint32_t*)&STM8_EEPROM_Data[12+44]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[4]);
	*((uint32_t*)&STM8_EEPROM_Data[16+44]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[8]);
	*((uint32_t*)&STM8_EEPROM_Data[20+44]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[12]);
	*((uint32_t*)&STM8_EEPROM_Data[24+44]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[16]);
    Xil_Out32(Freq_Meter_PID_GainP_Addr,*((uint32_t*)&STM8_EEPROM_Data[12+44]));
    Xil_Out32(Freq_Meter_PID_GainI_Addr,*((uint32_t*)&STM8_EEPROM_Data[16+44]));
    Xil_Out32(Freq_Meter_PID_GainI2_Addr,*((uint32_t*)&STM8_EEPROM_Data[20+44]));
    Xil_Out32(Freq_Meter_PID_GainD_Addr,*((uint32_t*)&STM8_EEPROM_Data[24+44]));
	Autotune_ManualOverride(&FreqAutotune);
	PC_HOST_Send_ASK_Only(0);
}
void CMD_94_WRITE_FREQMETER_TIMER(void)
{
	*((uint32_t*)&STM8_EEPROM_Data[28+44]) = *((uint32_t*)&PC_HOST_CMD_data_Buff[4]);
	Xil_Out32(Freq_Meter_Gate_Time_L_Addr,*((uint32_t*)&STM8_EEPROM_Data[28+44]));//中心频率
	Xil_Out32(Freq_Meter_Gate_Time_H_Addr,*((uint16_t*)&PC_HOST_CMD_data_Buff[8]));//中心频率
	PC_HOST_Send_ASK_Only(0);
}
void CMD_9A_WRITE_VBIAS_DAC(void)
{
	int16_t dacA,dacB;
	uint32_t Error_Code;
	dacA = PC_HOST_CMD_data_Buff[4]|(PC_HOST_CMD_data_Buff[5]<<8);
	dacB = PC_HOST_CMD_data_Buff[6]|(PC_HOST_CMD_data_Buff[7]<<8);
	Error_Code = Uart1_STM8_Set_Vbias_DAC(dacA,dacB);
	PC_HOST_Send_ASK_Only(Error_Code);
}

void PC_HOST_CMD_Respond(void)
{
	uint32_t i;
	if(PC_HOST_CMD_RX_Mark)
	{
		usleep(200);
		if(PC_HOST_CMD_ASK == 0x00)
		{
			printf("OK_0x%.2XR\r\n",PC_HOST_CMD_GET);
			Uart0_TX_Buff[2] = PC_HOST_CMD_GET;
			switch(PC_HOST_CMD_GET)
			{
			case PC_CMD_READ_MWS_SETTING:
				CMD_01_READ_MWS_SETTING();
				break;
			case PC_CMD_READ_MWS_STATUS:
				CMD_02_READ_MWS_STATUS();
				break;
			case PC_CMD_READ_PLL_FREQ_SETTING:
				CMD_03_READ_PLL_FREQ_SETTING();
				break;
			case PC_CMD_READ_PLL_MUL_DIV_SETTING:
				CMD_04_READ_PLL_MUL_DIV_SETTING();
				break;
			case PC_CMD_READ_PLL_THRESHOLD_SETTING:
				CMD_05_READ_PLL_THRESHOLD_SETTING();
				break;
			case PC_CMD_READ_PLL_LIMIT_SETTING:
				CMD_06_READ_PLL_LIMIT_SETTING();
				break;
			case PC_CMD_READ_PLL_PID_SETTING:
				CMD_07_READ_PLL_PID_SETTING();
				break;
			case PC_CMD_READ_PLL_AMP_SETTING:
				CMD_08_READ_PLL_AMP_SETTING();
				break;
			case PC_CMD_READ_PLL_STATUS:
				CMD_09_PLL_STATUS();
				break;
			case PC_CMD_READ_VERSION:
				CMD_0A_READ_VERSION();
				break;

			case PC_CMD_READ_DATA_LOG:
				CMD_0C_DataLog_Read();
				break;

			case PC_CMD_READ_FREQMETER_FREQ_SETTING:
				CMD_10_READ_FREQMETER_FREQ_SETTING();
				break;
			case PC_CMD_READ_FREQMETER_THRESHOLD_SETTING:
				CMD_11_READ_FREQMETER_THRESHOLD_SETTING();
				break;
			case PC_CMD_READ_FREQMETER_LIMIT_SETTING:
				CMD_12_READ_FREQMETER_LIMIT_SETTING();
				break;
			case PC_CMD_READ_FREQMETER_PID_SETTING:
				CMD_13_READ_FREQMETER_PID_SETTING();
				break;
			case PC_CMD_READ_FREQMETER_STATUS:
				CMD_14_READ_FREQMETER_STATUS();
				break;
			case PC_CMD_READ_FREQMETER_RUN_STATUS:
				CMD_15_READ_FREQMETER_RUN_STATUS();
				break;
			case PC_CMD_READ_FREQMETER_TIMER_SETTING:
				CMD_16_READ_FREQMETER_TIMER();
				break;
			case PC_CMD_READ_FREQMETER_CNT:
				CMD_17_READ_FREQMETER_CNT();
				break;
			case PC_CMD_VBIAS_READ_DAC:
				CMD_1A_READ_VBIAS_DAC();
				break;
			case PC_CMD_VBIAS_READ_ADC:
				CMD_1B_READ_VBIAS_ADC();
				break;


			case PC_CMD_WRITE_MWS_FREQ_PWR:
				CMD_81_WRITE_MWS_FREQ_PWR();
				break;
			case PC_CMD_WRITE_PLL_FREQ:
				CMD_82_WRITE_PLL_FREQ();
				break;
			case PC_CMD_WRITE_PLL_MUL_DIV:
				CMD_83_WRITE_PLL_MUL_DIV();
				break;
			case PC_CMD_WRITE_PLL_THRESHOLD:
				CMD_84_WRITE_PLL_THRESHOLD();
				break;
			case PC_CMD_WRITE_PLL_LIMIT:
				CMD_85_WRITE_PLL_LIMIT();
				break;
			case PC_CMD_WRITE_PLL_PID:
				CMD_86_WRITE_PLL_PID();
				break;
			case PC_CMD_WRITE_PLL_AMP:
				CMD_87_WRITE_PLL_AMP();
				break;
			case PC_CMD_WRITE_MWS_ON:
				CMD_88_WRITE_MWS_ON();
				break;
			case PC_CMD_WRITE_MWS_OFF:
				CMD_89_WRITE_MWS_OFF();
				break;
			case PC_CMD_WRITE_PLL_ON:
				Xil_Out32(PLL0_Lock_Ctrl_Addr,1);
				PLL_Lock_Status = 0x20;
				PC_HOST_Send_ASK_Only(0);
				break;
			case PC_CMD_WRITE_PLL_OFF:
				Xil_Out32(PLL0_Lock_Ctrl_Addr,0);
				PLL_Lock_Status = 0x00;
				PC_HOST_Send_ASK_Only(0);
				break;
			case PC_CMD_LOAD_EEPROM:
				CMD_8C_LOAD_EEPROM();
				break;
			case PC_CMD_SAVE_EEPROM:
				CMD_8D_SAVE_EEPROM();
				break;
			case PC_CMD_PLL_RESET:
				Xil_Out32(Opal_Kelly_Reset_Trigger_Addr,0);
				PC_HOST_Send_ASK_Only(0);
				break;

			case PC_CMD_FREQMETER_FREQ:
				CMD_90_WRITE_FREQMETER_FREQ();
				break;
			case PC_CMD_FREQMETER_THRESHOLD:
				CMD_91_WRITE_FREQMETER_THRESHOLD();
				break;
			case PC_CMD_FREQMETER_LIMIT:
				CMD_92_WRITE_FREQMETER_LIMIT();
				break;
			case PC_CMD_FREQMETER_PID:
				CMD_93_WRITE_FREQMETER_PID();
				break;
			case PC_CMD_FREQMETER_TIMER:
				CMD_94_WRITE_FREQMETER_TIMER();
				break;
			case PC_CMD_FREQMETER_TRIG:
				Xil_Out32(Freq_Meter_Run_Trigger_Addr,0);
				Freq_meter_gate_time_cache = Xil_In32(Freq_Meter_Gate_Time_L_Addr);
				i = Xil_In32(Freq_Meter_Gate_Time_H_Addr);
				Freq_meter_gate_time_cache |= (uint64_t)i<<32;
				PC_HOST_Send_ASK_Only(0);
				break;
			case PC_CMD_FREQMETER_RESET:
				PC_HOST_Send_ASK_Only(0);
				Xil_Out32(Freq_Meter_Lock_Ctrl_Addr,0);
				Xil_Out32(Freq_Meter_Reset_Trigger_Addr,0);
				Xil_Out32(Freq_Meter_Lock_Ctrl_Addr,1);
				break;
			case PC_CMD_AUTOTUNE_FREQ_METER:
				Autotune_Command(&FreqAutotune);
				break;
			case PC_CMD_AUTOTUNE_DPLL:
				Autotune_Command(&DpllAutotune);
				break;
			case PC_CMD_VBIAS_WRITE_DAC:
				CMD_9A_WRITE_VBIAS_DAC();
				break;
			}
		}
		else
		{
			PC_HOST_Send_ASK(PC_HOST_CMD_GET,PC_HOST_CMD_ASK);
		}
		PC_HOST_CMD_RX_Mark = 0;
	}
}




/*********************************UART1  STM8COM****************************/

#define PACKAGE_SOH 0xA1
#define PACKAGE_STX 0xA2
#define PACKAGE_ETX 0xA3

#define STATUS_NACK                     0x03
#define STATUS_COMMAND_NUMBER_ERROR     0x04
#define STATUS_PARAMETER_ERROR          0x05
#define STATUS_ACK                      0x06
#define STATUS_CHECKSUM_ERROR           0x07

#define CMD_WRITE_EEPROM_DATA  0xB0
#define CMD_READ_EEPROM_DATA   0xB1
#define CMD_WRITE_MWS_CFG      0xB2
#define CMD_READ_MWS_CFG       0xB3
#define CMD_RF_ON              0xB7
#define CMD_RF_OFF             0xB8
#define CMD_READ_MWS_STATUS    0xB9
#define CMD_WRITE_DAC_CFG      0xBA
#define CMD_READ_DAC_CFG       0xBB
#define CMD_READ_ADC_VALUE     0xBC

#define Uart1_Buff_Size 512
uint8_t Uart1_TX_Buff[Uart1_Buff_Size];
uint8_t Uart1_RX_Buff[Uart1_Buff_Size];
uint8_t Uart1_CMD_Buff[32];
uint32_t Uart1_RX_Wait_Num = 0;
uint8_t* Uart1_RX_Buff_Pointer;
uint8_t Uart1_Cache;
u32 STM_HOST_CMD_ASK = 0;
u32 STM_HOST_CMD_GET = 0;
u32 Uart1_RX_Num=0;


void Uart1_Handler(void *CallBackRef)
{
	u32 IsrStatus;
	u32 RX_Num;

	IsrStatus =  XUartPs_ReadReg(XUartPs_uart1.Config.BaseAddress, XUARTPS_IMR_OFFSET);
	IsrStatus &= XUartPs_ReadReg(XUartPs_uart1.Config.BaseAddress, XUARTPS_ISR_OFFSET);

	if((IsrStatus & (u32)XUARTPS_IXR_RXOVR)!=0)
	{
		XUartPs_WriteReg(XUartPs_uart1.Config.BaseAddress, XUARTPS_ISR_OFFSET, XUARTPS_IXR_RXOVR);
		RX_Num=XUartPs_Recv(&XUartPs_uart1,Uart1_RX_Buff_Pointer,Uart1_Buff_Size-Uart1_RX_Num);
		Uart1_RX_Num += RX_Num;
		Uart1_RX_Buff_Pointer+=RX_Num;
	}
	if((IsrStatus & (u32)XUARTPS_IXR_TOUT)!=0)
	{
		XUartPs_WriteReg(XUartPs_uart1.Config.BaseAddress, XUARTPS_ISR_OFFSET, XUARTPS_IXR_TOUT);
		RX_Num=XUartPs_Recv(&XUartPs_uart1,Uart1_RX_Buff_Pointer,Uart1_Buff_Size-Uart1_RX_Num);
		Uart1_RX_Buff_Pointer+=RX_Num;
		Uart1_RX_Num += RX_Num;
		Uart1_RX_Wait_Num = 0;
	}
}

//0-ok
//1=timeout
uint32_t Uart1_TXRX_Frame(uint8_t* TX_Data,uint8_t* RX_Data,uint32_t TX_Nums,uint32_t RX_Nums)
{
  uint16_t RX_TimeOut;
  if(RX_Nums != 0)
  {
	Uart1_RX_Buff_Pointer = RX_Data;
    Uart1_RX_Num=0;
    Uart1_RX_Wait_Num = RX_Nums;
    //XUartPs_Recv(&XUartPs_uart1,Uart1_RX_Buff,Uart1_Buff_Size);
  }
  while(TX_Nums)
  {
	XUartPs_SendByte(XUartPs_uart1.Config.BaseAddress,TX_Data[0]);
    TX_Nums--;
    TX_Data++;
  }
  while((Xil_In32((XUartPs_uart1.Config.BaseAddress) + XUARTPS_SR_OFFSET) & (uint32_t)XUARTPS_SR_TXEMPTY) == 0);
  //while(!XUartPs_IsTransmitEMPTY(XUartPs_uart1));
  if(RX_Nums == 0)return 0;
  RX_TimeOut = 5000;//50ms
  while(RX_TimeOut)
  {
    RX_TimeOut--;
    if(Uart1_RX_Wait_Num==0)
	{
    	if(Uart1_RX_Num > RX_Nums){print("Serr lengthB\r\n");return 2;}
    	if(Uart1_RX_Num < RX_Nums){print("Serr lengthS\r\n");return 3;}
    	return 0;
	}

    usleep(10);
  }
  print("Serr timeout\r\n");
  Uart1_RX_Wait_Num = 0;
  return 1;
}

void Uart1PS_Init(void)
{
	XUartPs_Config *XUartPs_Config_uart1;
	XUartPsFormat XUartPsFormat_uart1;

	int status;

	XUartPs_Config_uart1 = XUartPs_LookupConfig(XPAR_PS7_UART_1_DEVICE_ID);//获得串口1配置信息
	status = XUartPs_CfgInitialize(&XUartPs_uart1,XUartPs_Config_uart1,XUartPs_Config_uart1->BaseAddress);
	if(status != XST_SUCCESS)
	{
		print("Initialize uart1 fail\n");
	}
	XUartPs_SetOperMode(&XUartPs_uart1, XUARTPS_OPER_MODE_NORMAL);
	XUartPsFormat_uart1.BaudRate = 921600;//波特率921600
	XUartPsFormat_uart1.DataBits = XUARTPS_FORMAT_8_BITS;
	XUartPsFormat_uart1.Parity = XUARTPS_FORMAT_NO_PARITY;
	XUartPsFormat_uart1.StopBits = XUARTPS_FORMAT_1_STOP_BIT;
	status = XUartPs_SetDataFormat(&XUartPs_uart1,&XUartPsFormat_uart1);
	if(status != XST_SUCCESS)
	{
		print("set uart1 Buad Rate fail\n");
	}
	XUartPs_SetFifoThreshold(&XUartPs_uart1,32);
	XUartPs_SetRecvTimeout(&XUartPs_uart1,4);//4*4=16 timeout IXR
	XUartPs_SetInterruptMask(&XUartPs_uart1,XUARTPS_IXR_RXOVR|XUARTPS_IXR_TOUT);//开中断

	XScuGic_Disable(&XPS_XScuGic,XPS_UART1_INT_ID);
	//XScuGic_SetPriorityTriggerType(&XPS_XScuGic,XPS_UART0_INT_ID,16,1);
	XScuGic_Connect(&XPS_XScuGic,XPS_UART1_INT_ID,(Xil_ExceptionHandler)Uart1_Handler,(void *)&XUartPs_uart1);//入口
	XScuGic_Enable(&XPS_XScuGic,XPS_UART1_INT_ID);

	Uart1_RX_Buff_Pointer = Uart1_RX_Buff;//设置默认位置 以防上电出现奇怪问题
	Uart1_RX_Num=0;
}

uint32_t Uart1_STM8_Send_CMD(uint8_t* CMD_Data_Buff,uint8_t CMD,uint32_t CMD_Data_Nums,uint32_t CMD_RX_Nums)
{
  uint32_t CheckSm = 0,i,Error_Code;
  Uart1_TX_Buff[0] = PACKAGE_SOH;
  Uart1_TX_Buff[1] = CMD_Data_Nums + 1;
  CheckSm -= Uart1_TX_Buff[1];
  Uart1_TX_Buff[2] = CMD;
  CheckSm -= Uart1_TX_Buff[2];
  if(CMD_Data_Nums>0)
  {
	  for(i=0;i<CMD_Data_Nums;i++)
	  {
		  Uart1_TX_Buff[3+i] = CMD_Data_Buff[i];
		  CheckSm -= CMD_Data_Buff[i];
	  }
  }
  Uart1_TX_Buff[3+CMD_Data_Nums] = CheckSm&0xFF;
  Uart1_TX_Buff[4+CMD_Data_Nums] = PACKAGE_ETX;
  Error_Code = Uart1_TXRX_Frame(Uart1_TX_Buff,Uart1_RX_Buff,CMD_Data_Nums+5,CMD_RX_Nums);
  if(Error_Code){return Error_Code;}
  //printf("S %.2X %.2X %.2X %.2X %.2X %.2X\r\n",Uart1_RX_Buff[0],Uart1_RX_Buff[1],Uart1_RX_Buff[2],Uart1_RX_Buff[3],Uart1_RX_Buff[4],Uart1_RX_Buff[5]);
  if(Uart1_RX_Buff[0] != PACKAGE_STX){printf("Serr head 0x%.2X\r\n",Uart1_RX_Buff[0]); return 4;}
  if(Uart1_RX_Buff[1]>64){print("Serr size\r\n");return 5;}
  CheckSm = 0;
  CheckSm -= Uart1_RX_Buff[1];
  for(i=0;i<Uart1_RX_Buff[1];i++)
  {
    CheckSm -= Uart1_RX_Buff[2+i];
  }
  if(Uart1_RX_Buff[2+i] != (uint8_t)CheckSm){print("Serr checksum\r\n");return 6;}
  if(Uart1_RX_Buff[3+i] != PACKAGE_ETX){print("Serr etx\r\n");return 7;}
  if(Uart1_RX_Buff[2] != STATUS_ACK){print("Serr noask\r\n");return Uart1_RX_Buff[2]|0x80;}
  print("Sok\r\n");
  return 0;
}

//STM8_EEPROM_Data

uint32_t Uart1_STM8_Save_EEPROM(void)
{
	uint32_t Error_Code;
	Error_Code = Uart1_STM8_Send_CMD(&STM8_EEPROM_Data[3],CMD_WRITE_EEPROM_DATA,44-3,5);
	return Error_Code;
}

uint32_t Uart1_STM8_Read_EEPROM(void)
{
	uint32_t Error_Code;
	uint32_t i;
	Error_Code = Uart1_STM8_Send_CMD(Uart1_CMD_Buff,CMD_READ_EEPROM_DATA,0,48);
	if(Error_Code)return Error_Code;
	for(i=1;i<44;i++)
	{
		STM8_EEPROM_Data[i] = Uart1_RX_Buff[2+i];
	}
	return Error_Code;
}

uint32_t Uart1_STM8_Set_MWS_CFG(uint32_t Frequency_Code,uint8_t Power_Code)
{
	uint32_t Error_Code;
	uint8_t cmd_data[8];
	cmd_data[0] = Frequency_Code&0xFF;
	cmd_data[1] = (Frequency_Code>>8)&0xFF;
	cmd_data[2] = (Frequency_Code>>16)&0xFF;
	cmd_data[3] = (Frequency_Code>>24)&0xFF;
	cmd_data[4] = Power_Code;
	Error_Code = Uart1_STM8_Send_CMD(cmd_data,CMD_WRITE_MWS_CFG,5,5);
	return Error_Code;
}

uint32_t Uart1_STM8_Get_MWS_CFG(uint32_t* Frequency_Code,uint8_t* Power_Code)
{
	uint32_t Error_Code;
	uint32_t freq = 0;
	uint8_t cmd_data[8];
	Error_Code = Uart1_STM8_Send_CMD(cmd_data,CMD_READ_MWS_CFG,0,10);
	if(Error_Code)return Error_Code;
	freq = Uart1_RX_Buff[3]|((uint8_t)Uart1_RX_Buff[4]<<8)|((uint8_t)Uart1_RX_Buff[5]<<16)|((uint8_t)Uart1_RX_Buff[6]<<24);
	*Frequency_Code = freq;
	*Power_Code = Uart1_RX_Buff[7];

	return Error_Code;
}

uint32_t Uart1_STM8_Set_RF_ON(void)
{
	uint32_t Error_Code;
	uint8_t cmd_data[8];
	Error_Code = Uart1_STM8_Send_CMD(cmd_data,CMD_RF_ON,0,5);
	return Error_Code;
}
uint32_t Uart1_STM8_Set_RF_OFF(void)
{
	uint32_t Error_Code;
	uint8_t cmd_data[8];
	Error_Code = Uart1_STM8_Send_CMD(cmd_data,CMD_RF_OFF,0,5);
	return Error_Code;
}
uint32_t Uart1_STM8_Read_MWS_Status(uint8_t* Status)
{
	uint32_t Error_Code;
	uint8_t cmd_data[8];
	Error_Code = Uart1_STM8_Send_CMD(cmd_data,CMD_READ_MWS_STATUS,0,6);
	*Status = Uart1_RX_Buff[3];
	return Error_Code;
}

uint32_t Uart1_STM8_Set_Vbias_DAC(int16_t DACA,int16_t DACB)
{
	uint32_t Error_Code;
	uint8_t cmd_data[8];
	cmd_data[0] = DACA&0xFF;
	cmd_data[1] = (DACA>>8)&0xFF;
	cmd_data[2] = DACB&0xFF;
	cmd_data[3] = (DACB>>8)&0xFF;
	Error_Code = Uart1_STM8_Send_CMD(cmd_data,CMD_WRITE_DAC_CFG,4,5);
	return Error_Code;
}

uint32_t Uart1_STM8_Read_Vbias_DAC(int16_t* DACA,int16_t* DACB)
{
	uint32_t Error_Code;
	uint8_t cmd_data[8];
	Error_Code = Uart1_STM8_Send_CMD(cmd_data,CMD_READ_DAC_CFG,0,9);
	*DACA = Uart1_RX_Buff[3]|((uint8_t)Uart1_RX_Buff[4]<<8);
	*DACB = Uart1_RX_Buff[5]|((uint8_t)Uart1_RX_Buff[4]<<6);
	return Error_Code;
}

uint32_t Uart1_STM8_Read_Vbias_ADC(uint16_t* ADCA,uint16_t* ADCB)
{
	uint32_t Error_Code;
	uint8_t cmd_data[8];
	Error_Code = Uart1_STM8_Send_CMD(cmd_data,CMD_READ_ADC_VALUE,0,9);
	*ADCA = Uart1_RX_Buff[3]|((uint8_t)Uart1_RX_Buff[4]<<8);
	*ADCB = Uart1_RX_Buff[5]|((uint8_t)Uart1_RX_Buff[4]<<6);
	return Error_Code;
}

#define Freq_ref 125000000

int main()
{
//	uint32_t cache[4];
//	int32_t phase_data;
//	uint64_t Freq_cnt;
//	double Freq_meterA;
//	double Freq_meterB;
    init_platform();

    XPS_Core_init();
    Uart0PS_Init();
    Uart1PS_Init();

    //print("hello\r\n");
    usleep(1000000);

    Xil_Out32(Opal_Kelly_Reset_Trigger_Addr,0);//rst;
    Xil_Out32(PLL0_Lock_Ctrl_Addr,0);
    Xil_Out32(DAC0_VCO_Offset_Addr,0);//offset 14bit;
    Xil_Out32(DAC0_VOC_Amplitude_Addr,0x7fff);//amplitude 15bit;
    //Xil_Out32(DAC0_VOC_Amplitude_Addr,0x0001);//amplitude 15bit;
    Xil_Out32(DAC0_Centre_Frequency_Addr,0x051EB851);//中心频率 120KHz@fs=3.125MHz

    Xil_Out32(DAC0_DDC_Angle_Select_Addr,0);//wrapped_phase_cordic

    Xil_Out32(DAC1_DDS_Offset_Addr,0);//offset 14bit;
    Xil_Out32(DAC1_DDS_Amplitude_Addr,0x7fff);//amplitude 15bit;
    //Xil_Out32(DAC1_DDS_Frequency_Addr,0x03126E97);//Fre 31bit; 1.5Mhz
    //Xil_Out32(DAC1_DDS_Frequency_Addr,0x0020C49B);//Fre 31bit; 125KHz
    //Xil_Out32(DAC1_DDS_Frequency_Addr,0x00418000);//Fre 31bit; 125KHz
    Xil_Out32(DAC1_DDS_Frequency_Addr,0x47AE147A);//Fre 31bit; 35MHz
    Xil_Out32(DAC1_DDS_Phase_Addr,0x0);//Phase 32bit

    Xil_Out32(PID_Freq_Pos_Limit_Addr,0x7FFFFFFE);//32Bit
    Xil_Out32(PID_Freq_Neg_Limit_Addr,0x80000001);//32Bit
    Xil_Out32(VCO_Freq_Manual_Offset_Addr,0);//offset 10bit;
    Xil_Out32(VOC_Fre_Mul_Addr,1);//mul 16bit;
    Xil_Out32(VOC_Fre_Div_Addr,1);//div 16bit;

    Xil_Out32(DAC0_Freq_Residuals_Threshold_Addr,100);//14Bit
    Xil_Out32(DAC0_Phase_Residuals_Threshold_Addr,1000);//32Bit
    Xil_Out32(DAC0_Phase_Residuals_Offset_Addr,0);//32Bit

    //Xil_Out32(PLL0_PID_GainP_Addr,1100000);
    //Xil_Out32(PLL0_PID_GainI_Addr,5000000);
    //Xil_Out32(PLL0_PID_GainI2_Addr,5000000);//减少残差 加快最后的慢收敛
    //Xil_Out32(PLL0_PID_GainD_Addr,100000000);

    Xil_Out32(PLL0_PID_GainP_Addr,1100000);
    Xil_Out32(PLL0_PID_GainI_Addr,1000000);
    Xil_Out32(PLL0_PID_GainI2_Addr,1000000);//减少残差 加快最后的慢收敛
    Xil_Out32(PLL0_PID_GainD_Addr,80000000);

    //Xil_Out32(PLL0_PID_GainP_Addr,0x07000000);
    //Xil_Out32(PLL0_PID_GainI_Addr,0x01000000);
    //Xil_Out32(PLL0_PID_GainI2_Addr,0x01000000);
    //Xil_Out32(PLL0_PID_GainD_Addr,0x00100000);

    Xil_Out32(PLL0_Coefd_Filter_Addr,0x0ffff);//18Bit


    Xil_Out32(Freq_Meter_Reset_Trigger_Addr,0);//rst;
    Xil_Out32(Freq_Meter_Lock_Ctrl_Addr,0);

    Xil_Out32(Freq_Meter_Centre_Frequency_Addr,0x51EB851E); //40MHz
    //Xil_Out32(Freq_Meter_Centre_Frequency_Addr,0x51F12345); //40MHz test

    Xil_Out32(Freq_Meter_PID_GainP_Addr,0x00400000);
    Xil_Out32(Freq_Meter_PID_GainI_Addr,0x00100000);
    Xil_Out32(Freq_Meter_PID_GainI2_Addr,0x00000100);
    Xil_Out32(Freq_Meter_PID_GainD_Addr,0);
    Xil_Out32(Freq_Meter_Coefd_Filter_Addr,0x0FFFF);
    Xil_Out32(Freq_Meter_Freq_Pos_Limit_Addr,0x4Fffffff);
    Xil_Out32(Freq_Meter_Freq_Neg_Limit_Addr,0xB0000000);
    Xil_Out32(Freq_Meter_Freq_Manual_Offset_Addr,0);
    Xil_Out32(Freq_Meter_Gate_Time_H_Addr,0);

    Xil_Out32(Freq_Meter_Phase_Residuals_Threshold_Addr,1000);
    Xil_Out32(Freq_Meter_Phase_Residuals_Offset_Addr,0);
    Xil_Out32(Freq_Meter_Freq_Residuals_Threshold_Addr,500);
	usleep(50);

	Xil_Out32(Freq_Meter_Lock_Ctrl_Addr,1);
	Autotune_Init();

	XUartPs_SendByte(XUartPs_uart0.Config.BaseAddress,'C');

    while(1)
    {
    	PC_HOST_CMD_Respond();
		Autotune_Service();



/*
        cache[0] = Xil_In32(Freq_Meter_PLL_DDC_phase_Add_Addr);
        cache[1] = Xil_In32(Freq_Meter_System_Statue_Addr);
        cache[2] = Xil_In32(Freq_Meter_inst_frequency_Addr);
        if(cache[2]>0x1FFF)
        {
        	phase_data = (int)cache[2] - 0x4000;
        }
        else phase_data = cache[2];
        cache[3] = Xil_In32(Freq_Meter_PLL_phase_residuals_Addr);

        printf("%.8X  %.4X %d %d\r\n",cache[0],cache[1],phase_data,cache[3]);

        cache[0] = Xil_In32(Freq_Meter_System_Statue_Addr);
        if((cache[0]&0x30)==0x30)
        {
        	//Xil_Out32(Freq_Meter_Gate_Time_Addr,100);//10us
        	//Xil_Out32(Freq_Meter_Gate_Time_Addr,12500000);//0.1S
        	Xil_Out32(Freq_Meter_Gate_Time_Addr,125000000);//1S
        	//Xil_Out32(Freq_Meter_Gate_Time_Addr,1250000000);//10S
        	Xil_Out32(Freq_Meter_Run_Trigger_Addr,1);
        	while(1)
        	{
        		cache[1] = Xil_In32(Freq_Meter_Run_Statue_Addr);
        		if(cache[1] == 1)break;
        	}
        	Xil_Out32(Freq_Meter_Run_Trigger_Addr,0);

        	while(1)
        	{
        		cache[1] = Xil_In32(Freq_Meter_Run_Statue_Addr);
        		if(cache[1] == 0)break;
        	}
    		cache[1] = Xil_In32(Freq_Meter_DataL_Output_Addr);
    		cache[2] = Xil_In32(Freq_Meter_DataM_Output_Addr);
    		cache[3] = Xil_In32(Freq_Meter_DataH_Output_Addr);
    		cache[0] = Xil_In32(Freq_Meter_PLL_phase_residuals_Addr);
        	Freq_cnt = ((uint64_t)cache[2]<<32)|cache[1];
        	//Freq_cnt = Freq_cnt*(Freq_ref/12500000);//0.1S
        	Freq_cnt = Freq_cnt*(Freq_ref/125000000);//1S
        	//Freq_cnt = Freq_cnt*(Freq_ref/1250000000);//10S
        	Freq_meterB = (double)Freq_cnt/(double)0x1FFFFFFFF;
        	printf("Freq:%.4X%.8X%.8X %fHz %d\r\n",cache[3],cache[2],cache[1],Freq_meterB,cache[0]);


        }
        else
        {
        	printf("Unlock:0x%.4X\r\n",cache[0]);
        	usleep(10000);
        }
    	//print("hello\r\n");
*/
    }
    cleanup_platform();
    return 0;
}
