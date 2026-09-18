import { expect, test } from "vitest";
import { DURATION_STEPS, ESTIMATE_COEFFICIENTS, estimateBrief } from "../src/domain/estimate.js";

test("the dial's ten duration steps are the ones the mock shows", () => {
  expect(DURATION_STEPS).toEqual([30, 45, 60, 90, 120, 150, 180, 240, 300, 360]);
});

test("an off-step duration snaps to the nearest step", () => {
  expect(estimateBrief(100, 0.5).durationSec).toBe(90);
  expect(estimateBrief(1, 0.5).durationSec).toBe(30);
  expect(estimateBrief(9999, 0.5).durationSec).toBe(360);
});

test("register is clamped to 0..1", () => {
  expect(estimateBrief(60, -3).register).toBe(0);
  expect(estimateBrief(60, 7).register).toBe(1);
});

test("the 1:00 通俗 anchor", () => {
  const e = estimateBrief(60, 0.25);
  expect(e.tokens).toBe(68500);
  expect(e.sources).toBe(11);
  expect(e.factSlots).toBe(3);
  expect(e.researchMinutes).toBe(4);
});

test("the 3:00 偏专业 anchor", () => {
  const e = estimateBrief(180, 0.75);
  expect(e.tokens).toBe(175500);
  expect(e.sources).toBe(21);
  expect(e.factSlots).toBe(7);
  // 2 + 3×1.2 + 0.75×2.5 = 7.475 → 7
  expect(e.researchMinutes).toBe(7);
});

test("both axes only ever push cost up", () => {
  const cheap = estimateBrief(30, 0);
  const dear = estimateBrief(360, 1);
  expect(cheap.tokens).toBeLessThan(dear.tokens);
  for (let i = 1; i < DURATION_STEPS.length; i++) {
    const prev = estimateBrief(DURATION_STEPS[i - 1]!, 0.5).tokens;
    expect(estimateBrief(DURATION_STEPS[i]!, 0.5).tokens).toBeGreaterThan(prev);
  }
});

test("the coefficients are pinned so a change has to be deliberate", () => {
  expect(ESTIMATE_COEFFICIENTS).toEqual({
    tokensBase: 15000,
    tokensPerSecond: 600,
    tokensPerRegister: 70000,
    sourcesBase: 6,
    sourcesPerMinute: 3,
    sourcesPerRegister: 8,
    secondsPerFactSlot: 25,
    minimumFactSlots: 3,
    minutesBase: 2,
    minutesPerMinute: 1.2,
    minutesPerRegister: 2.5,
  });
});
