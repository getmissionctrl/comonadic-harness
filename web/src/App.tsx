import { useMemo } from "react";
import type { FC } from "react";
import {
  AssistantRuntimeProvider,
  ThreadPrimitive,
  MessagePrimitive,
  ComposerPrimitive,
} from "@assistant-ui/react";
import { useAgUiRuntime } from "@assistant-ui/react-ag-ui";
import { HttpAgent } from "@ag-ui/client";

// The standard AG-UI endpoint exposed by the Haskell harness server
// (Harness.AgUi.Server, POST /agent). Override with VITE_AGENT_URL if the
// server runs on another port.
const AGENT_URL =
  (import.meta.env.VITE_AGENT_URL as string | undefined) ??
  "http://localhost:8080/agent";

const bubble = (mine: boolean): React.CSSProperties => ({
  alignSelf: mine ? "flex-end" : "flex-start",
  background: mine ? "#2563eb" : "#e5e7eb",
  color: mine ? "white" : "#111827",
  padding: "8px 12px",
  borderRadius: 12,
  margin: "4px 0",
  maxWidth: "80%",
  whiteSpace: "pre-wrap",
});

const UserMessage: FC = () => (
  <MessagePrimitive.Root style={{ display: "flex", flexDirection: "column", alignItems: "flex-end" }}>
    <div style={bubble(true)}>
      <MessagePrimitive.Content />
    </div>
  </MessagePrimitive.Root>
);

const AssistantMessage: FC = () => (
  <MessagePrimitive.Root style={{ display: "flex", flexDirection: "column", alignItems: "flex-start" }}>
    <div style={bubble(false)}>
      <MessagePrimitive.Content />
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

export function App() {
  const agent = useMemo(() => new HttpAgent({ url: AGENT_URL }), []);
  const runtime = useAgUiRuntime({ agent });
  return (
    <AssistantRuntimeProvider runtime={runtime}>
      <main style={{ maxWidth: 720, margin: "40px auto", fontFamily: "system-ui, sans-serif", padding: "0 16px" }}>
        <h1 style={{ fontSize: 20 }}>Comonadic harness — AG-UI smoke test</h1>
        <p style={{ color: "#6b7280", fontSize: 14 }}>
          assistant-ui driving the harness over the standard AG-UI transport
          (<code>{AGENT_URL}</code>). Each message starts a run; the assistant
          reply is streamed back as AG-UI events.
        </p>
        <Thread />
      </main>
    </AssistantRuntimeProvider>
  );
}
