`timescale 1ns / 1ps
/* 
** Engineer:  mgwang37  mgwang37@126.com
** Create Date: 11/16/2023 23:00:52
** reviewed by： Biao Fang
** Module Name: FP32Multi
**
** Description: 
**      符合IEEE-754标准fp32浮点乘法器(四级流水)
**      新增 out_valid 信号，用于指示输出数据有效
**      新增 input_valid 信号，用于指示输入数据有效
**
** Dependencies: NO
**
** Revision:
**
** Revision 0.01 - File Created
** Revision 0.02 - Added detailed comments and out_valid signal
** Revision 0.03 - Added input_valid signal to gate data processing
**
** Additional Comments:
*/

module FP32Multi
(
    input         clk,                // 时钟信号
    input         input_valid,        // 输入数据有效指示信号，高电平表示x1和x2有效
    input [31:0]  x1,                 // 32位浮点数输入1
    input [31:0]  x2,                 // 32位浮点数输入2
    output [31:0] y,                  // 32位浮点数乘法结果输出
    output reg    out_valid           // 输出有效指示信号，高电平表示y端口数据有效
);

// =========================================================================
// 第一阶段：组合逻辑 - 数据预处理 (预计算尾数、状态和指数基数)
// 此阶段不受input_valid控制，因为它是纯组合逻辑，不消耗寄存器资源。
// 只有当后续时序阶段决定是否采样时，input_valid才会起作用。
// =========================================================================

// x1_0: 处理x1的尾数部分，将隐藏位显式化
// 如果x1是规格化数（阶码不为0），则尾数为 1 + 22位小数部分
// 如果x1是亚规格化数（阶码为0），则尾数为 0 + 22位小数部分
wire [23:0] x1_0 = (x1[30:23] == 8'h00) ? {1'b0, x1[22:0]} : {1'b1, x1[22:0]};

// x2_0: 同理处理x2的尾数部分
wire [23:0] x2_0 = (x2[30:23] == 8'h00) ? {1'b0, x2[22:0]} : {1'b1, x2[22:0]};

// state_0: 预计算输入数据的特殊状态
wire [ 1:0] state_0;
// state_0[1]: 1表示x1或x2为NaN或无穷大（阶码全1）
assign state_0[1] = (x1[30:23] == 8'hff) | (x2[30:23] == 8'hff);
// state_0[0]: 1表示x1或x2为零（阶码和尾数全零）
assign state_0[0] = (x1[30: 0] == 31'h00000000) | (x2[30: 0] == 31'h00000000);

// expo_x1_base: x1的指数计算基数
// 对于亚规格化数，其指数为 1 - 127 = -126
// 对于规格化数，其指数为 阶码 - 127
wire signed [9:0] expo_x1_base = (x1[30:23] == 8'h00) ? 126 : 127;

// expo_x2_base: 同理处理x2的指数计算基数
wire signed [9:0] expo_x2_base = (x2[30:23] == 8'h00) ? 126 : 127;

// 将x1和x2的8位阶码扩展为9位有符号数，以便进行加法运算
wire signed [9:0] expo_x1 = {2'h0, x1[30:23]};
wire signed [9:0] expo_x2 = {2'h0, x2[30:23]};

// =========================================================================
// 第二阶段：时序逻辑 - 流水线寄存器1 (计算指数和、尾数乘积、符号位)
// =========================================================================

reg  signed [ 9:0] expo_1;    // 寄存器：存储初步计算的指数和
reg         [47:0] mant_1;    // 寄存器：存储尾数的乘积 (24bit * 24bit = 48bit)
reg                sign_1;    // 寄存器：存储结果的符号位 (x1符号 ^ x2符号)
reg         [ 1:0] state_1;   // 寄存器：存储第一阶段计算的状态
reg                valid_1;   // 寄存器：流水线第一级有效标志

always @(posedge clk) begin
    if (!input_valid) begin
        // 如果输入数据无效，则保持当前寄存器的值，不更新
        expo_1  <= expo_1;
        mant_1  <= mant_1;
        sign_1  <= sign_1;
        state_1 <= state_1;
        valid_1 <= input_valid;
    end else begin
        // 输入数据有效，计算并更新寄存器
        expo_1  <= expo_x1 + expo_x2 - expo_x1_base - expo_x2_base;
        mant_1  <= x1_0 * x2_0;
        sign_1  <= x1[31] ^ x2[31];
        state_1 <= state_0;
        valid_1 <= input_valid; // 标记此级数据有效
    end
end

// =========================================================================
// 第三阶段：时序逻辑 - 流水线寄存器2 (尾数分段移位)
// =========================================================================

reg  signed [ 9:0] expo_2;    // 寄存器：存储经过移位调整后的指数
reg         [47:0] mant_2;    // 寄存器：存储经过移位的尾数
reg                sign_2;    // 寄存器：传递符号位
reg         [ 1:0] state_2;   // 寄存器：传递状态
reg                valid_2;   // 寄存器：流水线第二级有效标志

always @(posedge clk) begin
    if (!input_valid) begin
        // 如果输入数据无效，保持当前寄存器的值
        expo_2  <= expo_2;
        mant_2  <= mant_2;
        sign_2  <= sign_2;
        state_2 <= state_2;
        valid_2 <= valid_1;
    end else begin
        // 输入数据有效，传递并处理数据
        sign_2  <= sign_1;
        state_2 <= state_1;
        valid_2 <= valid_1; // 传递有效标志

        // 根据尾数乘积的最高有效位所在的12位段，进行大跨度移位
        if (mant_1[47:36] != 12'h000) begin // 最高12位非零，无需移位
            mant_2 <= mant_1;
            expo_2 <= expo_1;
        end else if (mant_1[35:24] != 12'h000) begin // 次高12位非零，左移12位
            mant_2 <= mant_1 << 12;
            expo_2 <= expo_1 - 12;
        end else if (mant_1[23:12] != 12'h000) begin // 中间12位非零，左移24位
            mant_2 <= mant_1 << 24;
            expo_2 <= expo_1 - 24;
        end else begin // 最低12位非零，左移36位
            mant_2 <= mant_1 << 36;
            expo_2 <= expo_1 - 36;
        end
    end
end

// =========================================================================
// 第四阶段：时序逻辑 - 流水线寄存器3 (尾数规格化)
// =========================================================================

reg  signed [ 9:0] expo_3;    // 寄存器：存储最终规格化后的指数
reg         [47:0] mant_3;    // 寄存器：存储最终规格化后的尾数
reg                sign_3;    // 寄存器：传递符号位
reg         [ 1:0] state_3;   // 寄存器：传递状态
reg                valid_3;   // 寄存器：流水线第三级有效标志

always @(posedge clk) begin
    if (!input_valid) begin
        // 如果输入数据无效，保持当前寄存器的值
        expo_3  <= expo_3;
        mant_3  <= mant_3;
        sign_3  <= sign_3;
        state_3 <= state_3;
        valid_3 <= valid_2;
    end else begin
        // 输入数据有效，传递并处理数据
        sign_3  <= sign_2;
        state_3 <= state_2;
        valid_3 <= valid_2; // 传递有效标志

        // 尾数规格化：将尾数调整为 1.xxxx... 的形式
        if (mant_2[47]) begin
            mant_3 <= mant_2 << 0;
            expo_3 <= expo_2 + 1;
        end else if (mant_2[46]) begin
            mant_3 <= mant_2 << 1;
            expo_3 <= expo_2 + 0;
        end else if (mant_2[45]) begin
            mant_3 <= mant_2 << 2;
            expo_3 <= expo_2 - 1;
        end else if (mant_2[44]) begin
            mant_3 <= mant_2 << 3;
            expo_3 <= expo_2 - 2;
        end else if (mant_2[43]) begin
            mant_3 <= mant_2 << 4;
            expo_3 <= expo_2 - 3;
        end else if (mant_2[42]) begin
            mant_3 <= mant_2 << 5;
            expo_3 <= expo_2 - 4;
        end else if (mant_2[41]) begin
            mant_3 <= mant_2 << 6;
            expo_3 <= expo_2 - 5;
        end else if (mant_2[40]) begin
            mant_3 <= mant_2 << 7;
            expo_3 <= expo_2 - 6;
        end else if (mant_2[39]) begin
            mant_3 <= mant_2 << 8;
            expo_3 <= expo_2 - 7;
        end else if (mant_2[38]) begin
            mant_3 <= mant_2 << 9;
            expo_3 <= expo_2 - 8;
        end else if (mant_2[37]) begin
            mant_3 <= mant_2 << 10;
            expo_3 <= expo_2 - 9;
        end else if (mant_2[36]) begin
            mant_3 <= mant_2 << 11;
            expo_3 <= expo_2 - 10;
        end else begin // 如果所有高位都为零，则结果为零
            mant_3 <= 48'h0;
            expo_3 <= 9'h0;
        end
    end
end

// =========================================================================
// 第五阶段：时序逻辑 - 流水线寄存器4 (最终结果打包和异常处理)
// =========================================================================

reg  signed [ 9:0] expo_4;    // 寄存器：存储最终输出的阶码
reg         [47:0] mant_4;    // 寄存器：存储最终输出的尾数
reg                sign_4;    // 寄存器：存储最终输出的符号位

// 将内部寄存器的值组合成最终的32位浮点数输出y
assign y[31]    = sign_4;                     // 符号位
assign y[30:23] = expo_4[7:0];                // 8位阶码
assign y[22:0]  = mant_4[46:24];              // 23位小数部分（隐藏位1不存储）

always @(posedge clk) begin
    if (!input_valid) begin
        // 如果输入数据无效，则out_valid输出会直接拉低，因此在流水线最后4个数据时，填入0比较合适
        expo_4     <= expo_4;
        mant_4     <= mant_4;
        sign_4     <= sign_4;
        out_valid  <= input_valid;
    end else begin
        // 输入数据有效，进行最终处理并更新输出
        
        // 根据前面传递的状态进行最终的异常处理和结果打包
        if (state_3[1]) begin // 如果输入为NaN或无穷大
            expo_4 <= 9'h0ff;   // 阶码全1
            mant_4 <= 48'h0;    // 尾数全0，表示无穷大
            sign_4 <= sign_3;
        end else if (state_3[0] || (valid_3 && mant_3 == 48'h0)) begin // 如果输入为零或计算结果为零
            expo_4 <= 9'h000;   // 阶码全0
            mant_4 <= 48'h0;    // 尾数全0，表示零
            sign_4 <= sign_3;
        end else if (expo_3 > 127) begin // 如果指数上溢
            expo_4 <= 9'h0ff;   // 输出无穷大
            mant_4 <= 48'h0;
            sign_4 <= sign_3;
        end else if (expo_3 < -126) begin // 如果指数下溢
            expo_4 <= 9'h000;   // 输出亚规格化数或零
            mant_4 <= mant_3 >> (-126 - expo_3); // 尾数右移，实现截尾舍入
            sign_4 <= sign_3;
        end else begin // 正常情况，输出规格化数
            expo_4 <= expo_3 + 127;  // 将指数转换为阶码
            mant_4 <= mant_3;        // 尾数的小数部分已在[46:24]
            sign_4 <= sign_3;
        end
        
        // out_valid信号在数据有效输入4个时钟周期后有效
        out_valid <= valid_3;
    end
end

endmodule
