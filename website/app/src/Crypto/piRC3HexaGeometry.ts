/**
 * PiRC3 Hexagonal Geometry Model
 *
 * Uses:
 * - Pythagorean theorem
 * - Six-sided polygon validation
 * - Regular hexagon area
 * - Normalized geometric ratio
 *
 * Geometry does not determine an official PI market price.
 */

export interface HexagonInput {
  sides: [
    number,
    number,
    number,
    number,
    number,
    number
  ];
}

export interface GeometryResult {
  valid: boolean;
  sideLength: number;
  area: number;
  diagonal: number;
  normalizedRatio: number;
}

/**
 * Calculate the hypotenuse using Pythagoras.
 */
export function pythagoras(
  a: number,
  b: number
): number {
  if (
    !Number.isFinite(a) ||
    !Number.isFinite(b) ||
    a <= 0 ||
    b <= 0
  ) {
    throw new Error("Invalid triangle dimensions");
  }

  return Math.hypot(a, b);
}

/**
 * Calculate the area of a regular hexagon.
 *
 * H = (3 * sqrt(3) / 2) * s^2
 */
export function hexagonArea(
  sideLength: number
): number {
  if (
    !Number.isFinite(sideLength) ||
    sideLength <= 0
  ) {
    throw new Error("Invalid hexagon side length");
  }

  return (
    (3 * Math.sqrt(3)) / 2
  ) * sideLength * sideLength;
}

/**
 * Validate six equal sides and calculate geometry.
 *
 * Reference area is the area of a regular hexagon
 * with side length 1.
 */
export function calculateHexagon(
  input: HexagonInput
): GeometryResult {
  const sides = input.sides;

  if (sides.length !== 6) {
    throw new Error("Exactly six sides are required");
  }

  for (const side of sides) {
    if (!Number.isFinite(side) || side <= 0) {
      throw new Error("All sides must be positive");
    }
  }

  const sideLength = sides[0];

  const tolerance = 1e-9;

  const valid = sides.every(
    side =>
      Math.abs(side - sideLength) <=
      tolerance * Math.max(1, sideLength)
  );

  if (!valid) {
    throw new Error(
      "Regular hexagon requires six equal sides"
    );
  }

  const area = hexagonArea(sideLength);

  const referenceArea = hexagonArea(1);

  const normalizedRatio =
    area / referenceArea;

  // For a regular hexagon, the long diagonal is 2s.
  const diagonal = 2 * sideLength;

  return {
    valid: true,
    sideLength,
    area,
    diagonal,
    normalizedRatio
  };
}
