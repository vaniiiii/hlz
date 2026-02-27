import { defineConfig } from "vocs";
import { sidebar } from "./sidebar/sidebar";

export default defineConfig({
  title: "hlz — Zig Tooling for Hyperliquid",
  basePath: "/hlz",
  rootDir: ".",
  sidebar,
  theme: {
    colorScheme: "dark",
  },
  accentColor: "#f7a41d",
  logoUrl: "/hlz-logo.svg",
  iconUrl: "/favicon.svg",
  editLink: {
    link: "https://github.com/vaniiiii/hlz/edit/main/docs/pages/:path",
    text: "Edit on GitHub",
  },
  socials: [
    {
      link: "https://github.com/vaniiiii/hlz",
      icon: "github",
    },
  ],
  topNav: [
    { link: "/introduction/getting-started", text: "Docs" },
    { link: "/guides", text: "Guides" },
    {
      text: "Reference",
      items: [
        { text: "CLI Commands", link: "/reference/cli" },
        { text: "SDK API", link: "/reference/sdk" },
        { text: "TUI Framework", link: "/reference/tui" },
        { text: "WebSocket", link: "/reference/websocket" },
      ],
    },
    { link: "/benchmarks", text: "Benchmarks" },
  ],
});
