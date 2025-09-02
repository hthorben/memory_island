// Thorben Heekenjann 

`include "axi/typedef.svh"
`include "axi/assign.svh"

`include "common_cells/assertions.svh"

module axi_memory_island_tb #(
  parameter int unsigned AddrWidth         = 32,
  parameter int unsigned NarrowDataWidth   = 32,
  parameter int unsigned WideDataWidth     = 512,
  parameter int unsigned AxiIdWidth        = 2,
  parameter int unsigned AxiUserWidth      = 1,
  parameter int unsigned NumNarrowReq      = 2,
  parameter int unsigned NumWideReq        = 1,
  parameter int unsigned NumWideBanks      = 8,
  parameter int unsigned NarrowExtraBF     = 2,
  parameter int unsigned WordsPerBank      = 512 * NumNarrowReq * NumWideReq,
  parameter int unsigned TbNumReads        = 200,
  parameter int unsigned TbNumWrites       = 200,
  parameter int unsigned BankAccessLatency = 2,
  parameter time         CyclTime          = 10ns,
  parameter time         ApplTime          = 2ns,
  parameter time         TestTime          = 8ns,

  localparam int unsigned TestRegionStart = 0,
  localparam int unsigned TestRegionEnd   = WordsPerBank*NumWideBanks*16*4
) ();

  localparam int unsigned TotalNumberOfWords = WordsPerBank * NumWideBanks * WideDataWidth /
      NarrowDataWidth;
  localparam int unsigned TotalBytes = WordsPerBank * NumWideBanks * WideDataWidth / 8;

  localparam int unsigned WideToNarrowFactor = WideDataWidth / NarrowDataWidth;

  localparam int unsigned UsableAddrWidth = $clog2(TotalBytes);

  //localparam int unsigned TotalReq = NumNarrowReq + NumWideReq;
  localparam int unsigned TotalReq = NumNarrowReq;
  //localparam int unsigned TxInFlight = 16;  // pow2
  localparam int unsigned TxInFlight = 1;  // pow2

  `ASSERT_INIT(TestRegionFits, TestRegionEnd <= WordsPerBank * NumWideBanks * WideDataWidth / 8)
  `ASSERT_INIT(TestAfterAppl, ApplTime < TestTime)
  `ASSERT_INIT(CycleTiming, ApplTime < CyclTime && TestTime < CyclTime)








  // To be used as number of narrow banks
  localparam int unsigned NWDivisor = WideDataWidth / NarrowDataWidth;
  // The amount of physical memory banks inside each narrow bank
  localparam int unsigned NumPhysicalBanks = 16;
  // The amount of physical banks inside each narrow bank that are turned off
  localparam int unsigned GatedBanks = 11;
  // The granularity of the power gating, i.e. how many physical banks are controlled by a signal (has to be a power of 2)
  localparam int unsigned GatingGranularity = NWDivisor*NumWideBanks;
  // The amount of cables needed to achieve the desired gating granularity
  localparam int unsigned PWRSigWidth = (NWDivisor*NumPhysicalBanks*NumWideBanks) / GatingGranularity;
  // Simulate power gating enabled
  localparam int unsigned Pwr_Sigs     = 1;



  logic [TotalReq-1:0] end_of_full_pwr;
  logic [TotalReq-1:0] end_of_pwr_gate;

  logic pw_gate_ctrl;
  logic deepsleep_ctrl;

  int unsigned gated_accs = 0;
  int unsigned gated;



  logic clk, rst_n;

  logic [TotalReq-1:0] random_mem_filled;
  logic [TotalReq-1:0] end_of_sim;
  logic [TotalReq-1:0] mismatch;

  // Clock/Reset generation
  clk_rst_gen #(
    .RstClkCycles(3),
    .ClkPeriod   (CyclTime)
  ) i_clk_gen (
    .clk_o (clk),
    .rst_no(rst_n)
  );

  // Main AXI type definitions
  `AXI_TYPEDEF_ALL(narrow, logic[AddrWidth-1:0], logic[AxiIdWidth-1:0], logic[NarrowDataWidth-1:0],
                   logic[NarrowDataWidth/8-1:0], logic[AxiUserWidth-1:0])
  `AXI_TYPEDEF_ALL(wide, logic[AddrWidth-1:0], logic[AxiIdWidth-1:0], logic[WideDataWidth-1:0],
                   logic[WideDataWidth/8-1:0], logic[AxiUserWidth-1:0])

  // Narrow Random Master config
  typedef axi_test::axi_rand_master#(
    .AW            (AddrWidth),
    .DW            (NarrowDataWidth),
    .IW            (AxiIdWidth),
    .UW            (AxiUserWidth),
    // Stimuli application and test time
    .TA            (ApplTime),
    .TT            (TestTime),
    // Maximum number of read and write transactions in flight
    .MAX_READ_TXNS (TxInFlight),
    .MAX_WRITE_TXNS(TxInFlight),

    .SIZE_ALIGN       (0),
    .AXI_MAX_BURST_LEN(0),     // max
    .TRAFFIC_SHAPING  (0),
    .AXI_EXCLS        (1'b0),
    .AXI_ATOPS        (1'b0),
    .AXI_BURST_FIXED  (1'b0),
    .AXI_BURST_INCR   (1'b1),
    .AXI_BURST_WRAP   (1'b0),
    .UNIQUE_IDS       (1'b0)
  ) narrow_axi_rand_master_t;


  narrow_req_t  [NumNarrowReq-1:0] axi_narrow_req;
  narrow_resp_t [NumNarrowReq-1:0] axi_narrow_rsp;

  AXI_BUS_DV #(
    .AXI_ADDR_WIDTH(AddrWidth),
    .AXI_DATA_WIDTH(NarrowDataWidth),
    .AXI_ID_WIDTH  (AxiIdWidth),
    .AXI_USER_WIDTH(AxiUserWidth)
  ) axi_narrow_dv[NumNarrowReq-1:0] (
    clk
  );

  narrow_axi_rand_master_t                    narrow_rand_master      [NumNarrowReq];
  
  narrow_req_t             [NumNarrowReq-1:0] filtered_narrow_req;
  narrow_resp_t            [NumNarrowReq-1:0] filtered_narrow_rsp;

  narrow_req_t             [NumNarrowReq-1:0] filtered_narrow_req_cut;
  narrow_resp_t            [NumNarrowReq-1:0] filtered_narrow_rsp_cut;

  narrow_req_t             [NumNarrowReq-1:0] dut_narrow_req;
  narrow_resp_t            [NumNarrowReq-1:0] dut_narrow_rsp;

  narrow_req_t             [NumNarrowReq-1:0] golden_narrow_req;
  narrow_resp_t            [NumNarrowReq-1:0] golden_narrow_rsp;

  // Filter reads to regions being written
  // Filter writes to regions being read
  typedef struct packed {
    logic [AddrWidth-1:0] start_addr;
    logic [AddrWidth-1:0] end_addr;
  } addr_range_t;

  logic        [TotalReq-1:0] blocking_write;
  logic        [TotalReq-1:0] blocking_read;

  // Address range queues to avoid writes interfering with reads or other writes
  addr_range_t                regions_being_read   [TotalReq][2**AxiIdWidth][$];
  addr_range_t                regions_being_written[TotalReq][2**AxiIdWidth][$];

  // Overlap if !(b.end < a.start || b.start > a.end)
  function automatic logic check_overlap(addr_range_t range_a, addr_range_t range_b);
    check_overlap =
        !((range_a.start_addr > range_b.end_addr) || (range_a.end_addr < range_b.start_addr));
  endfunction

  addr_range_t [TotalReq-1:0] tmp_read, tmp_write;

  int                         read_len    [TotalReq][2**AxiIdWidth];
  int                         write_len   [TotalReq][2**AxiIdWidth];

  addr_range_t [TotalReq-1:0] write_range;
  addr_range_t [TotalReq-1:0] read_range;

  logic [TotalReq-1:0] aw_hs, ar_hs;


  // Moritz: Can't use an always_comb block here, since queue updates do NOT trigger signal updates, so fully spec-compliant simulators will not reevaluate the assignments.
  // Store both narrow and wide in-flight address ranges into a queue;
  // Doing queue updates and recomputing read_len / write_len avoids timing bugs.
  always @(posedge clk) begin
    for (int i = 0; i < TotalReq; i++) begin : gen_len_req

      for (int id = 0; id < 2 ** AxiIdWidth; id++) begin
        // push write queue on actual AW
        if (aw_hs[i] && axi_narrow_req[i].aw.id == id) begin
          regions_being_written[i][id].push_back(write_range[i]);
           $display("writing to [%x, %x]", write_range[i].start_addr, write_range[i].end_addr);
        end
        // pop write queue on B
        if (axi_narrow_rsp[i].b_valid && filtered_narrow_req[i].b_ready &&
            axi_narrow_rsp[i].b.id == id) begin
          tmp_write[i] = regions_being_written[i][id].pop_front();
           $display("done writing [%x, %x]",tmp_write[i].start_addr, tmp_write[i].end_addr);
        end
        // push read queue on actual AR
        if (ar_hs[i] && axi_narrow_req[i].ar.id == id) begin
          regions_being_read[i][id].push_back(read_range[i]);
           $display("reading from [%x, %x]", read_range[i].start_addr, read_range[i].end_addr);
        end
        // pop read queue on last R
        if (axi_narrow_rsp[i].r_valid && filtered_narrow_req[i].r_ready &&
            axi_narrow_rsp[i].r.last && axi_narrow_rsp[i].r.id == id) begin
          tmp_read[i] = regions_being_read[i][id].pop_front();
           $display("done reading [%x, %x]",tmp_read[i].start_addr, tmp_read[i].end_addr);
        end
        read_len[i][id]  = regions_being_read[i][id].size();
        write_len[i][id] = regions_being_written[i][id].size();
      end
    end
  end

  logic [TotalReq-1:0][TotalReq-1:0][2**AxiIdWidth-1:0][TxInFlight-1:0]
      write_overlapping_write, write_overlapping_read, read_overlapping_write;

  logic [TotalReq-1:0][TotalReq-1:0]
      live_write_overlapping_write, live_write_overlapping_read, live_read_overlapping_write;











  for (genvar i = 0; i < NumNarrowReq; i++) begin : gen_narrow_stim_axi_assignment
    `AXI_ASSIGN_TO_REQ(axi_narrow_req[i], axi_narrow_dv[i])
    `AXI_ASSIGN_FROM_RESP(axi_narrow_dv[i], axi_narrow_rsp[i])
  end

    // Stimuli Generation
  
  for (genvar i = 0; i < NumNarrowReq; i++) begin : gen_narrow_stim 
    initial begin
      pw_gate_ctrl         <= 1'b0;
      deepsleep_ctrl       <= 1'b0;
    //for (int i = 0; i < NumNarrowReq; i++) begin : gen_narrow_stim  
      narrow_rand_master[i] = new(axi_narrow_dv[i]);
      random_mem_filled[i] <= 1'b0;
      end_of_sim[i]        <= 1'b0;
      end_of_full_pwr[i]   <= 1'b0;
      end_of_pwr_gate[i]   <= 1'b0;


      // Make sure in on state everything works as normal
      narrow_rand_master[i].add_memory_region(TestRegionStart, TestRegionEnd,
                                              axi_pkg::DEVICE_NONBUFFERABLE);
      narrow_rand_master[i].reset();
      @(posedge rst_n);
      narrow_rand_master[i].run(0, 80);
      random_mem_filled[i] <= 1'b1;
      wait (&random_mem_filled);
      narrow_rand_master[i].run(80, 80);
      end_of_full_pwr[i] <= 1'b1;
      wait (&end_of_full_pwr);
      pw_gate_ctrl <= 1'b1;
      narrow_rand_master[i] = new(axi_narrow_dv[i]);

      // Make the port checking the powered region is not checking switched off regions
      if (i >= NumNarrowReq/2) begin
        narrow_rand_master[i].add_memory_region(TestRegionStart, ((NumPhysicalBanks - GatedBanks)*TestRegionEnd)/NumPhysicalBanks,
                                              axi_pkg::DEVICE_NONBUFFERABLE);
        //narrow_rand_master[i].reset();
        //@(posedge rst_n);
        //narrow_rand_master[i].run(0, 0);
        //random_mem_filled[i] <= 1'b1;
        //wait (&random_mem_filled);
        narrow_rand_master[i].run(50, 0);
        end_of_pwr_gate[i] <= 1'b1;
      end else begin
        narrow_rand_master[i].add_memory_region(((NumPhysicalBanks - GatedBanks)*TestRegionEnd)/NumPhysicalBanks, TestRegionEnd,
                                              axi_pkg::DEVICE_NONBUFFERABLE);
      //end
        //narrow_rand_master[i].reset();
        //@(posedge rst_n);
        //narrow_rand_master[i].run(0, 0);
        //random_mem_filled[i] <= 1'b1;
        //wait (&random_mem_filled);
        narrow_rand_master[i].run(50, 0);
        end_of_pwr_gate[i] <= 1'b1;
      end

      wait (&end_of_pwr_gate);
      gated_accs = gated;
      pw_gate_ctrl <= 1'b0;
      deepsleep_ctrl <= 1'b1;

      narrow_rand_master[i].run(50, 0);
      end_of_sim[i] <= 1'b1;

    end
  end


  for (genvar i = 0; i < NumNarrowReq; i++) begin : gen_narrow_limiting
    // Log address ranges of the requests
    assign write_range[i].start_addr = axi_narrow_req[i].aw.addr;
    assign write_range[i].end_addr = axi_narrow_req[i].aw.addr +
        ((2 ** axi_narrow_req[i].aw.size) * (axi_narrow_req[i].aw.len + 1));
    //assign write_range[i].end_addr = axi_narrow_req[i].aw.addr + 4;
    assign read_range[i].start_addr = axi_narrow_req[i].ar.addr;
    assign read_range[i].end_addr = axi_narrow_req[i].ar.addr +
        ((2 ** axi_narrow_req[i].ar.size) * (axi_narrow_req[i].ar.len + 1));
    //assign read_range[i].end_addr = axi_narrow_req[i].ar.addr + 4;

    assign aw_hs[i] = filtered_narrow_req[i].aw_valid && axi_narrow_rsp[i].aw_ready;
    assign ar_hs[i] = filtered_narrow_req[i].ar_valid && axi_narrow_rsp[i].ar_ready;

    always_comb begin
      for (int requestIdx = 0; requestIdx < TotalReq; requestIdx++) begin : gen_overlap_check_reqs
        for (int axiIdx = 0; axiIdx < 2 ** AxiIdWidth; axiIdx++) begin : gen_overlap_check_ids
          for (int txIdx = 0; txIdx < TxInFlight; txIdx++) begin : gen_overlap_check_txns

            // Block write if overlapping region is already being written
            write_overlapping_write[i][requestIdx][axiIdx][txIdx] =
                txIdx < write_len[requestIdx][axiIdx] ? check_overlap(
                write_range[i], regions_being_written[requestIdx][axiIdx][txIdx]) : '0;
            // Block reads if overlapping region is already being written
            read_overlapping_write[i][requestIdx][axiIdx][txIdx] =
                txIdx < write_len[requestIdx][axiIdx] ?
                check_overlap(read_range[i], regions_being_written[requestIdx][axiIdx][txIdx]) : '0;
            // Block write if overlapping region is already being read
            write_overlapping_read[i][requestIdx][axiIdx][txIdx] =
                txIdx < read_len[requestIdx][axiIdx] ?
                check_overlap(write_range[i], regions_being_read[requestIdx][axiIdx][txIdx]) : '0;
          end
        end
        live_write_overlapping_write[i][requestIdx] =
            check_overlap(write_range[i], write_range[requestIdx]);
        live_write_overlapping_read[i][requestIdx] =
            check_overlap(write_range[i], read_range[requestIdx]);
        live_read_overlapping_write[i][requestIdx] =
            check_overlap(read_range[i], write_range[requestIdx]);
      end
    end

    always_comb begin : proc_filter_narrow
      // By default connect all signals
      `AXI_SET_REQ_STRUCT(filtered_narrow_req[i], axi_narrow_req[i])
      `AXI_SET_RESP_STRUCT(axi_narrow_rsp[i], filtered_narrow_rsp[i])
      blocking_write[i] = '0;
      blocking_read[i]  = '0;

      // Block writes if necessary
      if (axi_narrow_req[i].aw_valid && filtered_narrow_rsp[i].aw_ready) begin
        // check in-flight requests
        if (|write_overlapping_write[i] || |write_overlapping_read[i]) begin
          filtered_narrow_req[i].aw_valid = 1'b0;
          axi_narrow_rsp[i].aw_ready      = 1'b0;
          blocking_write[i]               = 1'b1;
        end
        // check other ports
        for (int j = 0; j < i; j++) begin
          // Block write if overlapping region is starting to be written/read by lower ID
          if ((live_write_overlapping_write[i][j] && aw_hs[j]) ||
              (live_write_overlapping_read[i][j] && ar_hs[j])) begin
            filtered_narrow_req[i].aw_valid = 1'b0;
            axi_narrow_rsp[i].aw_ready      = 1'b0;
            blocking_write[i]               = 1'b1;
          end
        end
      end
      // Block reads if necessary
      if (axi_narrow_req[i].ar_valid && filtered_narrow_rsp[i].ar_ready) begin
        // check in-flight requests
        if (|read_overlapping_write[i]) begin
          filtered_narrow_req[i].ar_valid = 1'b0;
          axi_narrow_rsp[i].ar_ready      = 1'b0;
          blocking_read[i]                = 1'b1;
        end
        // check other ports
        for (int j = 0; j <= i; j++) begin
          // Block read if overlapping region is starting to be written by lower or same ID
          if ((live_read_overlapping_write[i][j] && aw_hs[j])) begin
            filtered_narrow_req[i].ar_valid = 1'b0;
            axi_narrow_rsp[i].ar_ready      = 1'b0;
            blocking_read[i]                = 1'b1;
          end
        end
      end
    end
  end






  for (genvar i = 0; i < NumNarrowReq; i++) begin : gen_narrow_check
    // Cut for TB logic loop
    axi_cut #(
      .aw_chan_t (narrow_aw_chan_t),
      .w_chan_t  (narrow_w_chan_t),
      .b_chan_t  (narrow_b_chan_t),
      .ar_chan_t (narrow_ar_chan_t),
      .r_chan_t  (narrow_r_chan_t),
      .axi_req_t (narrow_req_t),
      .axi_resp_t(narrow_resp_t)
    ) i_cut_filtered_narrow (
      .clk_i     (clk),
      .rst_ni    (rst_n),
      .slv_req_i (filtered_narrow_req[i]),
      .slv_resp_o(filtered_narrow_rsp[i]),
      .mst_req_o (filtered_narrow_req_cut[i]),
      .mst_resp_i(filtered_narrow_rsp_cut[i])
    );

    // Test
    axi_slave_compare #(
      .AxiIdWidth   (AxiIdWidth),
      .FifoDepth    (32),
      .UseSize      (1'b1),
      .DataWidth    (NarrowDataWidth),
      .axi_aw_chan_t(narrow_aw_chan_t),
      .axi_w_chan_t (narrow_w_chan_t),
      .axi_b_chan_t (narrow_b_chan_t),
      .axi_ar_chan_t(narrow_ar_chan_t),
      .axi_r_chan_t (narrow_r_chan_t),
      .axi_req_t    (narrow_req_t),
      .axi_rsp_t    (narrow_resp_t)
    ) i_narrow_compare (
      .clk_i         (clk),
      .rst_ni        (rst_n),
      .testmode_i    ('0),
      .axi_mst_req_i (filtered_narrow_req_cut[i]),
      .axi_mst_rsp_o (filtered_narrow_rsp_cut[i]),
      .axi_ref_req_o (dut_narrow_req[i]),           // bus_compare a
      .axi_ref_rsp_i (dut_narrow_rsp[i]),           // bus_compare a
      .axi_test_req_o(golden_narrow_req[i]),        // bus_compare b
      .axi_test_rsp_i(golden_narrow_rsp[i]),        // bus_compare b
      //.axi_test_req_o('z),        // bus_compare b
      //.axi_test_rsp_i('z),        // bus_compare b
      .aw_mismatch_o (),
      .w_mismatch_o  (),
      .b_mismatch_o  (),
      .ar_mismatch_o (),
      .r_mismatch_o  (),
      .mismatch_o    (mismatch[i]),
      .busy_o        ()
    );
  end



  // Implementation type for Power Gating and Deppesleep ports
  typedef struct packed {
     logic deepsleep;
     logic powergate;
  } impl_in_t;

  impl_in_t [PWRSigWidth-1:0] impl_o;

  for (genvar i = 0; i < PWRSigWidth; i++) begin : gen_pwr_assignment
    if (i >= PWRSigWidth - GatedBanks) begin
      assign impl_o[i].deepsleep = deepsleep_ctrl;
      assign impl_o[i].powergate = pw_gate_ctrl;
    end else begin
      assign impl_o[i].deepsleep = 0;
      assign impl_o[i].powergate = 0;
    end
  end


  // DUT
  axi_memory_island_wrap #(
    .AddrWidth       (AddrWidth),
    .NarrowDataWidth (NarrowDataWidth),
    .WideDataWidth   (WideDataWidth),
    .AxiNarrowIdWidth(AxiIdWidth),
    .AxiWideIdWidth  (AxiIdWidth),
    .axi_narrow_req_t(narrow_req_t),
    .axi_narrow_rsp_t(narrow_resp_t),
    .axi_wide_req_t  (wide_req_t),
    .axi_wide_rsp_t  (wide_resp_t),
    .NumNarrowReq    (NumNarrowReq),
    .NumWideReq      (NumWideReq),

    .SpillNarrowReqEntry (0),
    .SpillNarrowRspEntry (0),
    .SpillNarrowReqRouted(0),
    .SpillNarrowRspRouted(0),

    .SpillWideReqEntry (0),
    .SpillWideRspEntry (0),
    .SpillWideReqRouted(0),
    .SpillWideRspRouted(0),
    .SpillWideReqSplit (0),
    .SpillWideRspSplit (0),

    .SpillReqBank    (0),
    .SpillRspBank    (0),
    .WidePriorityWait(3),

    .NumWideBanks     (NumWideBanks),
    .NarrowExtraBF    (NarrowExtraBF),
    .WordsPerBank     (WordsPerBank),
    .MemorySimInit    ("zeros"),
    .BankAccessLatency(BankAccessLatency),

    .NWDivisor         (NWDivisor),
    .NumPhysicalBanks  (NumPhysicalBanks),
    .GatingGranularity (GatingGranularity),
    .PWRSigWidth       (PWRSigWidth),
    .impl_in_t         (impl_in_t),
    .Pwr_Sigs          (Pwr_Sigs)
  ) i_dut (
    .clk_i           (clk),
    .rst_ni          (rst_n),
    .axi_narrow_req_i(dut_narrow_req),
    .axi_narrow_rsp_o(dut_narrow_rsp),
    .axi_wide_req_i  (dut_wide_req),
    .axi_wide_rsp_o  (dut_wide_rsp),
    //.axi_wide_req_i  (),
    //.axi_wide_rsp_o  (),
    //.impl_i({deepsleep_o, powergate_o})
    .impl_i(impl_o)
  );

  // Golden model

  wide_req_t  [TotalReq-1:0] golden_all_req;
  wide_resp_t [TotalReq-1:0] golden_all_rsp;

  for (genvar i = 0; i < NumNarrowReq; i++) begin : gen_golden_narrow_upsizer
    axi_dw_upsizer #(
      .AxiMaxReads        (TxInFlight),
      .AxiSlvPortDataWidth(NarrowDataWidth),
      .AxiMstPortDataWidth(WideDataWidth),
      .AxiAddrWidth       (AddrWidth),
      .AxiIdWidth         (AxiIdWidth),
      .aw_chan_t          (narrow_aw_chan_t),
      .mst_w_chan_t       (wide_w_chan_t),
      .slv_w_chan_t       (narrow_w_chan_t),
      .b_chan_t           (narrow_b_chan_t),
      .ar_chan_t          (narrow_ar_chan_t),
      .mst_r_chan_t       (wide_r_chan_t),
      .slv_r_chan_t       (narrow_r_chan_t),
      .axi_mst_req_t      (wide_req_t),
      .axi_mst_resp_t     (wide_resp_t),
      .axi_slv_req_t      (narrow_req_t),
      .axi_slv_resp_t     (narrow_resp_t)
    ) i_narrow_upsizer (
      .clk_i     (clk),
      .rst_ni    (rst_n),
      .slv_req_i (golden_narrow_req[i]),
      .slv_resp_o(golden_narrow_rsp[i]),
      .mst_req_o (golden_all_req[i]),
      .mst_resp_i(golden_all_rsp[i])
    );
  end
  //for (genvar i = 0; i < NumWideReq; i++) begin : gen_golden_wide_assign
    //`AXI_ASSIGN_REQ_STRUCT(golden_all_req[NumNarrowReq+i], golden_wide_req[i])
    //`AXI_ASSIGN_RESP_STRUCT(golden_wide_rsp[i], golden_all_rsp[NumNarrowReq+i])
    //`AXI_ASSIGN_REQ_STRUCT(golden_all_req[NumNarrowReq+i], golden_wide_req[i])
    //`AXI_ASSIGN_RESP_STRUCT(golden_wide_rsp[i], golden_all_rsp[NumNarrowReq+i])
  //end

  axi_sim_mem #(
    .AddrWidth        (AddrWidth),
    .DataWidth        (WideDataWidth),
    .IdWidth          (AxiIdWidth),
    .UserWidth        (AxiUserWidth),
    .NumPorts         (TotalReq),
    .axi_req_t        (wide_req_t),
    .axi_rsp_t        (wide_resp_t),
    .WarnUninitialized(1'b0),
    .UninitializedData("zeros"),
    .ClearErrOnAccess (1'b0),
    .ApplDelay        (ApplTime),
    .AcqDelay         (TestTime)
  ) i_sim_mem (
    .clk_i             (clk),
    .rst_ni            (rst_n),
    .axi_req_i         (golden_all_req),
    .axi_rsp_o         (golden_all_rsp),
    .mon_w_valid_o     (),
    .mon_w_addr_o      (),
    .mon_w_data_o      (),
    .mon_w_id_o        (),
    .mon_w_user_o      (),
    .mon_w_beat_count_o(),
    .mon_w_last_o      (),
    .mon_r_valid_o     (),
    .mon_r_addr_o      (),
    .mon_r_data_o      (),
    .mon_r_id_o        (),
    .mon_r_user_o      (),
    .mon_r_beat_count_o(),
    .mon_r_last_o      ()
  );

  int unsigned errors;
  int unsigned errors_x;
  //int unsigned gated;

  always @(negedge clk) begin
    if (mismatch[0] === 1'bx) gated += 1;
    if (mismatch[1] === 1'bx) errors_x += 1;
  end

  // TB ctrl
  initial begin
    errors = 0;
    do begin
      #TestTime;
      errors += $countones(mismatch);
      if (end_of_sim == '1) begin
        if (gated_accs == 0) errors += 1;
        if (gated - gated_accs == 0) errors += 1;
        $display("Counted %d errors.", errors + errors_x);
        $display("Power Gated accesses: %d ", gated_accs);
        $display("Deepsleeped accesses: %d ", gated - gated_accs);
        $display("Total Gated accesses: %d ", gated);
        $finish(errors);
      end
      @(posedge clk);
    end while (1'b1);
  end

endmodule
