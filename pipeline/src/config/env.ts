// pipeline/src/config/env.ts
import { readFileSync } from "node:fs";

export interface Config {
  deepseek: { apiKey: string; baseUrl: string };
  anthropic: { apiKey: string };
}

const DEFAULT_DEEPSEEK_BASE_URL = "https://api.deepseek.com";

/** 极小的 .env 解析器——不装 dotenv 是因为这 15 行不值得一个依赖。 */
export function parseEnvFile(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const rawLine of text.split("\n")) {
    const line = rawLine.trim();
    if (line === "" || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    // 只切第一个等号：URL 的 query string 里全是等号。
    let value = line.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"') && value.length >= 2) ||
      (value.startsWith("'") && value.endsWith("'") && value.length >= 2)
    ) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

export function resolveConfig(env: Record<string, string | undefined>): Config {
  const missing: string[] = [];
  const need = (key: string): string => {
    const value = (env[key] ?? "").trim();
    // 空值当缺失：`KEY=` 是填表时最常见的半成品，让它走到网络层再报 401 是浪费。
    if (value === "") missing.push(key);
    return value;
  };

  const deepseekKey = need("DEEPSEEK_API_KEY");
  const anthropicKey = need("ANTHROPIC_API_KEY");

  if (missing.length > 0) {
    throw new Error(
      `pipeline/.env.local 里缺这些值：${missing.join("、")}。` +
        `照着 pipeline/.env.example 填，别把值贴进任何对话或提交。`,
    );
  }

  return {
    deepseek: {
      apiKey: deepseekKey,
      baseUrl: (env.DEEPSEEK_BASE_URL ?? "").trim() || DEFAULT_DEEPSEEK_BASE_URL,
    },
    anthropic: { apiKey: anthropicKey },
  };
}

/** 从磁盘读。找不到文件时给出能照做的提示，而不是一个 ENOENT。 */
export function loadConfig(path = "pipeline/.env.local"): Config {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    throw new Error(
      `读不到 ${path}。先 cp pipeline/.env.example pipeline/.env.local 再填值。`,
    );
  }
  return resolveConfig({ ...parseEnvFile(text) });
}
