// pipeline/test/net/http.test.ts
import { describe, expect, it, vi } from "vitest";
import { classifyStatus, requestWithRetry } from "../../src/net/http.js";

describe("classifyStatus", () => {
  it("429 和 5xx 该重试", () => {
    expect(classifyStatus(429)).toBe("retry");
    expect(classifyStatus(500)).toBe("retry");
    expect(classifyStatus(503)).toBe("retry");
  });

  it("4xx（429 除外）重试也没用", () => {
    expect(classifyStatus(400)).toBe("fatal");
    expect(classifyStatus(401)).toBe("fatal");
    expect(classifyStatus(404)).toBe("fatal");
  });

  it("2xx 是成功", () => {
    expect(classifyStatus(200)).toBe("ok");
  });
});

describe("requestWithRetry", () => {
  it("一次就成功时不重试", async () => {
    const fn = vi.fn().mockResolvedValue(new Response("ok", { status: 200 }));
    const res = await requestWithRetry(fn, { attempts: 3, backoffMs: 0 });
    expect(await res.text()).toBe("ok");
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("429 之后重试并最终成功", async () => {
    const fn = vi
      .fn()
      .mockResolvedValueOnce(new Response("", { status: 429 }))
      .mockResolvedValueOnce(new Response("ok", { status: 200 }));
    const res = await requestWithRetry(fn, { attempts: 3, backoffMs: 0 });
    expect(res.status).toBe(200);
    expect(fn).toHaveBeenCalledTimes(2);
  });

  it("400 立刻放弃，不浪费重试额度", async () => {
    const fn = vi.fn().mockResolvedValue(new Response("bad", { status: 400 }));
    await expect(
      requestWithRetry(fn, { attempts: 3, backoffMs: 0 }),
    ).rejects.toThrow(/400/);
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("重试用尽后抛，错误里带最后一次状态码", async () => {
    const fn = vi.fn().mockResolvedValue(new Response("", { status: 503 }));
    await expect(
      requestWithRetry(fn, { attempts: 2, backoffMs: 0 }),
    ).rejects.toThrow(/503/);
    expect(fn).toHaveBeenCalledTimes(2);
  });

  it("网络异常也走重试", async () => {
    const fn = vi
      .fn()
      .mockRejectedValueOnce(new Error("ECONNRESET"))
      .mockResolvedValueOnce(new Response("ok", { status: 200 }));
    const res = await requestWithRetry(fn, { attempts: 3, backoffMs: 0 });
    expect(res.status).toBe(200);
  });
});
