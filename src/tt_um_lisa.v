/*
==============================================================================
tt_um_lisa.v:  Tiny Tapeout User Module for the LISA 8-bit processor.

Copyright 2024 by Ken Pettit <pettitkd@gmail.com>

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.

==============================================================================
*/

// ==============================================================================
// I/O Usage:
//
//
//                 +------------------------+
//                 |     tt_um_lisa         |
//                 |                        |
//                 |ui_in             uo_out|
//        |        | 0                    0 |
//        |        | 1                    1 |
//  baud  |        | 2                    2 |
//   val -+   rx   | 3                    3 |
//        |        | 4                    4 | tx
//        |        | 5                    5 |
//        |        | 6                    6 |
//        baud_set | 7                    7 |
//                 |                        |
//                 |                   uio  |
//                 |                      0 |
//                 |                      1 |
//                 |                      2 |   FSM
//                 |                      3 |   I/O
//                 |                      4 |
//                 |                      5 |
//                 |                      6 |
//                 |                      7 |
//                 |                        |
//                 +------------------------+
//
//
//   ui:
//      3: Debug RX
//
//      7: HIGH to sample ui[6:0] as BAUD divider at reset.
//    6-0: When [7] is HIGH at reset, sets the UART BAUD divider.
//
// ==============================================================================

