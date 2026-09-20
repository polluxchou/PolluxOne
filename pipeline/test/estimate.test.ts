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

test("a value exactly between two steps rounds down", () => {
  // 拨盘被拖拽时中点天天经过。`<` 加上从左往右 reduce，等距时保留更小的档——
  // 改成 `<=` 会把所有中点静默翻向上，而 Swift 端若实现方式不同就会和这里分歧。
  expect(estimateBrief(37.5, 0.5).durationSec).toBe(30);
  expect(estimateBrief(105, 0.5).durationSec).toBe(90);
  expect(estimateBrief(270, 0.5).durationSec).toBe(240);
});

test("the register axis pushes cost up too", () => {
  // 上一条只扫了 duration 轴，名字却说「两轴」。这一条把 register 轴补上。
  let previous = -1;
  for (const register of [0, 0.2, 0.4, 0.6, 0.8, 1]) {
    const tokens = estimateBrief(120, register).tokens;
    expect(tokens).toBeGreaterThan(previous);
    previous = tokens;
  }
});

test("the source count rounds rather than truncates", () => {
  // 两个锚点取整前恰好都是整数（11.0 和 21.0），所以 round→floor 这个改动
  // 在它们身上完全隐身。(90, 0.5) 取整前是 14.5，能区分。
  const e = estimateBrief(90, 0.5);
  expect(e.sources).toBe(15);
  expect(e.tokens).toBe(104000);
  expect(e.factSlots).toBe(4);
  expect(e.researchMinutes).toBe(5);
});

// 做回归标定的人注意：这条会在你第一次改系数时失败，那是设计如此，不是你引入的 bug。
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
