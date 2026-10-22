# Matrix Multiplier

Computes **A·B + C** on an FPGA and reduces the result to a single 32-bit number, where A is 128×128 (8-bit), B is 128×1 (8-bit) and C is 128×1 (16-bit). It uses 32 parallel multipliers and finishes in **520 cycles**:

- 512 for the multiplies (the speed-of-light limit at 32 multiplies per cycle)
- 2 to fill the pipeline
- 5 for the adder tree
- 1 for the answer to show up

See the design doc for architecture details.

## Files

| File | Purpose |
|---|---|
| `matrix_multiply.sv` | Top level, datapath and control FSMs |
| `generate_matrix.py` | Generates random `.coe` test data and prints the expected answer |

Required Vivado IP: `romA_128x128` (dual-port), `romB_128x1`, `romC_128x1` (dual-port) and `multiplier_8816`. Set the ROMs to **1-cycle read latency** (output registers off).

## Usage

1. Build in Vivado with the ROMs initialized from the `.coe` files.
2. Press **BTN[0]** to reset and run.
3. Read the result in hex: **SW[0] = 0** shows the answer, **SW[0] = 1** shows the cycle count.

## Generating Test Data

```bash
python3 generate_matrix.py matA_gen.coe matB_gen.coe matC_gen.coe
```

This writes random A, B and C matrices to the three `.coe` files and prints the correct answer.