module tt_um_lisa
(
`ifdef USE_POWER_PINS
    input                  VPWR,
    input                  VGND,
`endif
   input   wire [7:0]      ui_in,            // Connected to the input switches
   output  wire [7:0]      uo_out,           // Connected to the 7 segment display
   input   wire [7:0]      uio_in,
   output  wire [7:0]      uio_out,
   output  wire [7:0]      uio_oe,           // BIDIR Enable (0=input, 1=output)
   
   // Control inputs
   input   wire            ena,              // Will go high when the design is enabled
   input   wire            clk,              // System clock 
   input   wire            rst_n             // Active low reset
);
   // ==========================================================================
   // Debug bus signals
   // ==========================================================================
   wire                 debug_rx;
   wire                 debug_tx;
   wire                 baud_ref;

   // ==========================================================================
   // I/O mux control signals
   // ==========================================================================
   wire [15:0]          output_mux_bits;     // Output select bits per output
   wire [7:0]           io_mux_bits;         // I/O select bits per BIDIR

   // ==========================================================================
   // Processor Instruction RAM bus
   // ==========================================================================
   wire   [14:0]        core_i_addr;
   wire   [15:0]        core_inst;
   wire   [15:0]        core_inst_o;
   wire                 core_inst_we;
   wire                 core_i_ready;
   wire                 core_i_fetch;

   // ==========================================================================
   // Processor DATA RAM bus
   // ==========================================================================
   wire   [14:0]        d_addr;
   wire   [7:0]         d_i;
   wire   [7:0]         d_i_dram;
   wire   [7:0]         d_i_periph;
   wire   [7:0]         d_o;
   wire                 d_we;
   wire                 d_rd;
   wire                 d_periph;
   wire   [31:0]        ram_do;
   wire   [3:0]         ram_we;

   // ==========================================================================
   // Debug signals
   // ==========================================================================
   wire   [7:0]         dbg_a;
   wire   [15:0]        dbg_di;
   wire   [15:0]        dbg_do;
   wire   [15:0]        dbg_do_lisa;
   wire   [15:0]        dbg_do_regs;
   wire                 dbg_we;
   wire                 dbg_rd;
   wire                 dbg_reset;
   wire                 dbg_ready;
   wire                 dbg_ready_lisa;
   wire                 dbg_ready_regs;
   wire                 dbg_halted;

   // ==========================================================================
   // Lisa Peripheral signals
   // ==========================================================================
   wire    [7:0]        porta;
   wire    [7:0]        porta_in;   
   wire    [7:0]        porta_dir;
   wire    [7:0]        portb;
   wire    [7:0]        portb_in;   
   wire    [7:0]        portb_dir;

   // ==========================================================================
   // Lisa UART signals
   // ==========================================================================
   wire    [7:0]        lisa_tx_d;
   wire    [7:0]        lisa_rx_d;
   wire                 lisa_tx_wr;
   wire                 lisa_rx_rd;
   wire                 lisa_rx_data_avail;
   wire                 lisa_tx_buf_empty;

   // ==========================================================================
   // Baud rate control signals
   // ==========================================================================
   wire    [6:0]        baud_div;
   wire                 baud_set;
   wire                 brg_wr;
   wire    [7:0]        brg_div;
   wire    [1:0]        rx_sel;

   // ==========================================================================
   // QSPI Arbiter debug signals
   // ==========================================================================
   wire [23:0]          debug_addr;          // 8Mx32
   wire [15:0]          debug_rdata;         // Read data
   wire [15:0]          debug_wdata;         // Data to write
   wire [1:0]           debug_wstrb;         // Which bytes in the 32-bits to write
   wire                 debug_ready;         // Next 32-bit value is ready
   wire                 debug_xfer_done;     // Total xfer_len transfer is done
   wire                 debug_valid;         // Indicates a valid request 
   wire [3:0]           debug_xfer_len;      // Number of 32-bit words to transfer
   wire [1:0]           debug_ce_ctrl;
   wire [7:0]           cmd_quad_write;
   wire                 custom_spi_cmd;
   wire [7:0]           dbg_cmd_quad_write;
   wire                 dbg_custom_spi_cmd;
   wire [3:0]           plus_guard_time;
                        
   // ==========================================================================
   // QSPI Arbiter Lisa instruction bus signals
   // ==========================================================================
   wire [23:0]          lisa1_addr;          // 8Mx32
   wire [15:0]          lisa1_rdata;         // Read data
   wire [15:0]          lisa1_wdata;         // Data to write
   wire [1:0]           lisa1_wstrb;         // Which bytes in the 32-bits to write
   wire                 lisa1_ready;         // Next 32-bit value is ready
   wire                 lisa1_xfer_done;     // Total xfer_len transfer is done
   wire                 lisa1_valid;         // Indicates a valid request 
   wire [3:0]           lisa1_xfer_len;      // Number of 32-bit words to transfer
   wire [1:0]           lisa1_ce_ctrl;
   wire [15:0]          lisa1_base_addr;
                        
   // ==========================================================================
   // QSPI Arbiter Lisa data bus signals
   // ==========================================================================
   wire [23:0]          lisa2_addr;          // 8Mx32
   wire [15:0]          lisa2_rdata;         // Read data
   wire [15:0]          lisa2_wdata;         // Data to write
   wire [1:0]           lisa2_wstrb;         // Which bytes in the 32-bits to write
   wire                 lisa2_ready;         // Next 32-bit value is ready
   wire                 lisa2_xfer_done;     // Total xfer_len transfer is done
   wire                 lisa2_valid;         // Indicates a valid request 
   wire [3:0]           lisa2_xfer_len;      // Number of 32-bit words to transfer
   wire [1:0]           lisa2_ce_ctrl;
   wire [15:0]          lisa2_base_addr;
                        
   // ==========================================================================
   // QSPI module control signals
   // ==========================================================================
   wire [23:0]          addr;                // 8Mx32
   wire [15:0]          rdata;               // Read data
   wire [15:0]          wdata;               // Data to write
   wire [1:0]           wstrb;               // Which bytes in the 32-bits to write
   wire                 ready;               // Next 32-bit value is ready
   wire                 xfer_done;           // Total xfer_len transfer is done
   wire                 valid;               // Indicates a valid request 
   wire [3:0]           xfer_len;            // Number of 32-bit words to transfer

   // ==========================================================================
   // Chip select controls
   // ==========================================================================
   wire [1:0]           ce_ctrl;
   wire [1:0]           addr_16b;
   wire [1:0]           is_flash;
   wire [1:0]           quad_mode;
   wire [7:0]           dummy_read_cycles;

   // ==========================================================================
   // The QSPI I/O signals
   // ==========================================================================
   wire                 sclk;
   wire                 sio0_si_mosi_i;
   wire                 sio1_so_miso_i;
   wire                 sio2_i;
   wire                 sio3_i;
   wire                 sio0_si_mosi_o;
   wire                 sio1_so_miso_o;
   wire                 sio2_o;
   wire                 sio3_o;
   wire [3:0]           sio_oe;
   wire [1:0]           ce;
                             
   // ==========================================================================
   // Instantiate the Lisa Processor Core
   // ==========================================================================
   lisa_core i_lisa_core
   (
      .clk                 ( clk                ),
      .rst_n               ( rst_n              ),
      .reset               ( dbg_reset          ),
                                             
      // Instruction bus                     
      .inst_i              ( core_inst          ),
      .inst_ready          ( core_i_ready       ),
      .i_fetch             ( core_i_fetch       ),
      .i_addr              ( core_i_addr        ),
      .inst_o              ( core_inst_o        ),
      .inst_we             ( core_inst_we       ),
                                                
      // Data bus                               
      .d_i                 ( d_i                ),
      .d_o                 ( d_o                ),
      .d_addr              ( d_addr             ),
      .d_periph            ( d_periph           ),
      .d_we                ( d_we               ),
      .d_rd                ( d_rd               ),
                                                
      // Debug bus                              
      .dbg_a               ( dbg_a              ),
      .dbg_di              ( dbg_di             ),
      .dbg_do              ( dbg_do_lisa        ),
      .dbg_we              ( dbg_we             ),
      .dbg_rd              ( dbg_rd             ),
      .dbg_ready           ( dbg_ready_lisa     ),
      .dbg_halted          ( dbg_halted         )
   );

   // ==========================================================================
   // Instantiate the DATA RAM
   // ==========================================================================
   RAM32 ram1
   (
      .CLK                 ( clk                  ),
      .WE0                 ( ram_we               ),
      .EN0                 ( 1'b1                 ),
      .A0                  ( d_addr[6:2]          ),
      .Di0                 ( {d_o, d_o, d_o, d_o} ),
      .Do0                 ( ram_do               )
   );

   // ==========================================================================
   // Connect the RAM32 write enable and output signals
   // ==========================================================================
   assign ram_we[0] = d_we & ~d_periph & (d_addr[1:0] == 2'h0);
   assign ram_we[1] = d_we & ~d_periph & (d_addr[1:0] == 2'h1);
   assign ram_we[2] = d_we & ~d_periph & (d_addr[1:0] == 2'h2);
   assign ram_we[3] = d_we & ~d_periph & (d_addr[1:0] == 2'h3);
   assign d_i_dram = ({8{d_addr[1:0] == 2'h0}} & ram_do[7:0])   |
                     ({8{d_addr[1:0] == 2'h1}} & ram_do[15:8])  |
                     ({8{d_addr[1:0] == 2'h2}} & ram_do[23:16]) |
                     ({8{d_addr[1:0] == 2'h3}} & ram_do[31:24]);
   assign d_i = d_periph ? d_i_periph : d_i_dram;

   // ==========================================================================
   // Instantiate a peripheral controller
   // ==========================================================================
   lisa_periph i_lisa_periph
   (
      .clk                 ( clk                ),
      .rst_n               ( rst_n              ),
                                                
      // Data bus                               
      .d_i                 ( d_o                ),
      .d_o                 ( d_i_periph         ),
      .d_addr              ( d_addr[6:0]        ),
      .d_periph            ( d_periph           ),
      .d_we                ( d_we               ),
      .d_rd                ( d_rd               ),
                                                
      // GPIO signals                           
      .porta               ( porta              ),
      .porta_in            ( porta_in           ),
      .porta_dir           ( porta_dir          ),
      .portb               ( portb              ),
      .portb_in            ( portb_in           ),
      .portb_dir           ( portb_dir          ),

      // UART signals
      .uart_tx_d           ( lisa_tx_d          ),
      .uart_tx_wr          ( lisa_tx_wr         ),
      .uart_rx_rd          ( lisa_rx_rd         ),
      .uart_rx_d           ( lisa_rx_d          ),
      .uart_rx_data_avail  ( lisa_rx_data_avail ),
      .uart_tx_buf_empty   ( lisa_tx_buf_empty  )
   );

   // ==========================================================================
   // Instantiate the QSPI controller / arbiter
   // ==========================================================================
   lisa_qspi_controller i_lisa_qspi_controller
   (
      .clk                 ( clk                ),
      .rst_n               ( rst_n              ),

      // Interface for debug
      .debug_addr          ( debug_addr         ), // 8Mx32
      .debug_rdata         ( debug_rdata        ), // Read data
      .debug_wdata         ( debug_wdata        ), // Data to write
      .debug_wstrb         ( debug_wstrb        ), // Which bytes in the 32-bits to write
      .debug_ready         ( debug_ready        ), // Next 32-bit value is ready
      .debug_xfer_done     ( debug_xfer_done    ), // Total xfer_len transfer is done
      .debug_valid         ( debug_valid        ), // Indicates a valid request
      .debug_xfer_len      ( debug_xfer_len     ), // Number of 32-bit words to transfer
      .debug_ce_ctrl       ( debug_ce_ctrl      ),
      .debug_custom_spi_cmd( dbg_custom_spi_cmd ),
      .debug_cmd_quad_write( dbg_cmd_quad_write ),

      // Interface for Lisa core instruction bus
      .lisa1_addr          ( lisa1_addr         ), // 8Mx32
      .lisa1_rdata         ( lisa1_rdata        ), // Read data
      .lisa1_wdata         ( lisa1_wdata        ), // Data to write
      .lisa1_wstrb         ( lisa1_wstrb        ), // Which bytes in the 32-bits to write
      .lisa1_ready         ( lisa1_ready        ), // Next 32-bit value is ready
      .lisa1_xfer_done     ( lisa1_xfer_done    ), // Total xfer_len transfer is done
      .lisa1_valid         ( lisa1_valid        ), // Indicates a valid request
      .lisa1_xfer_len      ( lisa1_xfer_len     ), // Number of 32-bit words to transfer
      .lisa1_ce_ctrl       ( lisa1_ce_ctrl      ),

      // Interface for Lisa core data bus
      .lisa2_addr          ( lisa2_addr         ), // 8Mx32
      .lisa2_rdata         ( lisa2_rdata        ), // Read data
      .lisa2_wdata         ( lisa2_wdata        ), // Data to write
      .lisa2_wstrb         ( lisa2_wstrb        ), // Which bytes in the 32-bits to write
      .lisa2_ready         ( lisa2_ready        ), // Next 32-bit value is ready
      .lisa2_xfer_done     ( lisa2_xfer_done    ), // Total xfer_len transfer is done
      .lisa2_valid         ( lisa2_valid        ), // Indicates a valid request
      .lisa2_xfer_len      ( lisa2_xfer_len     ), // Number of 32-bit words to transfer
      .lisa2_ce_ctrl       ( lisa2_ce_ctrl      ),

      // Interface to the qqspi controller
      .addr                ( addr               ), // 8Mx32
      .rdata               ( rdata              ), // Read data
      .wdata               ( wdata              ), // Data to write
      .wstrb               ( wstrb              ), // Which bytes in the 32-bits to write
      .ready               ( ready              ), // Next 32-bit value is ready
      .xfer_done           ( xfer_done          ), // Total xfer_len transfer is done
      .valid               ( valid              ), // Indicates a valid request
      .xfer_len            ( xfer_len           ), // Number of 32-bit words to transfer
      .ce_ctrl             ( ce_ctrl            ),
      .custom_spi_cmd      ( custom_spi_cmd     ),
      .cmd_quad_write      ( cmd_quad_write     )
   );

   // TODO: Add cache controller for DATA bus
   // For now Lisa data is only 128 Bytes ... no external
   assign lisa2_valid = 1'b0;
   assign lisa2_addr  = 'h0;
   assign lisa2_wdata = 'h0;
   assign lisa2_wstrb = 'h0;
   assign lisa2_xfer_len = 'h0;

   // ==========================================================================
   // Instantiate the QQSPI controller
   // ==========================================================================
   lisa_qqspi i_lisa_qqspi
   (
      .clk                 ( clk                ),
      .rst_n               ( rst_n              ),
     
      // The control interface
      .addr                ( addr               ), // 8Mx32
      .rdata               ( rdata              ), // Read data
      .wdata               ( wdata              ), // Data to write
      .wstrb               ( wstrb              ), // Which bytes in the 32-bits to write
      .ready               ( ready              ), // Next 32-bit value is ready
      .xfer_done           ( xfer_done          ), // Total xfer_len transfer is done
      .valid               ( valid              ), // Indicates a valid request
      .xfer_len            ( xfer_len           ), // Number of 32-bit words to transfer
     
      // Per chip-select controls
      .ce_ctrl             ( ce_ctrl            ),
      .addr_16b            ( addr_16b           ),
      .is_flash            ( is_flash           ),
      .quad_mode           ( quad_mode          ),
     
      // The QSPI Pin interface
      .sclk                ( sclk               ),
      .sio0_si_mosi_i      ( sio0_si_mosi_i     ),
      .sio1_so_miso_i      ( sio1_so_miso_i     ),
      .sio2_i              ( sio2_i             ),
      .sio3_i              ( sio3_i             ),
      .sio0_si_mosi_o      ( sio0_si_mosi_o     ),
      .sio1_so_miso_o      ( sio1_so_miso_o     ),
      .sio2_o              ( sio2_o             ),
      .sio3_o              ( sio3_o             ),
      .sio_oe              ( sio_oe             ),
      .ce                  ( ce                 ),
      .dummy_read_cycles   ( dummy_read_cycles  ),
      .custom_spi_cmd      ( custom_spi_cmd     ),
      .cmd_quad_write      ( cmd_quad_write     )
   );

   // ==========================================================================
   // Instantiate the debug controller
   // ==========================================================================
   debug_ctrl i_debug_ctrl
   (
      .clk                 ( clk                ),
      .rst_n               ( rst_n              ),
                                                
      // UART signals                           
      .debug_rx            ( debug_rx           ),
      .debug_tx            ( debug_tx           ),

      // Processor debug interface
      .debug_a             ( dbg_a              ),
      .debug_dout          ( dbg_di             ),
      .debug_din           ( dbg_do             ),
      .debug_wr            ( dbg_we             ),
      .debug_rd            ( dbg_rd             ),
      .debug_reset         ( dbg_reset          ),
      .debug_ready         ( dbg_ready          ),
      .debug_halted        ( dbg_halted         ),
                                                
      // Baud rate manual set control
      .brg_wr              ( brg_wr             ),
      .brg_div             ( brg_div            ),
      .baud_set            ( baud_set           ),
      .baud_div            ( baud_div           ),
      .baud_ref            ( baud_ref           ),

      // Signals to share UART with Lisa core
      .plus_guard_time     ( plus_guard_time    ),
      .lisa_tx_d           ( lisa_tx_d          ),
      .lisa_tx_wr          ( lisa_tx_wr         ),
      .lisa_rx_rd          ( lisa_rx_rd         ),
      .lisa_rx_d           ( lisa_rx_d          ),
      .lisa_rx_data_avail  ( lisa_rx_data_avail ),
      .lisa_tx_buf_empty   ( lisa_tx_buf_empty  )
   );

   // ==========================================================================
   // Instantiate the debug registers
   // ==========================================================================
   debug_regs i_debug_regs
   (
      // Timing and reset inputs
      .clk                 ( clk                ), // System clock
      .rst_n               ( rst_n              ), // Active low reset

      // The Debug ctrl interface
      .dbg_a               ( dbg_a              ),
      .dbg_di              ( dbg_di             ),
      .dbg_do              ( dbg_do_regs        ),
      .dbg_we              ( dbg_we             ),
      .dbg_rd              ( dbg_rd             ),
      .dbg_ready           ( dbg_ready_regs     ),

      // The Debug ctrl interface
      .debug_addr          ( debug_addr         ), // 8Mx32
      .debug_rdata         ( debug_rdata        ), // Read data
      .debug_wdata         ( debug_wdata        ), // Data to write
      .debug_wstrb         ( debug_wstrb        ), // Which bytes in the 32-bits to write
      .debug_ready         ( debug_ready        ), // Next 32-bit value is ready
      .debug_xfer_done     ( debug_xfer_done    ), // Total xfer_len transfer is done
      .debug_valid         ( debug_valid        ), // Indicates a valid request
      .debug_xfer_len      ( debug_xfer_len     ), // Number of 16-bit words to transfer
      .debug_ce_ctrl       ( debug_ce_ctrl      ),

      // Lisa core QSPI CE and base addresses
      .lisa1_ce_ctrl       ( lisa1_ce_ctrl      ),
      .lisa1_base_addr     ( lisa1_base_addr    ),
      .lisa2_ce_ctrl       ( lisa2_ce_ctrl      ),
      .lisa2_base_addr     ( lisa2_base_addr    ),

      // QSPI Chip Enable options
      .addr_16b            ( addr_16b           ),
      .is_flash            ( is_flash           ),
      .quad_mode           ( quad_mode          ),
      .dummy_read_cycles   ( dummy_read_cycles  ),

      .custom_spi_cmd      ( dbg_custom_spi_cmd ),
      .cmd_quad_write      ( dbg_cmd_quad_write ),
      .plus_guard_time     ( plus_guard_time    ),

      // I/O Mux Bits
      .output_mux_bits     ( output_mux_bits    ),
      .io_mux_bits         ( io_mux_bits        )
   );

   assign dbg_do         = dbg_do_lisa | dbg_do_regs;
   assign dbg_ready      = dbg_ready_lisa | dbg_ready_regs;
   assign lisa1_addr     = {lisa1_base_addr, 8'h0} | {8'h0, core_i_addr, 1'b0};
   assign lisa1_valid    = core_i_fetch | core_inst_we;
   assign lisa1_wstrb    = {core_inst_we, core_inst_we};
   assign lisa1_wdata    = core_inst_o;
   assign lisa1_xfer_len = 4'h1;
   assign core_inst      = lisa1_rdata;
   assign core_i_ready   = lisa1_ready;
   assign baud_div       = ui_in[6:0];
   assign baud_set       = ui_in[7];

   // ==========================================================================
   // Instantiate the debug controller
   // ==========================================================================
   debug_autobaud i_debug_autobaud
   (
      // Timing and reset inputs
      .clk                 ( clk                ), // System clock
      .rst_n               ( rst_n              ), // Active low reset
      .disabled            ( ui_in[7]           ), // Disabled if set externally
      .rx1                 ( ui_in[3]           ), // Input from the UART
      .rx2                 ( uio_in[6]          ), // Input from the UART
      .rx3                 ( uio_in[4]          ), // Input from the UART
      .wr                  ( brg_wr             ), // Write the baud rate
      .div                 ( brg_div            ), // The divisor
      .rx_sel              ( rx_sel             )  // Selected RX input
   );

   // ==========================================================================
   // Instantiate the Lisa I/O Mux module
   // ==========================================================================
   lisa_io_mux i_lisa_io_mux
   (
      .clk                 ( clk                ),
      .rst_n               ( rst_n              ),

      // Chip top I/O signals
      .ui_in               ( ui_in              ),
      .uo_out              ( uo_out             ),
      .uio_in              ( uio_in             ),
      .uio_out             ( uio_out            ),
      .uio_oe              ( uio_oe             ),

      // I/O mux controls
      .rx_sel              ( rx_sel             ),
      .output_mux_bits     ( output_mux_bits    ),
      .io_mux_bits         ( io_mux_bits        ),

      // QSPI I/O signals
      .sclk                ( sclk               ),
      .ce                  ( ce                 ),
      .sio0_si_mosi_i      ( sio0_si_mosi_i     ),
      .sio1_so_miso_i      ( sio1_so_miso_i     ),
      .sio2_i              ( sio2_i             ),
      .sio3_i              ( sio3_i             ),
      .sio0_si_mosi_o      ( sio0_si_mosi_o     ),
      .sio1_so_miso_o      ( sio1_so_miso_o     ),
      .sio2_o              ( sio2_o             ),
      .sio3_o              ( sio3_o             ),
      .sio_oe              ( sio_oe             ),

      .lisa_porta_i        ( porta              ),
      .lisa_porta_o        ( porta_in           ),
      .lisa_portb_i        ( portb              ),
      .lisa_portb_dir_i    ( portb_dir          ),
      .lisa_portb_o        ( portb_in           ),

      // UART inputs
      .baud_ref            ( baud_ref           ),
      .debug_tx            ( debug_tx           ),

      // Muxed outputs
      .debug_rx            ( debug_rx           ) 
   );

endmodule // tt_um_lisa
