"use client";

import { useState } from "react";
import { greetAction } from "./actions";

export default function Home() {
  const [name, setName] = useState("");
  const [serverMessage, setServerMessage] = useState("");
  const [clientMessage, setClientMessage] = useState("");

  async function handleServerAction() {
    const msg = await greetAction(name || "World"); // ← Server Action 経由
    setServerMessage(msg);
  }

  async function handleClientFetch() {
    const res = await fetch(
      `/api/greet?name=${encodeURIComponent(name || "World")}`
    );
    const data = await res.json(); // ← クライアント → Next.js API Route 経由
    setClientMessage(data.message);
  }

  return (
    <main style={{ padding: "2rem", fontFamily: "sans-serif" }}>
      <h1>Debug Demo</h1>

      <div style={{ marginBottom: "1rem" }}>
        <input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="名前を入力"
          style={{ padding: "0.5rem", marginRight: "0.5rem" }}
        />
      </div>

      <div style={{ display: "flex", gap: "1rem", marginBottom: "2rem" }}>
        <button onClick={handleServerAction} style={{ padding: "0.5rem 1rem" }}>
          Server Action で呼ぶ
        </button>
        <button onClick={handleClientFetch} style={{ padding: "0.5rem 1rem" }}>
          API Route で呼ぶ
        </button>
      </div>

      {serverMessage && (
        <p>
          <strong>Server Action:</strong> {serverMessage}
        </p>
      )}
      {clientMessage && (
        <p>
          <strong>API Route:</strong> {clientMessage}
        </p>
      )}
    </main>
  );
}
