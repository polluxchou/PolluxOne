/** ② 拨盘纵轴的十档。iOS 侧的拨盘必须用同一组值。 */
export const DURATION_STEPS = [30, 45, 60, 90, 120, 150, 180, 240, 300, 360] as const;

/**
 * 这些系数目前来自 mock 的手调值。
 * **下一个计划要用真实样本的实际消耗把它们回归出来**——spec §10.1 的未决问题之一：
 * 估低了用户会觉得被骗。测试钉住当前值，改动必须是明知故犯。
 */
export const ESTIMATE_COEFFICIENTS = {
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
} as const;

export interface BriefEstimate {
  durationSec: number;
  /** 0 = 八卦，1 = 专业 */
  register: number;
  sources: number;
  factSlots: number;
  tokens: number;
  researchMinutes: number;
}

/**
 * 落到最近的一档。**等距时保留更小的那一档**（`<` 加上从左往右扫描）——
 * 拨盘拖拽时中点天天经过，这个方向必须是写明的决定，不能是实现的副产品。
 *
 * iOS 侧的拨盘本来只会产出这十个值，所以这里的 snap 是**防御性**的；
 * 档位的权威定义始终是 `DURATION_STEPS` 本身。
 */
function snapDuration(durationSec: number): number {
  return DURATION_STEPS.reduce((best, step) =>
    Math.abs(step - durationSec) < Math.abs(best - durationSec) ? step : best,
    DURATION_STEPS[0]);
}

/**
 * §10.1：花钱之前就把账算给用户看。
 * 纯函数，没有 IO——iOS 侧照抄同一组系数即可得到同样的数字。
 */
export function estimateBrief(durationSec: number, register: number): BriefEstimate {
  const c = ESTIMATE_COEFFICIENTS;
  const sec = snapDuration(durationSec);
  const reg = Math.min(1, Math.max(0, register));

  return {
    durationSec: sec,
    register: reg,
    // register 是连续量（拨盘可以停在任意位置），所以这一项会出小数。
    // token 是计数单位，而且同一个对象里另外三个字段都取整了。
    tokens: Math.round(c.tokensBase + sec * c.tokensPerSecond + reg * c.tokensPerRegister),
    sources: Math.round(c.sourcesBase + (sec / 60) * c.sourcesPerMinute + reg * c.sourcesPerRegister),
    factSlots: Math.max(c.minimumFactSlots, Math.round(sec / c.secondsPerFactSlot)),
    researchMinutes: Math.round(c.minutesBase + (sec / 60) * c.minutesPerMinute + reg * c.minutesPerRegister),
  };
}
