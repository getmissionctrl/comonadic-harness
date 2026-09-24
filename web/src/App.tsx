import { useMemo, useState } from "react";
import type { FC } from "react";
import {
  AssistantRuntimeProvider,
  ThreadPrimitive,
  MessagePrimitive,
  ComposerPrimitive,
} from "@assistant-ui/react";
import { useAgUiRuntime } from "@assistant-ui/react-ag-ui";
import { HttpAgent } from "@ag-ui/client";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

// The standard AG-UI endpoint exposed by the Haskell harness server
// (Harness.AgUi.Server, POST /agent). Override with VITE_AGENT_URL if the
// server runs on another port.
const AGENT_URL =
  (import.meta.env.VITE_AGENT_URL as string | undefined) ??
  "http://localhost:8080/agent";

// The control endpoint (POST /config {think}) lives beside /agent on the same
// server; derive it so a single VITE_AGENT_URL configures both.
const CONFIG_URL = AGENT_URL.replace(/\/agent$/, "/config");

const bubble = (mine: boolean): React.CSSProperties => ({
  alignSelf: mine ? "flex-end" : "flex-start",
  background: mine ? "#2563eb" : "#e5e7eb",
  color: mine ? "white" : "#111827",
  padding: "8px 12px",
  borderRadius: 12,
  margin: "4px 0",
  maxWidth: "80%",
});

const UserMessage: FC = () => (
  <MessagePrimitive.Root style={{ display: "flex", flexDirection: "column", alignItems: "flex-end" }}>
    <div style={{ ...bubble(true), whiteSpace: "pre-wrap" }}>
      <MessagePrimitive.Content />
    </div>
  </MessagePrimitive.Root>
);

// Renders assistant text as Markdown (GFM: tables, lists, code, links) instead of
// a raw string. The component slot receives the streaming `text`, so it re-renders
// as tokens arrive — the ".md" wrapper just tightens block margins inside the bubble.
const MarkdownText: FC<any> = ({ text }) => (
  <div className="md">
    <ReactMarkdown remarkPlugins={[remarkGfm]}>{text ?? ""}</ReactMarkdown>
  </div>
);

// Renders a tool call (name + args, then its result once it lands). Without this
// a tool-only turn shows nothing until the next turn's text streams — the harness
// emits TOOL_CALL_START/ARGS/END and TOOL_CALL_RESULT, but MessagePrimitive.Content
// has no default UI for tool parts.
const clip = (s: string, n = 600) => (s.length > n ? s.slice(0, n) + " …[+" + (s.length - n) + " chars]" : s);

const ToolFallback: FC<any> = ({ toolName, argsText, args, result, status }) => {
  const running = status?.type !== "complete" && result === undefined;
  const argStr = argsText || (args ? JSON.stringify(args) : "");
  const resStr =
    result === undefined ? "" : typeof result === "string" ? result : JSON.stringify(result, null, 2);
  return (
    <div style={{ border: "1px solid #d1d5db", borderRadius: 8, padding: 8, margin: "4px 0", fontFamily: "ui-monospace, monospace", fontSize: 13, background: "#f9fafb" }}>
      <div style={{ fontWeight: 600 }}>
        🔧 {toolName}({clip(argStr, 200)}) {running ? "· running…" : "· done"}
      </div>
      {resStr && (
        <pre style={{ margin: "6px 0 0", whiteSpace: "pre-wrap", color: "#374151" }}>{clip(resStr)}</pre>
      )}
    </div>
  );
};

const AssistantMessage: FC = () => (
  <MessagePrimitive.Root style={{ display: "flex", flexDirection: "column", alignItems: "flex-start", width: "100%" }}>
    <div style={{ ...bubble(false), maxWidth: "90%" }}>
      <MessagePrimitive.Content components={{ Text: MarkdownText, tools: { Fallback: ToolFallback } }} />
    </div>
  </MessagePrimitive.Root>
);

const Thread: FC = () => (
  <ThreadPrimitive.Root style={{ display: "flex", flexDirection: "column", height: "70vh", border: "1px solid #d1d5db", borderRadius: 12, overflow: "hidden" }}>
    <ThreadPrimitive.Viewport style={{ flex: 1, overflowY: "auto", padding: 16, display: "flex", flexDirection: "column" }}>
      <ThreadPrimitive.Messages components={{ UserMessage, AssistantMessage }} />
    </ThreadPrimitive.Viewport>
    <ComposerPrimitive.Root style={{ display: "flex", gap: 8, padding: 12, borderTop: "1px solid #d1d5db" }}>
      <ComposerPrimitive.Input
        placeholder="Give the harness a task…"
        style={{ flex: 1, padding: 8, borderRadius: 8, border: "1px solid #d1d5db", resize: "none" }}
      />
      <ComposerPrimitive.Send style={{ padding: "8px 16px", borderRadius: 8, border: "none", background: "#2563eb", color: "white", cursor: "pointer" }}>
        Send
      </ComposerPrimitive.Send>
    </ComposerPrimitive.Root>
  </ThreadPrimitive.Root>
);

// A checkbox that toggles the model's "thinking" (reasoning tokens) for the next
// run. It POSTs {think} to the server's /config endpoint rather than rebuilding
// the agent, so the conversation is preserved. Thinking off is the default: for a
// multi-turn agentic loop the per-turn reasoning is the dominant latency.
const ThinkingToggle: FC = () => {
  const [think, setThink] = useState(false);
  const [busy, setBusy] = useState(false);
  const onToggle = async (next: boolean) => {
    setBusy(true);
    setThink(next);
    try {
      await fetch(CONFIG_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ think: next }),
      });
    } catch {
      setThink(!next); // revert on failure
    } finally {
      setBusy(false);
    }
  };
  return (
    <label style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 14, color: "#374151", cursor: "pointer" }}>
      <input type="checkbox" checked={think} disabled={busy} onChange={(e) => onToggle(e.target.checked)} />
      Thinking {think ? "on" : "off"}
    </label>
  );
};

export function App() {
  const agent = useMemo(() => new HttpAgent({ url: AGENT_URL }), []);
  const runtime = useAgUiRuntime({ agent });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <style>{`.md > :first-child { margin-top: 0 } .md > :last-child { margin-bottom: 0 } .md p { margin: 0.4em 0 } .md pre { background:#f3f4f6; padding:8px; border-radius:6px; overflow:auto } .md code { font-family: ui-monospace, monospace } .md table { border-collapse: collapse } .md th, .md td { border:1px solid #d1d5db; padding:2px 6px }`}</style>
      <main style={{ maxWidth: 720, margin: "40px auto", fontFamily: "system-ui, sans-serif", padding: "0 16px" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
          <h1 style={{ fontSize: 20 }}>Comonadic harness — AG-UI smoke test</h1>
          <ThinkingToggle />
        </div>
        <p style={{ color: "#6b7280", fontSize: 14 }}>
          assistant-ui driving the harness over the standard AG-UI transport
          (<code>{AGENT_URL}</code>). Each message starts a run; the assistant
          reply is streamed back as AG-UI events and rendered as Markdown.
        </p>
        <Thread />
      </main>
    </AssistantRuntimeProvider>
  );
}
