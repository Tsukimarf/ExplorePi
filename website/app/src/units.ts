/**
 * PiRC3 Mathematical Unit Conversion
 *
 * K = 314159
 *
 * IMPORTANT:
 * This is an internal mathematical conversion constant.
 * It does not represent an official Pi Network market price.
 */

export const PIRC3_CONSTANT = 314159n;

export interface PiBalance {
  balancePi: string;
}

export interface ConvertedBalance {
  originalBalancePi: string;
  mathematicalUnits: bigint;
}

/**
 * Convert a decimal PI balance into internal PiRC3 units.
 *
 * Example:
 * 1 PI -> 314159 units
 *
 * Uses integer arithmetic to avoid floating-point errors.
 */
export function piToUnits(balancePi: string): bigint {
  if (!/^\d+(\.\d+)?$/.test(balancePi)) {
    throw new Error("Invalid PI balance");
  }

  const [whole, fraction = ""] = balancePi.split(".");

  // The input is limited to six decimal places.
  if (fraction.length > 6) {
    throw new Error(
      "PI balance supports a maximum of 6 decimal places"
    );
  }

  const scale = 1_000_000n;
  const fractionalValue = BigInt(
    fraction.padEnd(6, "0") || "0"
  );

  const balanceMicros =
    BigInt(whole) * scale + fractionalValue;

  // Exact conversion with six-decimal input precision.
  return (
    balanceMicros * PIRC3_CONSTANT
  ) / scale;
}

/**
 * Format integer units as a decimal string.
 */
export function formatUnits(units: bigint): string {
  return units.toString();
}
