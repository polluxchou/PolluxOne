// pipeline/test/config/env.test.ts
import { describe, expect, it } from "vitest";
import { parseEnvFile, resolveConfig } from "../../src/config/env.js";

describe("parseEnvFile", () => {
  it("读得出键值", () => {
    expect(parseEnvFile("A=1\nB=hello")).toEqual({ A: "1", B: "hello" });
  });

  it("跳过注释和空行", () => {
    expect(parseEnvFile("# 注释\n\nA=1\n  # 缩进注释\n")).toEqual({ A: "1" });
  });

  it("值里带等号不截断", () => {
    expect(parseEnvFile("URL=https://x.com/?a=1&b=2")).toEqual({
      URL: "https://x.com/?a=1&b=2",
    });
  });

  it("去掉包裹的引号", () => {
    expect(parseEnvFile(`A="quoted"\nB='single'`)).toEqual({
      A: "quoted",
      B: "single",
    });
  });
});

describe("resolveConfig", () => {
  it("齐全时返回配置", () => {
    const cfg = resolveConfig({
      DEEPSEEK_API_KEY: "sk-x",
      DEEPSEEK_BASE_URL: "https://api.deepseek.com",
      ANTHROPIC_API_KEY: "sk-ant-y",
    });
    expect(cfg.deepseek.apiKey).toBe("sk-x");
    expect(cfg.anthropic.apiKey).toBe("sk-ant-y");
  });

  it("baseUrl 缺省有默认值", () => {
    const cfg = resolveConfig({ DEEPSEEK_API_KEY: "sk-x", ANTHROPIC_API_KEY: "sk-ant-y" });
    expect(cfg.deepseek.baseUrl).toBe("https://api.deepseek.com");
  });

  it("缺 key 时抛，且说清缺哪个", () => {
    expect(() => resolveConfig({ DEEPSEEK_API_KEY: "sk-x" })).toThrow(
      /ANTHROPIC_API_KEY/,
    );
  });

  it("空字符串等同于缺失——填了等号但没填值是最常见的错", () => {
    expect(() =>
      resolveConfig({ DEEPSEEK_API_KEY: "sk-x", ANTHROPIC_API_KEY: "   " }),
    ).toThrow(/ANTHROPIC_API_KEY/);
  });
});
