/**
 * PiRC3 Wallet Rounding Engine
 *
 * Rounding is performed using integer arithmetic.
 */

export type RoundingMode =
  | "floor"
  | "ceil"
  | "nearest";

/**
 * Round an integer balance to a multiple of step.
 *
 * Example:
 * roundToStep(1234n, 100n, "nearest") -> 1200n
 * roundToStep(1250n, 100n, "nearest") -> 1300n
 */
export function roundToStep(
  value: bigint,
  step: bigint,
  mode: RoundingMode = "nearest"
): bigint {
  if (step <= 0n) {
    throw new Error("Step must be greater than zero");
  }

  if (value < 0n) {
    throw new Error("Balance cannot be negative");
  }

  const quotient = value / step;
  const remainder = value % step;

  switch (mode) {
    case "floor":
      return quotient * step;

    case "ceil":
      return (
        remainder === 0n
          ? quotient
          : quotient + 1n
      ) * step;

    case "nearest":
      return (
        remainder * 2n >= step
          ? quotient + 1n
          : quotient
      ) * step;

    default:
      throw new Error("Unsupported rounding mode");
  }
}
