import { piToUnits } from "../crypto/units";

import {
  roundToStep,
  type RoundingMode
} from "../crypto/rounding";

export interface MiningBalanceResult {
  originalBalancePi: string;
  mathematicalUnits: string;
  roundedDisplayUnits: string;
  roundingMode: RoundingMode;
}

/**
 * Process a mining balance without modifying
 * the original PI balance.
 */
export function processMiningBalance(
  originalBalancePi: string,
  roundingMode: RoundingMode = "nearest",
  roundingStep: bigint = 100n
): MiningBalanceResult {
  const units = piToUnits(originalBalancePi);

  const roundedUnits = roundToStep(
    units,
    roundingStep,
    roundingMode
  );

  return {
    originalBalancePi,
    mathematicalUnits: units.toString(),
    roundedDisplayUnits: roundedUnits.toString(),
    roundingMode
  };
}
