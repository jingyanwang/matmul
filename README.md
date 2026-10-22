# Matrix Multiply-Accumulate Accelerator (18-240 Project 2)

A hardware accelerator, written in SystemVerilog for a Xilinx FPGA board, that computes

```
MMA = sum over all i, j of ( A[i][j] * B[j] )  +  sum over i of C[i]
```

where **A** is a 128×128 matrix of 8-bit values, **B** is a 128×1 vector of 8-bit values, and **C** is a 128×1 vector of 16-bit values. In other words, it computes the matrix-vector product **A·B**, adds **C**, and reduces the whole result to a single 32-bit checksum that is shown on the seven-segment display.

The design does **32 multiply-accumulates per clock cycle** and finishes the 16,384 multiplies in about **520 cycles** (the theoretical floor at 32 MACs/cycle is 512).

---

## Why this project: matmul is the backbone of AI hardware

Almost all of the work in a neural network is matrix multiplication. A fully connected layer is `y = W·x + b`. That has exactly the same shape as this project: **W** is A, **x** is B, and the bias **b** is C. Convolutions and transformer attention are also lowered to matrix multiplies before they run on hardware. That is why AI accelerators (GPU tensor cores, Google's TPU, and the NPUs in phones) are, at their core, large arrays of multiply-accumulate units with memory systems built to keep those units fed.

Building one at small scale makes the main design problems concrete:

| Problem in a real AI accelerator | How it shows up in this design |
|---|---|
| **Parallel MAC units.** Throughput comes from doing many multiplies at once. | 32 multipliers (`multiplier_8816`) run every cycle. |
| **Memory bandwidth is the real bottleneck.** The math units are cheap; feeding them is the hard part. | One block RAM gives at most 2 reads per cycle. Reaching 32 reads per cycle required **16 dual-port ROMs**, each holding a full copy of A. |
| **Data reuse.** A value fetched once should be used as many times as possible. | Each element of B (`B[col]`) is read once and broadcast to all 32 multipliers in that cycle. |
| **Low-precision integer math.** Inference often uses INT8 inputs with wider accumulators. | 8-bit × 8-bit → 16-bit products, accumulated in 32-bit registers so nothing overflows. |
| **Pipelining.** Long combinational paths limit clock speed. | Separate pipeline stages for memory read, multiply, accumulate, and a registered adder tree. |
| **Reduction trees.** Partial sums have to be combined efficiently. | A 5-level pipelined adder tree reduces 32 partial sums to 1. |

This is not a systolic array like a TPU's. It is a broadcast design: one value of B goes to every multiplier, and the partial sums stay in place in their accumulators. That still makes it a good way to see the trade-offs a systolic array is designed to solve.

---

## Repository contents

| File | Purpose |
|---|---|
| `ChipInterface.sv` (top level) | Board I/O, the compute datapath, the control FSMs, and helper modules (`Register`, `Synchronizer`). |
| `generate_matrix.py` | Generates random A, B and C as Xilinx `.coe` ROM initialization files and prints the expected answer. |
| `matA.coe`, `matB.coe`, `matC.coe` | The default dataset loaded into the ROMs. These are identical to test set 1. |
| `matA_N.coe`, `matB_N.coe`, `matC_N.coe` (N = 1–3) | Three test datasets. |

IP cores generated in Vivado (not in source form here):

| IP | Configuration |
|---|---|
| `romA_128x128` | Dual-port ROM, 16,384 × 8 bit, initialized from `matA.coe` (instantiated 16 times) |
| `romB_128x1` | ROM, 128 × 8 bit, initialized from `matB.coe` |
| `romC_128x1` | Dual-port ROM, 128 × 16 bit, initialized from `matC.coe` |
| `multiplier_8816` | Unsigned 8 × 8 → 16-bit multiplier |

Course-provided modules: `SevenSegmentDisplay`, `SSegDisplayDriver`.

> **ROM latency must be 1 cycle.** The FSM timing (the `BUFFER` and `WAIT` states) assumes the ROM output appears one clock edge after the address. In the Block Memory Generator, turn off the primitive and core output registers. If they are left on, the pipeline goes out of alignment by one cycle and the answer will be wrong.

---

## Architecture

```
          row,col counters
                 │
     ┌───────────┴──────────────┐
     ▼                          ▼
16× dual-port romA          romB[col]
(32 reads/cycle)           (1 read, broadcast)
     │  32 × 8-bit              │ 8-bit
     └────────────┬─────────────┘
                  ▼
        32 × multiplier_8816
                  │ 32 × 16-bit
                  ▼
        product registers (accum)
                  │
                  ▼
     32 × 32-bit accumulators (sum32Q)   ◄── runs for 512 cycles
                  │
                  ▼
   pipelined adder tree 32→16→8→4→2→1    ◄── 5 cycles
                  │                       ┌── sumC: adds all 128
                  ▼                       │   C values in parallel
             sumQ  ──────── + ────────────┘   (2 per cycle)
                            │
                            ▼
                answerQ ──► 7-segment display
```

### Memory layout and addressing

Every one of the 16 `romA` instances holds the **entire** A matrix in row-major order (address = `row*128 + col`). Duplicating the data is how the design gets 32 independent read ports out of block RAM, which is a deliberate trade of memory area for bandwidth.

Each port's address is built as:

```
addr = { row[1:0], port, m[3:0], col[6:0] }
          │         │     │       └─ column j (0–127)
          │         │     └───────── ROM instance m (0–15)
          │         └─────────────── port A = 0, port B = 1
          └───────────────────────── which group of 32 rows (0–3)
```

The upper 7 bits form the matrix row index `row*32 + port*16 + m`. In one cycle the 32 ports read 32 different rows of A, all in the same column `col`. All 32 elements get multiplied by the same `B[col]`.

### Iteration order

- `row` (2 bits) increments every cycle and selects one of four groups of 32 rows.
- `col` (7 bits) increments every 4 cycles.
- 4 row groups × 128 columns = **512 cycles**. 512 cycles × 32 MACs = 16,384 = 128 × 128 products.

Accumulator `i` collects the products for rows `i`, `i+32`, `i+64` and `i+96`. That is fine here, because the final result is a total over everything and does not need each row's sum separately.

### Bit widths

- Product: 255 × 255 = 65,025, which fits in 16 bits.
- One accumulator: 512 × 65,025 ≈ 3.3 × 10⁷, which fits in 26 bits.
- Total A·B: 16,384 × 65,025 ≈ 1.07 × 10⁹, plus C (at most 128 × 65,535 ≈ 8.4 × 10⁶), which is less than 2³² ≈ 4.29 × 10⁹. **32 bits cannot overflow.**

### Control: main FSM (`fsm`)

| State | `computing` | `enAccum` | `adding` | What happens |
|---|:-:|:-:|:-:|---|
| `START` | | | | Idle for one cycle after reset. |
| `BUFFER1` | ✔ | | | First address sent to the ROMs. |
| `BUFFER2` | ✔ | | | ROM data → multiplier → `accum` register. Filling the pipeline. |
| `MULTI` | ✔ | ✔ | | Steady state: addresses are issued and products accumulated every cycle, until `isLastAddr` (row = 3, col = 127). |
| `WAIT1`, `WAIT2` | | ✔ | | Drain the 2-stage pipeline so the last two products get accumulated. |
| `ADD` | | | ✔ | Run the adder tree for 5 cycles (`countAdd` 0–4), one level per cycle. |
| `DONE` | | | | Latch `answerQ = sumQ + cSum` (once `sumC` is also done). Stop `clockCount`. |

### Sum of C (`sumC`)

This runs in parallel with the main computation. The dual-port `romC` reads `C[idx]` and `C[idx+64]` each cycle, so all 128 values are summed in 64 cycles. That is well before the matrix product finishes, so it costs no extra time.

---

## Using it on the board

1. Build the Vivado project with the IP cores above, initialized from `matA.coe`, `matB.coe` and `matC.coe`.
2. Program the board. Press **BTN[0]** to reset and start the computation.
3. Read the result on the 8-digit seven-segment display, in hex:
   - **SW[0] = 0** shows the MMA answer.
   - **SW[0] = 1** shows the cycle count.

### Expected results

| Dataset | A·B sum | C sum | **MMA answer (display)** |
|---|---|---|---|
| default (`matA/B/C.coe`) = set 1 | `0x0E44DD03` | `0x004025F7` | **`0E8502FA`** |
| set 2 (`*_2.coe`) | `0x0FFF9D25` | `0x003EB7E2` | **`103E5507`** |
| set 3 (`*_3.coe`) | `0x0EAF28F6` | `0x00428BBD` | **`0EF1B4B3`** |

The cycle count should read about `0x208`–`0x20A` (about 520 cycles, or about 5.2 µs at 100 MHz).

To test with a new random dataset:

```bash
python3 generate_matrix.py matA_gen.coe matB_gen.coe matC_gen.coe
```

The script prints the expected `MMA product`. Re-point the ROM IP at the new `.coe` files and regenerate the IP before rebuilding.

---

## Performance summary

| Metric | Value |
|---|---|
| Multipliers | 32 (8 × 8 bit, unsigned) |
| MACs per cycle | 32 |
| Total MACs | 16,384 |
| Cycles (reset to done) | ≈ 520 (512 compute + pipeline fill/drain + 5 adder-tree cycles) |
| Time at 100 MHz | ≈ 5.2 µs |
| Block RAM for A | 16 copies × 16 KB (duplicated for bandwidth) |

---

## What I'd explore next

- **Systolic array.** Pass operands between neighboring MAC units instead of storing 16 copies of A. This is the approach TPUs use to cut memory bandwidth.
- **Banking instead of duplication.** Split A across ROMs by row (each ROM holding only 1/32 of the matrix) to get the same bandwidth with 1/16 of the memory.
- **Full matrix-matrix multiply (GEMM).** With a B matrix instead of a vector, each value of A could be reused across many columns. This is where real accelerators get their efficiency, measured as arithmetic intensity.
- **Signed / INT8-with-scale arithmetic**, as used in quantized neural network inference.
- **Fewer reduction cycles.** The adder tree could run concurrently with the last accumulations, or be collapsed into fewer pipeline stages if timing allows.

---

## Revision notes

There are two versions of the top-level file. Both compute the same answer.

- **v1:** `sumC` is written as a behavioral `always_ff` block. `` `default_nettype none `` is enabled.
- **v2:** `sumC` is rewritten as an explicit FSM (`INIT → START → ADD → LAST → DONE`) built from `Register` instances. Zero-extension in the accumulator is written out explicitly (`{16'd0, accum[i]}`). `Register` and `Synchronizer` are included in the file, and `` `default_nettype none `` is commented out to avoid synthesis issues.# matmul
