import { describe, expect, it } from "vitest";
import { collectSearchResults } from "../../src/models/search.js";

describe("collectSearchResults", () => {
  it("从 web_search_tool_result 块里收 URL", () => {
    const urls = collectSearchResults([
      {
        type: "web_search_tool_result",
        content: [
          { type: "web_search_result", url: "https://a.com/1", title: "A" },
          { type: "web_search_result", url: "https://b.com/2", title: "B" },
        ],
      },
    ] as never);
    expect(urls).toEqual(["https://a.com/1", "https://b.com/2"]);
  });

  it("忽略非搜索块", () => {
    const urls = collectSearchResults([
      { type: "text", text: "我来搜一下" },
      {
        type: "web_search_tool_result",
        content: [{ type: "web_search_result", url: "https://a.com/1" }],
      },
    ] as never);
    expect(urls).toEqual(["https://a.com/1"]);
  });

  it("出错时 content 是对象不是数组——不能当成结果去遍历", () => {
    const urls = collectSearchResults([
      { type: "web_search_tool_result", content: { error_code: "max_uses_exceeded" } },
    ] as never);
    expect(urls).toEqual([]);
  });

  it("去重，保持首次出现的顺序", () => {
    const urls = collectSearchResults([
      {
        type: "web_search_tool_result",
        content: [
          { type: "web_search_result", url: "https://a.com/1" },
          { type: "web_search_result", url: "https://a.com/1" },
          { type: "web_search_result", url: "https://b.com/2" },
        ],
      },
    ] as never);
    expect(urls).toEqual(["https://a.com/1", "https://b.com/2"]);
  });

  it("没有任何搜索块时返回空数组", () => {
    expect(collectSearchResults([{ type: "text", text: "x" }] as never)).toEqual([]);
  });
});
