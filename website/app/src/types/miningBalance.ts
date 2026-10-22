export interface MiningBalance {
  walletId: string;

  /**
   * Original PI balance.
   * Store as a decimal string to avoid floating-point errors.
   */
  originalBalancePi: string;

  /**
   * Internal PiRC3 mathematical units.
   */
  mathematicalUnits: string;

  /**
   * Rounded display value.
   */
  roundedDisplayUnits: string;

  roundingMode: "floor" | "ceil" | "nearest";

  /**
   * Internal mathematical constant.
   */
  conversionConstant: "314159";

  updatedAt: string;
}
