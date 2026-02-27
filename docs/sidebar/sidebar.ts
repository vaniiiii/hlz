import type { Sidebar } from "vocs";

const docs = [
  {
    text: "Introduction",
    items: [
      { text: "Getting Started", link: "/introduction/getting-started" },
      { text: "Installation", link: "/introduction/installation" },
      { text: "Configuration", link: "/introduction/configuration" },
    ],
  },
  {
    text: "CLI",
    items: [
      { text: "Overview", link: "/cli" },
      { text: "Market Data", link: "/cli/market-data" },
      { text: "Trading", link: "/cli/trading" },
      { text: "Account", link: "/cli/account" },
      { text: "Transfers", link: "/cli/transfers" },
      { text: "Streaming", link: "/cli/streaming" },
      { text: "Key Management", link: "/cli/keys" },
      { text: "Agent Integration", link: "/cli/agent-integration" },
    ],
  },
  {
    text: "SDK",
    items: [
      { text: "Overview", link: "/sdk" },
      { text: "Client", link: "/sdk/client" },
      { text: "Signing", link: "/sdk/signing" },
      { text: "WebSocket", link: "/sdk/websocket" },
      { text: "Types", link: "/sdk/types" },
      { text: "Decimal Math", link: "/sdk/decimal" },
    ],
  },
  {
    text: "Terminal",
    items: [
      { text: "Overview", link: "/terminal" },
      { text: "Keybindings", link: "/terminal/keybindings" },
      { text: "Architecture", link: "/terminal/architecture" },
    ],
  },
  {
    text: "TUI Framework",
    items: [
      { text: "Overview", link: "/tui" },
      { text: "App", link: "/tui/app" },
      { text: "Buffer", link: "/tui/buffer" },
      { text: "Terminal", link: "/tui/terminal" },
      { text: "Layout", link: "/tui/layout" },
      { text: "Widgets", link: "/tui/widgets" },
    ],
  },
  {
    text: "Guides",
    items: [
      { text: "Building a Trading Bot", link: "/guides/trading-bot" },
      { text: "Streaming Market Data", link: "/guides/streaming" },
      { text: "Agent Payments", link: "/guides/agent-payments" },
    ],
  },
];

export const sidebar: Sidebar = {
  "/benchmarks": [],
  "/": [],
  "/introduction": docs,
  "/cli": docs,
  "/sdk": docs,
  "/terminal": docs,
  "/tui": docs,
  "/guides": docs,
  "/reference": docs,
};
